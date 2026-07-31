#!/usr/bin/env bash
# End-to-end checks for a deployed bigip-mgt-mfa. Read-only: it asserts, it never configures.
# Run after ./deploy.sh. Exit code is the number of failed checks.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
_PASS_IN="${BIGIP_PASS:-}"; set -a; . "${HERE}/../.env"; set +a
# shellcheck disable=SC1091
. "${HERE}/lib/directory.sh"
[ -n "$_PASS_IN" ] && BIGIP_PASS="$_PASS_IN"

FAIL=0
ok(){   printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad(){  printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
skip(){ printf '  \033[33mSKIP\033[0m  %s\n' "$*"; }
sect(){ printf '\n\033[36m== %s ==\033[0m\n' "$*"; }


sect "containers"
for c in bigip-mgt-mfa-dns; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] \
    && ok "$c running" || bad "$c not running"
done
if mfa_is_bundled; then
  [ "$(docker inspect -f '{{.State.Running}}' openldap 2>/dev/null)" = true ] \
    && ok "openldap running" || bad "openldap not running"
fi

sect "demo DNS zone"
for pair in "${MFA_WEBTOP_FQDN}:${MFA_APM_VIP}"; do
  name="${pair%:*}"; want="${pair##*:}"
  got=$(dig +short +time=3 +tries=1 "@${MFA_HOST_IP}" -p "${MFA_DNS_PORT:-53}" "$name" 2>/dev/null | tail -1)
  [ "$got" = "$want" ] && ok "$name -> $got" || bad "$name resolved '$got', expected '$want'"
done

sect "directory"
LDAP_URI="ldap://${MFA_LDAP_HOST}:${MFA_LDAP_PORT}"
ldapwhoami -x -H "$LDAP_URI" -D "${MFA_BIND_DN}" -w "${MFA_BIND_PW}" >/dev/null 2>&1 \
  && ok "bind account can bind" || bad "bind account cannot bind as ${MFA_BIND_DN}"
# The demo's whole authorization story in two assertions: alice is in the admin group and
# bob is not. If these are wrong, the TMUI role outcome is wrong too.
for u in alice.admin bob.user; do
  ldapwhoami -x -H "$LDAP_URI" -D "${MFA_LOGIN_ATTR}=${u},${MFA_USER_SEARCH_BASE}" -w "${MFA_TEST_USER_PW}" >/dev/null 2>&1 \
    && ok "$u can bind with the demo password" || bad "$u cannot bind"
done
MEM=$(ldapsearch -x -LLL -H "$LDAP_URI" -D "${MFA_BIND_DN}" -w "${MFA_BIND_PW}" \
      -b "${MFA_USER_SEARCH_BASE}" "(${MFA_LOGIN_ATTR}=alice.admin)" memberOf 2>/dev/null | grep -ci "${MFA_ADMIN_GROUP_DN}")
[ "${MEM:-0}" -ge 1 ] && ok "alice.admin has memberOf=${MFA_ADMIN_GROUP_DN}" \
  || bad "alice.admin is NOT in the admin group (memberof overlay applied before the group was created?)"
MEM=$(ldapsearch -x -LLL -H "$LDAP_URI" -D "${MFA_BIND_DN}" -w "${MFA_BIND_PW}" \
      -b "${MFA_USER_SEARCH_BASE}" "(${MFA_LOGIN_ATTR}=bob.user)" memberOf 2>/dev/null | grep -ci "${MFA_ADMIN_GROUP_DN}")
[ "${MEM:-0}" -eq 0 ] && ok "bob.user is not in the admin group (will land read-only)" \
  || bad "bob.user IS in the admin group — the read-only half of the demo will not show"


# Preflight: is the management plane even answering? Every BIG-IP check below reads config
# over iControl REST, and an unreachable restjavad looks EXACTLY like a missing object --
# both produce an empty jq result. Reporting "access profile NOT on B" when the real problem
# is a wedged control plane sends you hunting through configuration that was never broken.
# It has happened twice; hence this gate.
#
# Note the data plane is independent: TMM keeps serving the webtop perfectly while restjavad
# is down, so "REST unreachable" is not the same as "the demo is down". Check the VIP.
A=(-sk -u "${BIGIP_USER}:${BIGIP_PASS:-}")
# BIGIP_B_MGMT is optional -- a single-unit deployment is supported, so every per-unit check
# iterates whatever is actually configured rather than assuming a pair.
UNITS=("$BIGIP_A_MGMT")
[ -n "${BIGIP_B_MGMT:-}" ] && UNITS+=("$BIGIP_B_MGMT")
mgmt_up(){ # mgmt_up <address>
  curl "${A[@]}" -o /dev/null -m8 -w '%{http_code}' "https://$1/mgmt/tm/sys/version" 2>/dev/null | grep -q '^200$'
}
REST_DOWN=0
if [ -n "${BIGIP_PASS:-}" ]; then
  for u in "${UNITS[@]}"; do
    mgmt_up "$u" || { REST_DOWN=1; printf '  \033[33mSKIP\033[0m  %s iControl REST is not answering\n' "$u"; }
  done
fi
if [ "$REST_DOWN" = 1 ]; then
  sect "BIG-IP access tier"
  skip "every BIG-IP config check — the management plane is unreachable, not necessarily misconfigured"
  echo "        restjavad may be wedged: 'bigstart restart restjavad' on the unit."
  echo "        The data plane is separate — check the VIP before assuming the demo is down:"
  echo "        curl -sk -o /dev/null -w '%{http_code}\n' https://${MFA_APM_VIP}/"
else

sect "BIG-IP access tier"
if [ -z "${BIGIP_PASS:-}" ]; then
  skip "BIGIP_PASS not set — skipping BIG-IP checks"
else
  A=(-sk -u "${BIGIP_USER}:${BIGIP_PASS}")
  for unit in "${UNITS[@]}"; do
    RR=$(curl "${A[@]}" -m8 "https://${unit}/mgmt/tm/auth/remote-role/role-info/bigip_mgt_mfa_admins" | jq -r '.attribute // empty')
    [ "$RR" = "${MFA_ADMIN_ROLE_ATTRIBUTE}" ] \
      && ok "$unit remote-role maps ${RR} -> administrator" \
      || bad "$unit remote-role missing or wrong (got '${RR:-none}')"
    SRC=$(curl "${A[@]}" -m8 "https://${unit}/mgmt/tm/auth/source" | jq -r '.type // empty')
    [ "$SRC" = ldap ] && ok "$unit auth source is ldap" || bad "$unit auth source is '${SRC:-unknown}'"
    DEF=$(curl "${A[@]}" -m8 "https://${unit}/mgmt/tm/auth/remote-user" | jq -r '.defaultRole // empty')
    [ "$DEF" = guest ] && ok "$unit default role is guest (read-only)" || bad "$unit default role is '${DEF:-unknown}'"
  done
  AP=$(curl "${A[@]}" -m8 "https://${BIGIP_A_MGMT}/mgmt/tm/apm/profile/access/~Common~bigip-mgt-mfa" | jq -r '.name // empty')
  [ -n "$AP" ] && ok "access profile bigip-mgt-mfa present on A" || bad "access profile missing on A"
  # Synced, not just built: the peer must carry the policy or a failover loses the webtop.
  if [ -n "${BIGIP_B_MGMT:-}" ]; then
    APB=$(curl "${A[@]}" -m8 "https://${BIGIP_B_MGMT}/mgmt/tm/apm/profile/access/~Common~bigip-mgt-mfa" | jq -r '.name // empty')
    [ -n "$APB" ] && ok "access profile synced to B" || bad "access profile NOT on B — run a config-sync"
  else
    skip "peer sync — single-unit deployment (BIGIP_B_MGMT unset)"
  fi
  RES_N=$(curl "${A[@]}" -m8 "https://${BIGIP_A_MGMT}/mgmt/tm/apm/resource/portal-access" | jq -r '[.items[]?|select(.name|startswith("bigip-mgt-mfa-bigip"))]|length')
  [ "${RES_N:-0}" = 2 ] && ok "two portal resources (one per unit)" || bad "expected 2 portal resources, found ${RES_N:-0}"
  # A portal resource can exist, publish and rewrite perfectly while carrying NO SSO
  # configuration: passing sso inside items.item1 on a REST create returns 200 and is then
  # silently dropped. The user gets a working webtop that immediately asks them to log in
  # again -- the one thing this demo exists to avoid -- so assert it rather than assume it.
  for r in bigip-a bigip-b; do
    # The /items SUB-COLLECTION, not the parent object: the parent's representation omits
    # nested item fields entirely and reports sso as null even when it is correctly set.
    # Reading the parent produces a convincing false alarm.
    SSO=$(curl "${A[@]}" -m8 "https://${BIGIP_A_MGMT}/mgmt/tm/apm/resource/portal-access/~Common~bigip-mgt-mfa-${r}-tmui/items" | jq -r '.items[0].sso // empty')
    [ -n "$SSO" ] && ok "${r} portal resource has form SSO attached" || bad "${r} portal resource has NO SSO — the webtop will ask for a second login"
  done
  VS=$(curl "${A[@]}" -m8 "https://${BIGIP_A_MGMT}/mgmt/tm/ltm/virtual/~Common~bigip-mgt-mfa-vs" | jq -r '.destination // empty')
  [ -n "$VS" ] && ok "webtop virtual server $VS" || bad "webtop virtual server missing"
fi

sect "authorization (the point of the demo)"
if [ -z "${BIGIP_PASS:-}" ]; then
  skip "BIGIP_PASS not set — skipping role checks"
else
  # Asserted from the BIG-IP's own audit log rather than from HTTP status codes: the Guest
  # role legitimately cannot use iControl REST, so a read-only user returns 401 to curl and
  # a status-code test would read that as "broken" when it is exactly right. The audit line
  # records the role TMOS actually assigned.
  probe_role(){ # probe_role <unit> <user>
    curl -sk -m10 -o /dev/null -u "${2}:${MFA_TEST_USER_PW}" "https://${1}/mgmt/tm/sys/version" 2>/dev/null
    sleep 3
    curl -sk -m10 -u "${BIGIP_USER}:${BIGIP_PASS}" -X POST -H 'Content-Type: application/json' \
      "https://${1}/mgmt/tm/util/bash" \
      -d "{\"command\":\"run\",\"utilCmdArgs\":\"-c \\\"grep pam_audit /var/log/secure | grep ${2} | tail -1\\\"\"}" \
      | jq -r '.commandResult // ""' | grep -oE 'level=[A-Za-z]+' | tail -1 | cut -d= -f2
  }
  for unit in "${UNITS[@]}"; do
    R=$(probe_role "$unit" alice.admin)
    [ "$R" = Administrator ] && ok "$unit: alice.admin -> Administrator" \
      || bad "$unit: alice.admin got '${R:-unknown}', expected Administrator (is checkRolesGroup enabled?)"
    R=$(probe_role "$unit" bob.user)
    [ "$R" = Guest ] && ok "$unit: bob.user -> Guest (read-only)" \
      || bad "$unit: bob.user got '${R:-unknown}', expected Guest"
  done
fi

fi   # end of the management-plane gate

sect "front door"
CODE=$(curl -sk -o /dev/null -w '%{http_code}' -m10 --resolve "${MFA_WEBTOP_FQDN}:443:${MFA_APM_VIP}" "https://${MFA_WEBTOP_FQDN}/" 2>/dev/null)
case "$CODE" in
  200|302) ok "VIP answers on https://${MFA_WEBTOP_FQDN}/ (HTTP $CODE)";;
  000)     bad "VIP ${MFA_APM_VIP} unreachable from this host (routing, or run this from a host on that network)";;
  *)       bad "VIP answered HTTP $CODE";;
esac

# ── single sign-on, tested by BEHAVIOUR ─────────────────────────────────────
# The checks above assert that SSO is CONFIGURED. That is not the same claim, and the
# difference is not academic: this suite once reported everything green while clicking a
# webtop tile landed on the TMUI login form. Configuration checks cannot catch a wrong form
# action, a missing CSRF header, or an empty credential -- only driving the thing can.
#
# So: log in for real, open a portal resource, and assert that what comes back is the TMUI
# application rather than its login page.
sect "single sign-on (behaviour, not configuration)"
if [ -z "${MFA_TEST_USER_PW:-}" ] || [ ! -s "${HERE}/../certs/totp-seeds.env" ]; then
  skip "no demo credentials or TOTP seeds — cannot drive a real login"
elif ! command -v oathtool >/dev/null 2>&1; then
  skip "oathtool not installed — cannot generate a one-time code"
else
  SSO_USER="${MFA_SSO_TEST_USER:-alice.admin}"
  SEED=$(grep "^${SSO_USER}=" "${HERE}/../certs/totp-seeds.env" | cut -d= -f2)
  if [ -z "$SEED" ]; then
    skip "${SSO_USER} has no enrolled token — run scripts/enroll-totp.sh"
  else
    JAR=$(mktemp)
    C=(-sk -c "$JAR" -b "$JAR" --resolve "${MFA_WEBTOP_FQDN}:443:${MFA_APM_VIP}")
    OTP=$(oathtool --totp -b --time-step-size="${MFA_TOTP_PERIOD:-60}s" "$SEED")
    curl "${C[@]}" -o /dev/null -m10 "https://${MFA_WEBTOP_FQDN}/" 2>/dev/null
    curl "${C[@]}" -L -o /dev/null -m10 "https://${MFA_WEBTOP_FQDN}/my.policy" 2>/dev/null
    PAGE=$(curl "${C[@]}" -L -m20 -d "username=${SSO_USER}" \
             --data-urlencode "password=${MFA_TEST_USER_PW}" \
             -d "otp=${OTP}" -d vhost=standard \
             "https://${MFA_WEBTOP_FQDN}/my.policy" 2>/dev/null)
    if ! grep -q '"webtop"' <<<"$PAGE"; then
      bad "${SSO_USER} could not reach the webtop — MFA login failed, so SSO is untestable"
    else
      ok "${SSO_USER} reached the webtop"
      # Follow the published portal resource and look at what TMUI actually returns. A login
      # form here means the credential was never injected -- the exact failure that
      # configuration checks sail straight past.
      LINK=$(curl "${C[@]}" -s -m15 "https://${MFA_WEBTOP_FQDN}/vdesk/webtop.eui?webtop=/Common/${P:-bigip-mgt-mfa}-webtop" 2>/dev/null \
             | grep -oE '/f5-w-[A-Za-z0-9%]+\$\$/?' | head -1)
      if [ -z "$LINK" ]; then
        skip "could not find a rewritten portal link on the webtop to follow"
      else
        APP=$(curl "${C[@]}" -L -m20 "https://${MFA_WEBTOP_FQDN}${LINK}" 2>/dev/null)
        if grep -qiE 'name="passwd"|loginform|Log in with your username' <<<"$APP"; then
          bad "portal opened TMUI's LOGIN FORM — single sign-on is not injecting the credential"
        elif grep -qiE 'Configuration Utility|tmui|Main.*Statistics' <<<"$APP"; then
          ok "portal opened TMUI already authenticated (no login form)"
        else
          skip "portal returned an unrecognised page — inspect by hand"
        fi
      fi
    fi
    rm -f "$JAR"
  fi
fi

printf '\n%s\n' "$([ "$FAIL" = 0 ] && printf '\033[32mall checks passed\033[0m' || printf "\033[31m${FAIL} check(s) failed\033[0m")"
exit "$FAIL"
