#!/usr/bin/env bash
# Reconcile the running Keycloak realm with what this repo declares.
#
# Why this exists: `--import-realm` only applies when the realm does not yet exist. Every
# redeploy after the first would otherwise silently run against whatever the realm looked
# like before, so editing the template would appear to do nothing. Wiping the kcdata volume
# would fix that by destroying every enrolled authenticator, which is not a fix.
#
# So the import handles first creation and this handles convergence. It is idempotent, and
# it only touches the objects bigip-mgt-mfa owns: the direct-grant flow, the realm's flow
# bindings, and the client's enabled grant types.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a

KC="https://${MFA_KEYCLOAK_FQDN}:${MFA_KEYCLOAK_PORT}"
R=(--resolve "${MFA_KEYCLOAK_FQDN}:${MFA_KEYCLOAK_PORT}:${MFA_HOST_IP}" -sk)
REALM="${MFA_KEYCLOAK_REALM}"
FLOW="bigip-mgt-mfa direct grant"

say(){ printf '  %s\n' "$*"; }
die(){ printf '\033[31m  error: %s\033[0m\n' "$*" >&2; exit 1; }

TOK=$(curl "${R[@]}" -m10 -d client_id=admin-cli -d "username=${MFA_KEYCLOAK_ADMIN}" \
      --data-urlencode "password=${MFA_KEYCLOAK_ADMIN_PW}" -d grant_type=password \
      "$KC/realms/master/protocol/openid-connect/token" | jq -r '.access_token // empty')
[ -n "$TOK" ] || die "cannot authenticate to the Keycloak admin API"
API(){ curl "${R[@]}" -m15 -H "Authorization: Bearer $TOK" "$@"; }
AJ(){  API -H 'Content-Type: application/json' "$@"; }

# 1. the direct-grant flow: username + password + OTP, all REQUIRED.
if API "$KC/admin/realms/${REALM}/authentication/flows" | jq -e --arg f "$FLOW" '.[]|select(.alias==$f)' >/dev/null 2>&1; then
  say "flow '${FLOW}' present"
else
  AJ -X POST -o /dev/null -w '  create flow -> %{http_code}\n' \
    -d "$(jq -n --arg a "$FLOW" '{alias:$a,description:"username + password + OTP validated together, for the BIG-IP APM logon page",providerId:"basic-flow",topLevel:true,builtIn:false}')" \
    "$KC/admin/realms/${REALM}/authentication/flows"
  # Executions are added by provider id, then each is set to REQUIRED. Order of addition is
  # the order of evaluation, so username must precede password must precede otp.
  for prov in direct-grant-validate-username direct-grant-validate-password direct-grant-validate-otp; do
    AJ -X POST -o /dev/null -w "  + ${prov} -> %{http_code}\n" \
      -d "$(jq -n --arg p "$prov" '{provider:$p}')" \
      "$KC/admin/realms/${REALM}/authentication/flows/$(printf '%s' "$FLOW" | jq -sRr @uri)/executions/execution"
  done
fi

# Force every execution in the flow to REQUIRED. The stock direct-grant flow makes OTP
# CONDITIONAL, which lets a user who has not enrolled through on a password alone — the
# whole point of this flow is that the second factor cannot be skipped.
EXECS=$(API "$KC/admin/realms/${REALM}/authentication/flows/$(printf '%s' "$FLOW" | jq -sRr @uri)/executions")
echo "$EXECS" | jq -c '.[]' | while read -r e; do
  req=$(jq -r '.requirement' <<<"$e")
  [ "$req" = REQUIRED ] && continue
  AJ -X PUT -o /dev/null -w "  set $(jq -r '.displayName' <<<"$e") REQUIRED -> %{http_code}\n" \
    -d "$(jq -c '.requirement="REQUIRED"' <<<"$e")" \
    "$KC/admin/realms/${REALM}/authentication/flows/$(printf '%s' "$FLOW" | jq -sRr @uri)/executions"
done

# 2. bind the realm: our flow for direct grant, the stock one for the browser (the Account
#    Console, where users enrol their authenticator, must remain an ordinary login).
AJ -X PUT -o /dev/null -w '  realm flow bindings -> %{http_code}\n' \
  -d "$(jq -n --arg f "$FLOW" '{directGrantFlow:$f,browserFlow:"browser"}')" \
  "$KC/admin/realms/${REALM}"

# 3. the client: direct grant on, authorization-code off (APM never redirects a browser here).
CID=$(API "$KC/admin/realms/${REALM}/clients?clientId=${MFA_OIDC_CLIENT_ID}" | jq -r '.[0].id // empty')
[ -n "$CID" ] || die "client ${MFA_OIDC_CLIENT_ID} not found in realm ${REALM}"
AJ -X PUT -o /dev/null -w '  client grant types -> %{http_code}\n' \
  -d "$(jq -n --arg s "${MFA_OIDC_CLIENT_SECRET}" '{directAccessGrantsEnabled:true,standardFlowEnabled:false,publicClient:false,secret:$s}')" \
  "$KC/admin/realms/${REALM}/clients/${CID}"

say "realm ${REALM} reconciled"
