#!/usr/bin/env bash
# The APM front door. Builds the whole access tier on ONE unit; config-sync carries it to
# the peer (deploy.sh triggers the sync).
#
# Policy graph:
#   Start -> Logon Page -> LDAP Auth -> OAuth Client (Keycloak, TOTP) -> SSO Credential
#            Mapping -> Resource Assign -> Allow
#   any failure -> Deny
#
# The ordering is the whole design. APM collects the password and proves it against the
# directory FIRST, which means the password is in the session and can be single-signed-on
# to TMUI. Only then does it step up to Keycloak for the second factor. Reverse the order
# (Keycloak first, as a plain OIDC relying party) and APM never sees a password, which is
# why that design needs a vault. See docs/adr/0001-apm-first-auth-order.md.
#
# Idempotent: the mutable policy graph is torn down and rebuilt; everything else tolerates
# 409 (already exists).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
_PASS_IN="${BIGIP_PASS:-}"; set -a; . "${HERE}/../.env"; set +a
# shellcheck disable=SC1091
. "${HERE}/../scripts/lib/directory.sh"
# shellcheck disable=SC1091
. "${HERE}/lib/objects.sh"
[ -n "$_PASS_IN" ] && BIGIP_PASS="$_PASS_IN"
: "${BIGIP_PASS:?export BIGIP_PASS}"; : "${WL_BIND_PW:?need WL_BIND_PW}"
: "${BIGIP_MGMT:=${BIGIP_A_MGMT:?set BIGIP_A_MGMT}}"

B="https://${BIGIP_MGMT}"; A=(-sk -u "${BIGIP_USER}:${BIGIP_PASS}")
P=warden-lite                     # object-name prefix / access-profile name
PART=Common
AAA=${P}-ldap-aaa
VIP_IP="${WL_APM_VIP:?set WL_APM_VIP in .env}"
SHADOW_A="${WL_SHADOW_A:-192.0.2.5}"
SHADOW_B="${WL_SHADOW_B:-192.0.2.6}"
RESOLVER=${P}-resolver
PROVIDER=${P}-keycloak
OAUTH_SRV=${P}-oauth-server
KC_BASE="https://${WL_KEYCLOAK_FQDN}:${WL_KEYCLOAK_PORT}/realms/${WL_KEYCLOAK_REALM}"

step(){ echo; echo "== $* =="; }
add(){ # add <url> <json> — additive POST tolerating 409
  local code; code=$(curl "${A[@]}" -o /tmp/wl-apm.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$2" "$1")
  echo "  POST ${1##*/tm/} -> $code"
  case "$code" in 200|201|409) ;; *) echo "    $(cat /tmp/wl-apm.out)"; return 1;; esac
}
bash_cmd(){ # bash_cmd <tmsh-or-shell> — run via /tm/util/bash, print commandResult
  curl "${A[@]}" -X POST -H 'Content-Type: application/json' "$B/mgmt/tm/util/bash" \
    -d "$(jq -n --arg u "-c '$1'" '{command:"run",utilCmdArgs:$u}')" | jq -r '.commandResult // "  (ok)"'
}
upload(){ # upload <local-file> <remote-name>
  local sz; sz=$(stat -c%s "$1")
  curl "${A[@]}" -X POST -H "Content-Type: application/octet-stream" \
    -H "Content-Range: 0-$((sz-1))/${sz}" --data-binary @"$1" \
    "$B/mgmt/shared/file-transfer/uploads/$2" -o /dev/null -w "  upload $2 -> %{http_code}\n"
}

step "1. VIP server certificate (${WL_WEBTOP_FQDN})"
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
while IFS= read -r o; do td "$B/mgmt/tm/${o}"; done < <(wl_apm_objects "$P" "$PART")

step "3. AAA LDAP server (password check happens here, by BIND)"
# TMOS 21.x APM AAA LDAP requires a server POOL — a bare address is rejected. Single-quote
# wrap so the DN commas pass through tmsh intact.
bash_cmd "tmsh create ltm pool ${AAA}-pool { members add { ${WL_LDAP_HOST}:${WL_LDAP_PORT} } monitor tcp } ; tmsh create apm aaa ldap ${AAA} { pool ${AAA}-pool port ${WL_LDAP_PORT} admin-dn \"${WL_BIND_DN}\" admin-encrypted-password \"${WL_BIND_PW}\" base-dn \"${WL_USER_SEARCH_BASE}\" }"

step "4. DNS resolver -> the demo zone (CoreDNS on the stack host)"
# TMM resolves OAuth endpoints itself and does NOT read the BIG-IP's /etc/hosts, so the
# resolver is mandatory, not a nicety. warden-lite ships the DNS server it points at.
bash_cmd "tmsh create net dns-resolver ${RESOLVER} { forward-zones add { ${WL_DOMAIN} { nameservers add { ${WL_HOST_IP}:${WL_DNS_PORT:-53} } } } route-domain 0 }"

step "5. OAuth provider + server (Keycloak as the second factor)"
bash_cmd "tmsh create apm aaa oauth-provider ${PROVIDER} { type custom authentication-uri ${KC_BASE}/protocol/openid-connect/auth token-uri ${KC_BASE}/protocol/openid-connect/token userinfo-request-uri ${KC_BASE}/protocol/openid-connect/userinfo openid-cfg-uri ${KC_BASE}/.well-known/openid-configuration trusted-ca-bundle /Common/${P}-ca.crt use-auto-jwt-config true }"
# Our own request objects: the shipped templates are vendor-shaped (Okta/Ping carry
# offline_access, the F5 ones carry a token_content_type Keycloak does not use). These are
# plain OIDC authorization-code. APM appends `code` to the token request itself.
# `type` is not optional: it tells TMOS which leg of the exchange the object describes, and
# omitting it makes the object default to scope-data-request, which then fails validation
# demanding a URI. The URI itself comes from the provider, so it stays `none` here.
# The scope parameter carries NO value: APM substitutes the scope configured on the agent.
# Setting it in both places is what produces `scope=openid openid` on the wire.
# delete-then-create so a re-run converges (tmsh create alone is not idempotent).
bash_cmd "tmsh delete apm aaa oauth-request ${P}-auth-redirect 2>/dev/null; tmsh create apm aaa oauth-request ${P}-auth-redirect { type auth-redirect-request method get parameters add { client_id { type client-id } redirect_uri { type redirect-uri } response_type { type response-type } scope { type scope } } }"
bash_cmd "tmsh delete apm aaa oauth-request ${P}-token-by-code 2>/dev/null; tmsh create apm aaa oauth-request ${P}-token-by-code { type token-request method post parameters add { client_id { type client-id } client_secret { type client-secret } grant_type { type grant-type } redirect_uri { type redirect-uri } } }"
bash_cmd "tmsh delete apm aaa oauth-request ${P}-token-refresh 2>/dev/null; tmsh create apm aaa oauth-request ${P}-token-refresh { type token-refresh-request method post parameters add { client_id { type client-id } client_secret { type client-secret } grant_type { type custom value refresh_token } } }"
bash_cmd "tmsh create apm aaa oauth-server ${OAUTH_SRV} { mode client provider-name ${PROVIDER} client-id ${WL_OIDC_CLIENT_ID} client-secret ${WL_OIDC_CLIENT_SECRET} dns-resolver-name ${RESOLVER} client-serverssl-profile-name /Common/${P}-serverssl-oauth }"

step "6. customization groups"
add "$B/mgmt/tm/apm/policy/customization-group" "$(jq -n --arg n "${P}_act_logon_ag" '{name:$n,partition:"Common",source:"/Common/modern",type:"logon"}')"
add "$B/mgmt/tm/apm/policy/customization-group" "$(jq -n --arg n "${P}_end_deny_ag" '{name:$n,partition:"Common",source:"/Common/modern",type:"logout"}')"
add "$B/mgmt/tm/apm/policy/customization-group" "$(jq -n --arg n "${P}_webtop_cg" '{name:$n,partition:"Common",source:"/Common/modern",type:"webtop"}')"
for grp in logout:logout eps:eps errormap:errormap framework_installation:framework-installation general_ui:general-ui; do
  add "$B/mgmt/tm/apm/policy/customization-group" "$(jq -n --arg n "${P}_${grp%%:*}" --arg t "${grp##*:}" '{name:$n,partition:"Common",source:"/Common/modern",type:$t}')"
done

step "7. agents: logon page, LDAP auth, OAuth client, SSO mapping, resource assign"
add "$B/mgmt/tm/apm/policy/agent/logon-page" "$(jq -n --arg n "${P}_act_logon_ag" --arg cg "/$PART/${P}_act_logon_ag" \
  '{name:$n,partition:"Common",customizationGroup:$cg,
    fieldType1:"text",postVarName1:"username",sessionVarName1:"username",fieldModifiable1:"true",
    fieldType2:"password",postVarName2:"password",sessionVarName2:"password",fieldModifiable2:"true"}')"
# LDAP Auth (type=auth): APM locates the entry with the filter, then BINDS as that user to
# prove the password. Nothing reads a password hash, which is why the bind account needs no
# privilege beyond search.
add "$B/mgmt/tm/apm/policy/agent/aaa-ldap" "$(jq -n --arg n "${P}_act_ldapauth_ag" --arg s "/$PART/$AAA" \
  --arg base "${WL_USER_SEARCH_BASE}" --arg f "(${WL_LOGIN_ATTR}=%{session.logon.last.username})" \
  '{name:$n,partition:"Common",type:"auth",server:$s,searchDn:$base,filter:$f,maxLogonAttempt:3}')"
add "$B/mgmt/tm/apm/policy/agent/aaa-oauth" "$(jq -n --arg n "${P}_act_oauth_ag" --arg s "/$PART/${OAUTH_SRV}" \
  --arg ar "/$PART/${P}-auth-redirect" --arg tr "/$PART/${P}-token-by-code" --arg rr "/$PART/${P}-token-refresh" \
  --arg ru "https://${WL_WEBTOP_FQDN}/oauth/client/redirect" \
  '{name:$n,partition:"Common",type:"client",grantType:"authorization-code",server:$s,
    authRedirectRequest:$ar,tokenRequest:$tr,tokenRefreshRequest:$rr,
    redirectionUri:$ru,scope:"openid"}')"
# SSO Credential Mapping: hand the webtop resources the credential the user already proved.
# This is the entire "single sign-on" of the demo — no vault, no shared account.
add "$B/mgmt/tm/apm/policy/agent/variable-assign" "$(jq -n --arg n "${P}_act_ssomap_ag" \
  '{name:$n,partition:"Common",type:"sso-cred-mapping",variables:[
     {varname:"session.sso.token.last.username",expression:"mcget {session.logon.last.username}"},
     {varname:"session.sso.token.last.password",expression:"mcget -secure {session.logon.last.password}",secure:"true"}]}')"
add "$B/mgmt/tm/apm/policy/agent/ending-allow" "$(jq -n --arg n "${P}_end_allow_ag" '{name:$n,partition:"Common"}')"
add "$B/mgmt/tm/apm/policy/agent/ending-deny" "$(jq -n --arg n "${P}_end_deny_ag" --arg cg "/$PART/${P}_end_deny_ag" '{name:$n,partition:"Common",customizationGroup:$cg}')"

step "8. shadow façades for the two TMUIs"
# APM portal access refuses "reserved" targets — self-IPs, the management address, cluster
# addresses — with 01490585/errorcode=17, and publishing TMUI on a routable external self-IP
# would be a hole anyway. So each unit's TMUI is fronted by a non-routable RFC5737 façade,
# and a plain LTM virtual with a `node` iRule makes the last hop. A pool cannot hold a
# self-IP, hence `node`.
bash_cmd "tmsh modify sys db tmm.tcl.rule.connect.allow_loopback_addresses value true; tmsh modify sys db tmm.tcl.rule.node.allow_loopback_addresses value true; echo db-flags-set"
add "$B/mgmt/tm/ltm/rule" "$(jq -n --arg n "${P}-shadow-a-node" --arg b "when CLIENT_ACCEPTED {
    node ${BIGIP_A_TMUI} 443
}" '{name:$n,partition:"Common",apiAnonymous:$b}')"
add "$B/mgmt/tm/ltm/rule" "$(jq -n --arg n "${P}-shadow-b-node" --arg b "when CLIENT_ACCEPTED {
    node ${BIGIP_B_TMUI} 443
}" '{name:$n,partition:"Common",apiAnonymous:$b}')"
mk_shadow_vs(){ # mk_shadow_vs <name> <facade-ip> <irule>
  add "$B/mgmt/tm/ltm/virtual" "$(jq -n --arg n "$1" --arg d "/$PART/$2:443" --arg ir "/$PART/$3" \
    '{name:$n,partition:"Common",destination:$d,mask:"255.255.255.255",ipProtocol:"tcp",
      profiles:[{name:"/Common/tcp"}],rules:[$ir],sourceAddressTranslation:{type:"automap"}}')"
}
mk_shadow_vs "${P}-shadow-a-vs" "$SHADOW_A" "${P}-shadow-a-node"
mk_shadow_vs "${P}-shadow-b-vs" "$SHADOW_B" "${P}-shadow-b-node"

step "9. webtop, form SSO, and one portal resource per unit"
add "$B/mgmt/tm/apm/sso/form-based" "$(jq -n --arg n "${P}-tmui-sso" \
  '{name:$n,partition:"Common",startUri:"/tmui/login.jsp*",formAction:"/tmui/logmein.html",formUsername:"username",formPassword:"passwd",formMethod:"post",successMatchType:"url",successMatchValue:"/"}')"
add "$B/mgmt/tm/apm/resource/webtop" "$(jq -n --arg n "${P}-webtop" --arg cg "/$PART/${P}_webtop_cg" '{name:$n,partition:"Common",customizationGroup:$cg,webtopType:"full"}')"
mk_portal(){ # mk_portal <name> <facade-ip> <acl-order> <caption>
  add "$B/mgmt/tm/apm/resource/portal-access" "$(jq -n --arg n "$1" --arg h "$2" --argjson o "$3" --arg c "$4" --arg sso "/$PART/${P}-tmui-sso" \
    '{name:$n,partition:"Common",aclOrder:$o,publishOnWebtop:"true",caption:$c,
      applicationUri:("https://"+$h+"/tmui/login.jsp"),
      items:{item1:{host:$h,paths:"/*",scheme:"https",port:443,sso:$sso}}}')"
  # destipaddr steers the portal engine to the façade; referer satisfies TMUI login.jsp CSRF.
  # Both are header_data_t values the REST body cannot express, so tmsh sets them.
  # caption is what the user actually reads on the webtop tile; it does not take via the
  # REST body, so set it here alongside the headers.
  bash_cmd "tmsh modify apm resource portal-access $1 caption \"$4\" items modify { item1 { headers { { name destipaddr value $2 } { name referer value https://$2:443 } } } }"
}
mk_portal "${P}-bigip-a-tmui" "$SHADOW_A" 1 "BIG-IP A (TMUI)"
mk_portal "${P}-bigip-b-tmui" "$SHADOW_B" 2 "BIG-IP B (TMUI)"
add "$B/mgmt/tm/ltm/rule" "$(jq -n --arg n "${P}-referer-strip" --arg b 'when HTTP_REQUEST {
    if { [HTTP::uri] contains "tmui/login.jsp" } {
        HTTP::header remove "Referer"
    }
}' '{name:$n,partition:"Common",apiAnonymous:$b}')"
add "$B/mgmt/tm/apm/profile/connectivity" "$(jq -n --arg n "${P}-connectivity" '{name:$n,partition:"Common",defaultsFrom:"/Common/connectivity"}')"
add "$B/mgmt/tm/apm/policy/agent/resource-assign" "$(jq -n --arg n "${P}_act_resourceassign_ag" --arg wt "/$PART/${P}-webtop" \
  --arg pa "/$PART/${P}-bigip-a-tmui" --arg pb "/$PART/${P}-bigip-b-tmui" \
  '{name:$n,partition:"Common",type:"general",rules:[{portalAccessResources:[$pa,$pb],webtop:$wt}]}')"

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
# OAuth Client: Keycloak has verified the TOTP. Anything other than a successful token
# exchange is a Deny — a failed second factor must not degrade to first-factor-only access.
# `eq {}` rather than the VPE's usual `== ""`: an empty double-quoted literal does not
# survive the trip through REST into the stored rule, and what lands on the box is
# `... == ` — a Tcl syntax error that fails the branch and denies every successful login.
# Braces carry an empty string through intact.
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_oauth"),partition:"Common",caption:"MFA (Keycloak OIDC)",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_oauth_ag"),partition:"Common",type:"aaa-oauth"}],
  rules:[{caption:"Successful",expression:"expr {[mcget {session.oauth.client.last.errMsg}] eq {}}",nextItem:("/Common/"+$p+"_act_ssomap")},
         {caption:"fallback",nextItem:("/Common/"+$p+"_end_deny")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_ldapauth"),partition:"Common",caption:"LDAP Auth",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_ldapauth_ag"),partition:"Common",type:"aaa-ldap"}],
  rules:[{caption:"Successful",expression:"expr {[mcget {session.ldap.last.authresult}] == 1}",nextItem:("/Common/"+$p+"_act_oauth")},
         {caption:"fallback",nextItem:("/Common/"+$p+"_end_deny")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_act_logon"),partition:"Common",caption:"Logon Page",color:1,itemType:"action",loop:"false",
  agents:[{name:($p+"_act_logon_ag"),partition:"Common",type:"logon-page"}],
  rules:[{caption:"fallback",nextItem:("/Common/"+$p+"_act_ldapauth")}]}')"
tadd "$PI" "$(jq -n --arg p "$P" '{name:($p+"_ent"),partition:"Common",caption:"Start",color:1,itemType:"entry",loop:"false",
  rules:[{caption:"fallback",nextItem:("/Common/"+$p+"_act_logon")}]}')"
tadd "$B/mgmt/tm/apm/policy/access-policy/" "$(jq -n --arg p "$P" '{name:$p,partition:"Common",type:"access-policy",startItem:($p+"_ent"),defaultEnding:($p+"_end_deny"),maxMacroLoopCount:1,oneshotMacro:"false",
  items:[{name:($p+"_ent"),partition:"Common"},{name:($p+"_act_logon"),partition:"Common"},{name:($p+"_act_ldapauth"),partition:"Common"},{name:($p+"_act_oauth"),partition:"Common"},{name:($p+"_act_ssomap"),partition:"Common"},{name:($p+"_act_resourceassign"),partition:"Common"},{name:($p+"_end_allow"),partition:"Common"},{name:($p+"_end_deny"),partition:"Common"}]}')"
tadd "$B/mgmt/tm/apm/profile/access/" "$(jq -n --arg p "$P" '{name:$p,partition:"Common",acceptLanguages:["en"],defaultLanguage:"en",accessPolicy:("/Common/"+$p),customizationGroup:("/Common/"+$p+"_logout"),epsGroup:("/Common/"+$p+"_eps"),errormapGroup:("/Common/"+$p+"_errormap"),frameworkInstallationGroup:("/Common/"+$p+"_framework_installation"),generalUiGroup:("/Common/"+$p+"_general_ui"),type:"all",scope:"profile",accessPolicyTimeout:300,inactivityTimeout:900,maxSessionTimeout:604800,logoutUriTimeout:5,maxConcurrentSessions:0,maxInProgressSessions:128,maxFailureDelay:5,minFailureDelay:2,secureCookie:"true",persistentCookie:"false",restrictToSingleClientIp:"false",userIdentityMethod:"http",logSettings:["/Common/default-log-setting"]}')"
echo "  committing transaction..."
curl "${A[@]}" -o /tmp/wl-apm.out -w '  commit -> %{http_code}\n' -X PATCH -H 'Content-Type: application/json' -d '{"state":"VALIDATING"}' "$B/mgmt/tm/transaction/$TID"
grep -q '"state":"COMPLETED"' /tmp/wl-apm.out || echo "  $(cat /tmp/wl-apm.out)"

step "11. the webtop virtual server ${VIP_IP}:443"
# traffic-group so the VIP floats: the access tier itself survives a failover, which is the
# point of putting it on the pair rather than beside it.
add "$B/mgmt/tm/ltm/virtual" "$(jq -n --arg n "${P}-vs" --arg d "/$PART/${VIP_IP}:443" --arg cs "/$PART/${P}-clientssl" \
  --arg ap "/$PART/$P" --arg rs "/$PART/${P}-referer-strip" --arg cp "/$PART/${P}-connectivity" \
  '{name:$n,partition:"Common",destination:$d,mask:"255.255.255.255",ipProtocol:"tcp",
    profiles:[{name:"/Common/tcp"},{name:"/Common/http"},{name:$cs,context:"clientside"},{name:"/Common/serverssl",context:"serverside"},{name:$ap},{name:$cp},{name:"/Common/rewrite-portal"},{name:"/Common/rba"},{name:"/Common/ppp"},{name:"/Common/websso"}],
    rules:[$rs],sourceAddressTranslation:{type:"automap"}}')"
bash_cmd "tmsh save sys config"

echo; echo "Done. Browse https://${WL_WEBTOP_FQDN}/ — logon page, then Keycloak for TOTP, then the webtop."
