#!/usr/bin/env bash
# The APM front door. Builds the whole access tier on ONE unit; config-sync carries it to
# the peer (deploy.sh triggers the sync).
#
# Policy graph:
#   Start -> Logon Page (username + password + one-time code)
#         -> LDAP Auth  (the directory proves the password)
#         -> Keycloak Verify (ONE direct-grant call proves password AND OTP together)
#         -> SSO Credential Mapping -> Resource Assign -> Allow
#   any failure -> Deny
#
# One screen, no redirect. The user reads their code from the authenticator they enrolled
# at Keycloak and types all three values here; APM posts username+password+otp to Keycloak's
# token endpoint in a single call, so Keycloak validates both factors against ONE identity
# atomically. A valid password paired with somebody else's authenticator is rejected by
# Keycloak, not by a comparison we have to remember to write.
#
# An earlier revision redirected to Keycloak for OIDC step-up. It asked for the username
# twice, needed a password-less realm no customer would run, and — because nothing compared
# the token subject to the user APM had authenticated — accepted anyone else's second
# factor. See docs/adr/0002-single-logon-page-direct-grant.md.
#
# Idempotent: the mutable policy graph is torn down and rebuilt; everything else tolerates
# 409 (already exists).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
_PASS_IN="${BIGIP_PASS:-}"; set -a; . "${HERE}/../.env"; set +a
# shellcheck disable=SC1091
. "${HERE}/../scripts/lib/directory.sh"
# shellcheck disable=SC1091
. "${HERE}/../scripts/lib/units.sh"
# shellcheck disable=SC1091
. "${HERE}/lib/objects.sh"
[ -n "$_PASS_IN" ] && BIGIP_PASS="$_PASS_IN"
: "${BIGIP_PASS:?export BIGIP_PASS}"; : "${MFA_BIND_PW:?need MFA_BIND_PW}"
: "${BIGIP_MGMT:=${BIGIP_A_MGMT:?set BIGIP_A_MGMT}}"
# A second unit is optional throughout. Everything B-side below — the façade virtual, its
# node iRule, the portal resource and the webtop tile — is built only when one is configured.
mfa_require_peer_tmui || exit 1

B="https://${BIGIP_MGMT}"; A=(-sk -u "${BIGIP_USER}:${BIGIP_PASS}")
P=bigip-mgt-mfa                     # object-name prefix / access-profile name
PART=Common
AAA=${P}-ldap-aaa
VIP_IP="${MFA_APM_VIP:?set MFA_APM_VIP in .env}"
SHADOW_A="${MFA_SHADOW_A:-192.0.2.5}"
SHADOW_B="${MFA_SHADOW_B:-192.0.2.6}"
KC_AAA=${P}-keycloak-otp
SHADOW_KC="${MFA_SHADOW_KC:-192.0.2.7}"   # non-routable façade for the Keycloak call

step(){ echo; echo "== $* =="; }
add(){ # add <url> <json> — additive POST tolerating 409, retrying transient failures
  # The BIG-IP's REST layer is not reliable under the volume of calls a full build makes:
  # restjavad returns 401 or 502 ("Error reading from remote server"), or stops answering
  # entirely, and recovers a few seconds later. Because step 2 tears the policy down before
  # rebuilding it, a single transient error used to abort the run and leave the demo DELETED
  # rather than merely unchanged. That is the worst possible failure mode for something you
  # demo, so transient codes are retried rather than fatal.
  local code attempt=1 max=5
  while :; do
    code=$(curl "${A[@]}" -o /tmp/wl-apm.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$2" "$1" || echo 000)
    case "$code" in
      200|201|409) echo "  POST ${1##*/tm/} -> $code"; return 0 ;;
      000|401|500|502|503|504)
        if [ "$attempt" -ge "$max" ]; then
          echo "  POST ${1##*/tm/} -> $code (gave up after ${max} attempts)"
          echo "    $(head -c 300 /tmp/wl-apm.out)"; return 1
        fi
        echo "  POST ${1##*/tm/} -> $code (transient, retry ${attempt}/${max})"
        sleep $((attempt * 4)); attempt=$((attempt + 1)) ;;
      *) echo "  POST ${1##*/tm/} -> $code"; echo "    $(head -c 300 /tmp/wl-apm.out)"; return 1 ;;
    esac
  done
}
bash_cmd(){ # bash_cmd <tmsh-or-shell> — run via /tm/util/bash, print commandResult
  # tmsh reports errors in commandResult with a 200 on the wire, so a naive caller sees
  # success. Surface anything that looks like an error loudly: a silently-skipped tmsh
  # command is how the portal headers went missing while the build claimed to work.
  local out attempt=1
  while :; do
    out=$(curl "${A[@]}" -X POST -H 'Content-Type: application/json' "$B/mgmt/tm/util/bash" \
          -d "$(jq -n --arg u "-c '$1'" '{command:"run",utilCmdArgs:$u}')" | jq -r '.commandResult // ""' 2>/dev/null || echo "")
    # A 502 arrives as an HTML error page, not JSON, so jq yields nothing. Distinguish that
    # from a command that legitimately printed nothing by retrying a bounded number of times.
    case "$out" in
      *"Proxy Error"*|*"<html>"*|*"resterrorresponse"*)
        [ "$attempt" -ge 4 ] && break
        echo "    (REST transient, retry ${attempt}/4)" >&2
        sleep $((attempt * 4)); attempt=$((attempt + 1)) ;;
      *) break ;;
    esac
  done
  [ -n "$out" ] && echo "$out"
  case "$out" in
    *"Syntax Error"*|*"was not found"*|*"01020036"*|*"is not allowed"*)
      echo "    ^^ tmsh REJECTED that command" >&2 ;;
  esac
  return 0
}
upload(){ # upload <local-file> <remote-name>
  local sz; sz=$(stat -c%s "$1")
  curl "${A[@]}" -X POST -H "Content-Type: application/octet-stream" \
    -H "Content-Range: 0-$((sz-1))/${sz}" --data-binary @"$1" \
    "$B/mgmt/shared/file-transfer/uploads/$2" -o /dev/null -w "  upload $2 -> %{http_code}\n"
}

step "1. VIP server certificate (${MFA_WEBTOP_FQDN})"
# The browser must trust this name: it is the OIDC redirect_uri origin, and a cert error
# here surfaces as a failed OAuth redirect rather than as a cert warning.
upload "${HERE}/../certs/webtop.crt" "${P}-webtop.crt"
upload "${HERE}/../certs/webtop.key" "${P}-webtop.key"
# endpoint:extension — the REST collection is ssl-cert but the uploaded file is .crt.
for pair in cert:crt key:key; do
  ep="${pair%%:*}"; obj="${P}-webtop.${pair##*:}"
  if curl "${A[@]}" "$B/mgmt/tm/sys/file/ssl-${ep}/${obj}" | jq -e '.name' >/dev/null 2>&1; then
    curl "${A[@]}" -o /dev/null -w "  PATCH ssl-${ep} -> %{http_code}\n" -X PATCH -H 'Content-Type: application/json' \
      -d "{\"sourcePath\":\"file:/var/config/rest/downloads/${obj}\"}" "$B/mgmt/tm/sys/file/ssl-${ep}/${obj}"
  else
    add "$B/mgmt/tm/sys/file/ssl-${ep}" "{\"name\":\"${obj}\",\"sourcePath\":\"file:/var/config/rest/downloads/${obj}\"}"
  fi
done
# Keycloak's CA, so the BIG-IP can validate the back-channel token call.
upload "${HERE}/../certs/ca.crt" "${P}-ca.crt"
curl "${A[@]}" "$B/mgmt/tm/sys/file/ssl-cert/${P}-ca.crt" | jq -e '.name' >/dev/null 2>&1 \
  && curl "${A[@]}" -o /dev/null -w "  PATCH ca -> %{http_code}\n" -X PATCH -H 'Content-Type: application/json' \
       -d "{\"sourcePath\":\"file:/var/config/rest/downloads/${P}-ca.crt\"}" "$B/mgmt/tm/sys/file/ssl-cert/${P}-ca.crt" \
  || add "$B/mgmt/tm/sys/file/ssl-cert" "{\"name\":\"${P}-ca.crt\",\"sourcePath\":\"file:/var/config/rest/downloads/${P}-ca.crt\"}"

add "$B/mgmt/tm/ltm/profile/client-ssl" "$(jq -n --arg n "${P}-clientssl" --arg c "/$PART/${P}-webtop.crt" --arg k "/$PART/${P}-webtop.key" \
  '{name:$n,partition:"Common",defaultsFrom:"/Common/clientssl",cert:$c,key:$k}')"
# Server-side profile for the OAuth back-channel: validate Keycloak against our CA.
add "$B/mgmt/tm/ltm/profile/server-ssl" "$(jq -n --arg n "${P}-serverssl-oauth" --arg ca "/$PART/${P}-ca.crt" \
  '{name:$n,partition:"Common",defaultsFrom:"/Common/serverssl",caFile:$ca,peerCertMode:"require",authenticateName:""}')"

step "2. teardown the mutable graph so this re-runs cleanly"
# Before the OAuth objects, not after: the aaa-oauth agent holds references to the request
# objects, so they cannot be recreated while it still exists. Tearing down first makes a
# re-run genuinely converge instead of silently keeping the previous values.
td(){ curl "${A[@]}" -o /dev/null -w "  DEL ${1##*~} -> %{http_code}\n" -X DELETE "$1"; }
while IFS= read -r o; do td "$B/mgmt/tm/${o}"; done < <(mfa_apm_objects "$P" "$PART")

step "3. AAA LDAP server (password check happens here, by BIND)"
# TMOS 21.x APM AAA LDAP requires a server POOL — a bare address is rejected. Single-quote
# wrap so the DN commas pass through tmsh intact.
# Delete first: `tmsh create` is not idempotent and silently keeps the EXISTING object when
# one is already there. Anything that changes in .env afterwards -- the bind DN, the search
# base, the directory address -- is then ignored forever, and the failure surfaces much later
# as "Failed to bind ... Invalid credentials" naming a DN that is no longer in any config file.
bash_cmd "tmsh delete apm aaa ldap ${AAA} 2>/dev/null; tmsh delete ltm pool ${AAA}-pool 2>/dev/null; true"
bash_cmd "tmsh create ltm pool ${AAA}-pool { members add { ${MFA_LDAP_HOST}:${MFA_LDAP_PORT} } monitor tcp } ; tmsh create apm aaa ldap ${AAA} { pool ${AAA}-pool port ${MFA_LDAP_PORT} admin-dn \"${MFA_BIND_DN}\" admin-encrypted-password \"${MFA_BIND_PW}\" base-dn \"${MFA_USER_SEARCH_BASE}\" }"

step "4. TOTP seed store"
# A data group, not a directory attribute. The directory owns identity; the MFA verifier
# owns token secrets -- the same split a real MFA product makes. It also keeps a
# credential-equivalent secret off the user's directory entry, where anything able to read
# the entry could mint valid codes.
#
# Seeds come from certs/totp-seeds.env, written by scripts/enroll-totp.sh. Absent that file
# nobody has a token and every login is denied, which is the correct failure direction.
SEEDS_FILE="${HERE}/../certs/totp-seeds.env"
RECORDS='[]'
if [ -f "$SEEDS_FILE" ]; then
  while IFS='=' read -r u sec; do
    case "$u" in ''|\#*) continue;; esac
    RECORDS=$(jq -c --arg n "$u" --arg d "$sec" '. += [{name:$n,data:$d}]' <<<"$RECORDS")
  done < "$SEEDS_FILE"
fi
echo "  seeds loaded: $(jq -r 'length' <<<"$RECORDS")"
curl "${A[@]}" -o /dev/null -w "  DEL previous data-group -> %{http_code}\n" -X DELETE "$B/mgmt/tm/ltm/data-group/internal/~${PART}~bigip_mgt_mfa_totp_dg"
add "$B/mgmt/tm/ltm/data-group/internal" "$(jq -n --argjson r "$RECORDS" '{name:"bigip_mgt_mfa_totp_dg",partition:"Common",type:"string",records:$r}')"

step "5. TOTP verification iRule"
curl "${A[@]}" -o /dev/null -w "  DEL previous rule -> %{http_code}\n" -X DELETE "$B/mgmt/tm/ltm/rule/~${PART}~${P}-totp-verify"
# envsubst restricted to our one placeholder so the iRule's own $vars survive untouched.
# Both placeholders must be listed. envsubst leaves anything unlisted untouched, and an
# unsubstituted ${MFA_TOTP_SKEW} is still VALID Tcl -- it reads a variable of that literal
# name -- so the rule compiles, uploads, reports success, and then fails at runtime on every
# login. It does not fail loudly anywhere.
TOTP_RULE="$(MFA_TOTP_PERIOD="${MFA_TOTP_PERIOD:-60}" MFA_TOTP_SKEW="${MFA_TOTP_SKEW:-1}" \
  envsubst '${MFA_TOTP_PERIOD} ${MFA_TOTP_SKEW}' < "${HERE}/apm-totp-verify.irule")"
case "$TOTP_RULE" in
  *'${MFA_'*) echo "  ERROR: a placeholder survived envsubst in the TOTP iRule" >&2; exit 1 ;;
esac
echo "  TOTP step ${MFA_TOTP_PERIOD:-60}s, skew +/-${MFA_TOTP_SKEW:-1} => a code is accepted for $(( ${MFA_TOTP_PERIOD:-60} * (2 * ${MFA_TOTP_SKEW:-1} + 1) ))s"
add "$B/mgmt/tm/ltm/rule" "$(jq -n --arg n "${P}-totp-verify" --arg b "$TOTP_RULE" '{name:$n,partition:"Common",apiAnonymous:$b}')"

step "6. customization groups"
add "$B/mgmt/tm/apm/policy/customization-group" "$(jq -n --arg n "${P}_act_logon_ag" '{name:$n,partition:"Common",source:"/Common/modern",type:"logon"}')"
add "$B/mgmt/tm/apm/policy/customization-group" "$(jq -n --arg n "${P}_end_deny_ag" '{name:$n,partition:"Common",source:"/Common/modern",type:"logout"}')"
add "$B/mgmt/tm/apm/policy/customization-group" "$(jq -n --arg n "${P}_webtop_cg" '{name:$n,partition:"Common",source:"/Common/modern",type:"webtop"}')"
for grp in logout:logout eps:eps errormap:errormap framework_installation:framework-installation general_ui:general-ui; do
  add "$B/mgmt/tm/apm/policy/customization-group" "$(jq -n --arg n "${P}_${grp%%:*}" --arg t "${grp##*:}" '{name:$n,partition:"Common",source:"/Common/modern",type:$t}')"
done

step "7. agents: logon page, LDAP auth, Keycloak verify, SSO mapping, resource assign"
add "$B/mgmt/tm/apm/policy/agent/logon-page" "$(jq -n --arg n "${P}_act_logon_ag" --arg cg "/$PART/${P}_act_logon_ag" \
  '{name:$n,partition:"Common",customizationGroup:$cg,
    fieldType1:"text",postVarName1:"username",sessVarName1:"username",fieldModifiable1:"true",
    fieldType2:"password",postVarName2:"password",sessVarName2:"password",fieldModifiable2:"true",
    fieldType3:"text",postVarName3:"otp",sessVarName3:"otp",fieldModifiable3:"true"}')"
# fieldType3 is "text", not "password": APM stores password-type fields as SECURE session
# variables, and a plain `ACCESS::session data get` on one returns an empty string -- the
# verifier then sees no code at all and denies every login. A one-time code is valid for
# 30 seconds and is not a long-lived secret, so a text field is the right trade here.
#
# sessVarName, NOT sessionVarName. TMOS silently drops the unknown property and leaves the
# default, so field 3 lands in session.logon.last.field3 and the OTP never reaches the
# verifier. Fields 1 and 2 hide the mistake because their defaults are already username and
# password -- only the third field exposes it.
# LDAP Auth (type=auth): APM locates the entry with the filter, then BINDS as that user to
# prove the password. Nothing reads a password hash, which is why the bind account needs no
# privilege beyond search.
add "$B/mgmt/tm/apm/policy/agent/aaa-ldap" "$(jq -n --arg n "${P}_act_ldapauth_ag" --arg s "/$PART/$AAA" \
  --arg base "${MFA_USER_SEARCH_BASE}" --arg f "(${MFA_LOGIN_ATTR}=%{session.logon.last.username})" \
  '{name:$n,partition:"Common",type:"auth",server:$s,searchDn:$base,filter:$f,maxLogonAttempt:3}')"
add "$B/mgmt/tm/apm/policy/agent/irule-event" "$(jq -n --arg n "${P}_act_kcverify_ag" \
  '{name:$n,partition:"Common",id:"totp_verify"}')"
# SSO Credential Mapping: hand the webtop resources the credential the user already proved.
# This is the entire "single sign-on" of the demo — no vault, no shared account.
add "$B/mgmt/tm/apm/policy/agent/variable-assign" "$(jq -n --arg n "${P}_act_ssomap_ag" \
  '{name:$n,partition:"Common",type:"sso-cred-mapping",variables:[
     {varname:"session.sso.token.last.username",expression:"mcget {session.logon.last.username}"},
     {varname:"session.sso.token.last.password",expression:"mcget -secure {session.logon.last.password}",secure:"true"}]}')"
add "$B/mgmt/tm/apm/policy/agent/ending-allow" "$(jq -n --arg n "${P}_end_allow_ag" '{name:$n,partition:"Common"}')"
add "$B/mgmt/tm/apm/policy/agent/ending-deny" "$(jq -n --arg n "${P}_end_deny_ag" --arg cg "/$PART/${P}_end_deny_ag" '{name:$n,partition:"Common",customizationGroup:$cg}')"

step "8. shadow façades for the TMUI of each configured unit ($(mfa_unit_count))"
# APM portal access refuses "reserved" targets — self-IPs, the management address, cluster
# addresses — with 01490585/errorcode=17, and publishing TMUI on a routable external self-IP
# would be a hole anyway. So each unit's TMUI is fronted by a non-routable RFC5737 façade,
# and a plain LTM virtual with a `node` iRule makes the last hop. A pool cannot hold a
# self-IP, hence `node`.
bash_cmd "tmsh modify sys db tmm.tcl.rule.connect.allow_loopback_addresses value true; tmsh modify sys db tmm.tcl.rule.node.allow_loopback_addresses value true; echo db-flags-set"
add "$B/mgmt/tm/ltm/rule" "$(jq -n --arg n "${P}-shadow-a-node" --arg b "when CLIENT_ACCEPTED {
    node ${BIGIP_A_TMUI} 443
}" '{name:$n,partition:"Common",apiAnonymous:$b}')"
mk_shadow_vs(){ # mk_shadow_vs <name> <facade-ip> <irule>
  add "$B/mgmt/tm/ltm/virtual" "$(jq -n --arg n "$1" --arg d "/$PART/$2:443" --arg ir "/$PART/$3" \
    '{name:$n,partition:"Common",destination:$d,mask:"255.255.255.255",ipProtocol:"tcp",
      profiles:[{name:"/Common/tcp"}],rules:[$ir],sourceAddressTranslation:{type:"automap"}}')"
}
mk_shadow_vs "${P}-shadow-a-vs" "$SHADOW_A" "${P}-shadow-a-node"
if mfa_have_peer; then
  add "$B/mgmt/tm/ltm/rule" "$(jq -n --arg n "${P}-shadow-b-node" --arg b "when CLIENT_ACCEPTED {
    node ${BIGIP_B_TMUI} 443
}" '{name:$n,partition:"Common",apiAnonymous:$b}')"
  mk_shadow_vs "${P}-shadow-b-vs" "$SHADOW_B" "${P}-shadow-b-node"
else
  # Converge in BOTH directions. Dropping BIGIP_B_MGMT from .env must actually remove the
  # second unit, not merely stop publishing its tile: the façade virtual and its node iRule
  # are created outside the step-2 teardown list, so nothing else would ever delete them and
  # a stale VS would keep listening on 192.0.2.6 pointing at a unit that is no longer part of
  # the deployment. The portal resource goes here too — its only referrer, the resource-assign
  # agent, was deleted in step 2, so it is free to remove.
  echo "  single unit — removing any B-side objects left by an earlier pair deployment"
  for o in "apm/resource/portal-access/~${PART}~${P}-bigip-b-tmui" \
           "ltm/virtual/~${PART}~${P}-shadow-b-vs" \
           "ltm/rule/~${PART}~${P}-shadow-b-node"; do
    curl "${A[@]}" -o /dev/null -w "  DEL ${o##*~} -> %{http_code}\n" -X DELETE "$B/mgmt/tm/${o}"
  done
fi

step "9. webtop, form SSO, and one portal resource per unit"
add "$B/mgmt/tm/apm/sso/form-based" "$(jq -n --arg n "${P}-tmui-sso" \
  '{name:$n,partition:"Common",startUri:"/tmui/login.jsp*",formAction:"/tmui/logmein.html",formUsername:"username",formPassword:"passwd",formMethod:"post",successMatchType:"url",successMatchValue:"/"}')"
add "$B/mgmt/tm/apm/resource/webtop" "$(jq -n --arg n "${P}-webtop" --arg cg "/$PART/${P}_webtop_cg" '{name:$n,partition:"Common",customizationGroup:$cg,webtopType:"full"}')"
mk_portal(){ # mk_portal <name> <facade-ip> <acl-order> <caption>
  # `items` is an ARRAY of objects each carrying a `name`, not an object keyed by item name.
  # That is the shape F5's own Postman collection uses, and it matters: in the array form the
  # nested `sso` is accepted and stored by a plain REST create, so no tmsh call is needed for
  # it. In the object form it was silently dropped, which is what sent me to tmsh originally.
  #
  # `caption` is passed but is NOT settable on this object -- it is ignored on create,
  # refused on PATCH, and absent from the tmsh property list. F5's collection does not set one
  # either; their tile labels come from webtop-section. It is left here so the intent is
  # visible rather than looking like an omission.
  #
  # The create stays 409-tolerant. Recreating would not fix the caption and WOULD destroy one
  # set by hand in the GUI, which is currently the only way to set it.
  add "$B/mgmt/tm/apm/resource/portal-access" "$(jq -n --arg n "$1" --arg h "$2" --argjson o "$3" --arg c "$4" --arg sso "/$PART/${P}-tmui-sso" \
    '{name:$n,partition:"Common",aclOrder:$o,publishOnWebtop:"true",caption:$c,
      applicationUri:("https://"+$h+"/tmui/login.jsp"),
      items:[{name:"item1",host:$h,paths:"/*",scheme:"https",port:443,sso:$sso}]}')"

  # headers is the ONE thing REST will not take, in any shape tried -- the array form is
  # rejected with `Unexpected identifier "destipaddr" "{" is required`. So exactly one tmsh
  # call survives, and it sets only headers. tmsh wants a brace block of UNNAMED entries;
  # `headers replace-all-with {...}` and `headers add {...}` are both refused with
  #   Syntax Error: "headers" you must specify either "none" or "{"
  #
  # destipaddr steers the portal engine to the facade; referer satisfies TMUI login.jsp CSRF.
  # The command is COLLECTED rather than run here: /util/bash forks a shell and loads tmsh on
  # the appliance, so a pair used to pay for two of the most expensive call this build makes.
  # They are issued together below. Do NOT fold anything else into an items-modify -- it
  # replaces the item block, and combining it with the caption breaks the parse because of the
  # parentheses in the value. Separate `tmsh modify` commands joined by `;` are fine: each is
  # its own statement and neither contains parens.
  HDR_CMDS+=("tmsh modify apm resource portal-access $1 items modify { item1 { headers { { name destipaddr value $2 } { name referer value https://$2:443 } } } }")
}

verify_portal(){ # verify_portal <name>
  # Read back from the /items SUB-COLLECTION. The parent object reports these nested fields as
  # null even when they are set correctly, which is a very convincing way to diagnose a bug
  # that does not exist.
  local got
  got=$(curl "${A[@]}" -m8 "$B/mgmt/tm/apm/resource/portal-access/~${PART}~$1/items" \
        | jq -r '.items[0] | "sso=\(.sso // "MISSING") headers=\([.headers[]?]|length)"')
  echo "  verify $1 -> $got"
  case "$got" in *"sso=MISSING"*|*"headers=0"*) echo "    ^^ portal item is incomplete" >&2 ;; esac
}

HDR_CMDS=()
mk_portal "${P}-bigip-a-tmui" "$SHADOW_A" 1 "BIG-IP A (TMUI)"
PORTALS=("/$PART/${P}-bigip-a-tmui")
if mfa_have_peer; then
  mk_portal "${P}-bigip-b-tmui" "$SHADOW_B" 2 "BIG-IP B (TMUI)"
  PORTALS+=("/$PART/${P}-bigip-b-tmui")
fi
# Every portal's headers in ONE /util/bash call, then read each back.
bash_cmd "$(printf '%s; ' "${HDR_CMDS[@]}")echo headers-set"
for p in "${PORTALS[@]}"; do verify_portal "${p##*/}"; done
add "$B/mgmt/tm/ltm/rule" "$(jq -n --arg n "${P}-referer-strip" --arg b 'when HTTP_REQUEST {
    if { [HTTP::uri] contains "tmui/login.jsp" } {
        HTTP::header remove "Referer"
    }
}' '{name:$n,partition:"Common",apiAnonymous:$b}')"
add "$B/mgmt/tm/apm/profile/connectivity" "$(jq -n --arg n "${P}-connectivity" '{name:$n,partition:"Common",defaultsFrom:"/Common/connectivity"}')"
# One tile per configured unit. The agent is in the step-2 teardown list, so this list is
# rebuilt from scratch on every run and a deployment that loses its peer loses the tile.
add "$B/mgmt/tm/apm/policy/agent/resource-assign" "$(jq -n --arg n "${P}_act_resourceassign_ag" --arg wt "/$PART/${P}-webtop" \
  --argjson pr "$(printf '%s\n' "${PORTALS[@]}" | jq -R . | jq -sc .)" \
  '{name:$n,partition:"Common",type:"general",rules:[{portalAccessResources:$pr,webtop:$wt}]}')"

step "10. policy graph (one transaction)"
TID=$(curl "${A[@]}" -X POST -H 'Content-Type: application/json' -d '{}' "$B/mgmt/tm/transaction" | jq -r '.transId')
echo "  transId=$TID"
tadd(){ local code; code=$(curl "${A[@]}" -o /tmp/wl-apm.out -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H "X-F5-REST-Coordination-Id: $TID" -d "$2" "$1")
  echo "    item -> $code"; [ "$code" = 200 ] || { echo "      $(cat /tmp/wl-apm.out)"; return 1; }
}
PI="$B/mgmt/tm/apm/policy/policy-item/"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_end_allow"),partition:"Common",caption:"Allow",color:1,itemType:"ending",agents:[{name:($p+"_end_allow_ag"),partition:"Common",type:"ending-allow"}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_end_deny"),partition:"Common",caption:"Deny",color:2,itemType:"ending",agents:[{name:($p+"_end_deny_ag"),partition:"Common",type:"ending-deny"}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_resourceassign"),partition:"Common",caption:"Resource Assign",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_resourceassign_ag"),partition:"Common",type:"resource-assign"}],
  rules:[{caption:"fallback",nextItem:("/Common/"+$p+"_end_allow")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_ssomap"),partition:"Common",caption:"SSO Credential Mapping",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_ssomap_ag"),partition:"Common",type:"variable-assign"}],
  rules:[{caption:"fallback",nextItem:("/Common/"+$p+"_act_resourceassign")}]}')"
# Keycloak Verify: one direct-grant call that proves the password AND the one-time code
# belong to the same user. Anything but a clean success is a Deny — a failed second factor
# must never degrade to first-factor-only access.
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_kcverify"),partition:"Common",caption:"MFA (TOTP)",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_kcverify_ag"),partition:"Common",type:"irule-event"}],
  rules:[{caption:"Successful",expression:"expr {[mcget {session.custom.totp.verified}] == 1}",nextItem:("/Common/"+$p+"_act_ssomap")},
         {caption:"fallback",nextItem:("/Common/"+$p+"_end_deny")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_ldapauth"),partition:"Common",caption:"LDAP Auth",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_ldapauth_ag"),partition:"Common",type:"aaa-ldap"}],
  rules:[{caption:"Successful",expression:"expr {[mcget {session.ldap.last.authresult}] == 1}",nextItem:("/Common/"+$p+"_act_kcverify")},
         {caption:"fallback",nextItem:("/Common/"+$p+"_end_deny")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_logon"),partition:"Common",caption:"Logon Page",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_logon_ag"),partition:"Common",type:"logon-page"}],
  rules:[{caption:"fallback",nextItem:("/Common/"+$p+"_act_ldapauth")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_ent"),partition:"Common",caption:"Start",color:1,itemType:"entry",loop:"false",
  rules:[{caption:"fallback",nextItem:("/Common/"+$p+"_act_logon")}]}')"
tadd "$B/mgmt/tm/apm/policy/access-policy/" "$(jq -n --arg p "$P" '{name:$p,partition:"Common",type:"access-policy",startItem:($p+"_ent"),defaultEnding:($p+"_end_deny"),maxMacroLoopCount:1,oneshotMacro:"false",
  items:[{name:($p+"_ent"),partition:"Common"},{name:($p+"_act_logon"),partition:"Common"},{name:($p+"_act_ldapauth"),partition:"Common"},{name:($p+"_act_kcverify"),partition:"Common"},{name:($p+"_act_ssomap"),partition:"Common"},{name:($p+"_act_resourceassign"),partition:"Common"},{name:($p+"_end_allow"),partition:"Common"},{name:($p+"_end_deny"),partition:"Common"}]}')"
tadd "$B/mgmt/tm/apm/profile/access/" "$(jq -n --arg p "$P" '{name:$p,partition:"Common",acceptLanguages:["en"],defaultLanguage:"en",accessPolicy:("/Common/"+$p),customizationGroup:("/Common/"+$p+"_logout"),epsGroup:("/Common/"+$p+"_eps"),errormapGroup:("/Common/"+$p+"_errormap"),frameworkInstallationGroup:("/Common/"+$p+"_framework_installation"),generalUiGroup:("/Common/"+$p+"_general_ui"),type:"all",scope:"profile",accessPolicyTimeout:300,inactivityTimeout:900,maxSessionTimeout:604800,logoutUriTimeout:5,maxConcurrentSessions:0,maxInProgressSessions:128,maxFailureDelay:5,minFailureDelay:2,secureCookie:"true",persistentCookie:"false",restrictToSingleClientIp:"false",userIdentityMethod:"http",logSettings:["/Common/default-log-setting"]}')"
echo "  committing transaction..."
curl "${A[@]}" -o /tmp/wl-apm.out -w '  commit -> %{http_code}\n' -X PATCH -H 'Content-Type: application/json' -d '{"state":"VALIDATING"}' "$B/mgmt/tm/transaction/$TID"
grep -q '"state":"COMPLETED"' /tmp/wl-apm.out || echo "  $(cat /tmp/wl-apm.out)"

step "11. the webtop virtual server ${VIP_IP}:443"
# traffic-group so the VIP floats: the access tier itself survives a failover, which is the
# point of putting it on the pair rather than beside it.
add "$B/mgmt/tm/ltm/virtual" "$(jq -n --arg n "${P}-vs" --arg d "/$PART/${VIP_IP}:443" --arg cs "/$PART/${P}-clientssl" \
  --arg ap "/$PART/$P" --arg rs "/$PART/${P}-referer-strip" --arg cp "/$PART/${P}-connectivity" --arg kc "/$PART/${P}-totp-verify" \
  '{name:$n,partition:"Common",destination:$d,mask:"255.255.255.255",ipProtocol:"tcp",
    profiles:[{name:"/Common/tcp"},{name:"/Common/http"},{name:$cs,context:"clientside"},{name:"/Common/serverssl",context:"serverside"},{name:$ap},{name:$cp},{name:"/Common/rewrite-portal"},{name:"/Common/rba"},{name:"/Common/ppp"},{name:"/Common/websso"}],
    rules:[$kc,$rs],sourceAddressTranslation:{type:"automap"}}')"
# Pin the traffic group EXPLICITLY. A virtual-address in an HA pair already defaults to
# traffic-group-1, so the webtop would float anyway — but "it happens to inherit the right
# default" is not the same claim as "the demo configures the access tier to survive a
# failover", and only the second one is worth making. Set on the virtual-address, not the
# virtual server: the address is what carries a traffic group.
# One call, not two: /util/bash is the expensive shape and these are both plain tmsh.
bash_cmd "tmsh modify ltm virtual-address ${VIP_IP} traffic-group ${MFA_APM_TRAFFIC_GROUP:-traffic-group-1}; tmsh save sys config"

echo; echo "Done. Browse https://${MFA_WEBTOP_FQDN}/ — logon page, then Keycloak for TOTP, then the webtop."
