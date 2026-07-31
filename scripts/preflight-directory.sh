#!/usr/bin/env bash
# Prove an EXTERNAL directory works before any BIG-IP is touched.
#
# Every failure this catches is one that would otherwise surface as an opaque authentication
# error on the appliance, where the real cause is invisible. Read-only throughout: it binds,
# searches, and reads. It writes nothing.
#
# Usage:  scripts/preflight-directory.sh [test-user]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
# shellcheck disable=SC1091
. "${HERE}/lib/directory.sh"

TEST_USER="${1:-alice.admin}"
FAIL=0
ok(){  printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad(){ printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
note(){ printf '        %s\n' "$*"; }

echo
mfa_directory_summary
echo

URI="ldap://${MFA_LDAP_HOST}:${MFA_LDAP_PORT}"
URIS="ldaps://${MFA_LDAP_HOST}:${MFA_LDAPS_PORT}"

# 1. the bind account. Everything else depends on this one working.
if ldapwhoami -x -H "$URI" -D "${MFA_BIND_DN}" -w "${MFA_BIND_PW}" >/dev/null 2>&1; then
  ok "bind as ${MFA_BIND_DN}"
else
  bad "cannot bind as ${MFA_BIND_DN} on ${URI}"
  note "wrong DN or password, or the directory refuses simple binds on the plain port"
fi

# 2. the search base has to exist and be readable BY THE BIND ACCOUNT — a base that exists
#    but is not readable looks identical to a base that does not exist.
if ldapsearch -x -LLL -H "$URI" -D "${MFA_BIND_DN}" -w "${MFA_BIND_PW}" \
     -b "${MFA_USER_SEARCH_BASE}" -s base dn >/dev/null 2>&1; then
  ok "search base ${MFA_USER_SEARCH_BASE} is readable"
else
  bad "cannot read ${MFA_USER_SEARCH_BASE}"
fi

# 3. the login attribute must actually resolve a user, or APM's LDAP Auth finds nobody.
DN=$(ldapsearch -x -LLL -H "$URI" -D "${MFA_BIND_DN}" -w "${MFA_BIND_PW}" \
     -b "${MFA_USER_SEARCH_BASE}" "(${MFA_LOGIN_ATTR}=${TEST_USER})" dn 2>/dev/null | sed -n 's/^dn: //p' | head -1)
if [ -n "$DN" ]; then
  ok "(${MFA_LOGIN_ATTR}=${TEST_USER}) resolves to ${DN}"
else
  bad "(${MFA_LOGIN_ATTR}=${TEST_USER}) matched nothing"
  note "with Active Directory the login attribute is normally sAMAccountName — set MFA_LDAP_SCHEMA=ad"
fi

# 4. memberOf must be RETURNED, not merely correct. Many directories compute it, some strip
#    it from unprivileged reads, and remote-role maps on it — so if it is missing here, no
#    user will ever be elevated to administrator and nothing else will indicate why.
if [ -n "$DN" ]; then
  MEM=$(ldapsearch -x -LLL -H "$URI" -D "${MFA_BIND_DN}" -w "${MFA_BIND_PW}" \
        -b "${MFA_USER_SEARCH_BASE}" "(${MFA_LOGIN_ATTR}=${TEST_USER})" memberOf 2>/dev/null | grep -c '^memberOf:')
  if [ "${MEM:-0}" -ge 1 ]; then
    ok "memberOf is returned for ${TEST_USER} (${MEM} group(s))"
    if ldapsearch -x -LLL -H "$URI" -D "${MFA_BIND_DN}" -w "${MFA_BIND_PW}" \
         -b "${MFA_USER_SEARCH_BASE}" "(${MFA_LOGIN_ATTR}=${TEST_USER})" memberOf 2>/dev/null \
         | grep -qi "${MFA_ADMIN_GROUP_DN}"; then
      ok "${TEST_USER} is in ${MFA_ADMIN_GROUP_DN} (would become Administrator)"
    else
      note "${TEST_USER} is not in ${MFA_ADMIN_GROUP_DN} — would land read-only"
    fi
  else
    bad "memberOf is NOT returned for ${TEST_USER}"
    note "remote-role maps on memberOf; without it nobody is ever elevated"
    note "nested groups do not appear in memberOf — use a group with direct membership"
  fi
fi

# 5. LDAPS, which is what the BIG-IP itself uses, validated against the CA you supplied.
case "${MFA_LDAP_CA_FILE}" in /*) CA="${MFA_LDAP_CA_FILE}";; *) CA="${HERE}/../${MFA_LDAP_CA_FILE}";; esac
if [ ! -f "$CA" ]; then
  bad "MFA_LDAP_CA_FILE not found: ${CA}"
elif LDAPTLS_CACERT="$CA" ldapwhoami -x -H "$URIS" -D "${MFA_BIND_DN}" -w "${MFA_BIND_PW}" >/dev/null 2>&1; then
  ok "LDAPS bind on ${URIS} validates against ${CA##*/}"
else
  bad "LDAPS bind failed on ${URIS}"
  note "the BIG-IP validates the same way and fails closed — export the CA that signed the"
  note "directory's LDAPS certificate (for AD, the issuing CA of the DC certificate)"
fi

printf '\n%s\n' "$([ "$FAIL" = 0 ] && printf '\033[32mdirectory looks usable\033[0m' || printf "\033[31m${FAIL} check(s) failed — fix these before ./deploy.sh --bigip\033[0m")"
exit "$FAIL"
