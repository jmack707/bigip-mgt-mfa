#!/usr/bin/env bash
# Headless walk of the ENTIRE login chain, for one demo user, with no browser:
#
#   APM logon page -> LDAP Auth -> Keycloak (username + TOTP) -> back to APM -> webtop
#
# It exists because "the objects were created" and "a user can actually log in" are very
# different claims, and only the second one is worth demoing. On first run it also performs
# the TOTP enrollment Keycloak requires, printing the secret so you can add it to a real
# authenticator app and repeat the flow by hand.
#
# Usage:  scripts/demo-login.sh [username]        (default: alice.admin)
# Needs:  curl, jq, oathtool  (apt install oathtool)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
# shellcheck disable=SC1091
. "${HERE}/lib/directory.sh"

USER_ID="${1:-alice.admin}"
PW="${MFA_TEST_USER_PW}"
SECRET_FILE="${HERE}/../certs/.totp-${USER_ID}"     # gitignored with the rest of certs/
J=$(mktemp); trap 'rm -f "$J"' EXIT

WEBTOP="https://${MFA_WEBTOP_FQDN}"
CURL=(-sk -c "$J" -b "$J"
      --resolve "${MFA_WEBTOP_FQDN}:443:${MFA_APM_VIP}"
      --resolve "${MFA_KEYCLOAK_FQDN}:${MFA_KEYCLOAK_PORT}:${MFA_HOST_IP}")

ok(){  printf '  \033[32m%s\033[0m\n' "$*"; }
bad(){ printf '  \033[31m%s\033[0m\n' "$*"; exit 1; }
step(){ printf '\n\033[36m== %s ==\033[0m\n' "$*"; }

step "1. APM front door"
curl "${CURL[@]}" -o /dev/null "${WEBTOP}/" || bad "VIP unreachable"
curl "${CURL[@]}" -L -o /dev/null "${WEBTOP}/my.policy" || bad "no logon page"
ok "session established, logon page served"

step "2. logon page -> LDAP Auth"
KC_URL=$(curl "${CURL[@]}" -o /dev/null -w '%{redirect_url}' \
  -d "username=${USER_ID}" --data-urlencode "password=${PW}" -d "vhost=standard" \
  "${WEBTOP}/my.policy")
case "$KC_URL" in
  *"${MFA_KEYCLOAK_FQDN}"*) ok "password accepted, stepped up to Keycloak" ;;
  "") bad "no redirect — the password was rejected, or LDAP Auth failed (check /var/log/apm)" ;;
  *)  bad "unexpected redirect: $KC_URL" ;;
esac

step "3. Keycloak username form"
PAGE=$(curl "${CURL[@]}" -L "$KC_URL")
ACTION=$(grep -oE 'action="[^"]*login-actions/[^"]*"' <<<"$PAGE" | head -1 | sed 's/^action="//;s/"$//' | sed 's/&amp;/\&/g')
[ -n "$ACTION" ] || bad "could not find the Keycloak form action"
PAGE=$(curl "${CURL[@]}" -L -d "username=${USER_ID}" -d "credentialId=" "$ACTION")
ok "identity submitted"

step "4. TOTP"
if grep -q 'name="totpSecret"' <<<"$PAGE"; then
  RAW=$(grep -oE 'name="totpSecret"[^>]*value="[^"]*"' <<<"$PAGE" | grep -oE 'value="[^"]*"' | sed 's/^value="//;s/"$//')
  [ -n "$RAW" ] || bad "enrollment page shown but no secret found"
  # Keycloak posts back the RAW secret but the authenticator (and oathtool) want the base32
  # form — the same value Keycloak shows for manual entry. Encoding it here rather than
  # scraping the spaced display string keeps this independent of the login theme.
  SECRET=$(printf '%s' "$RAW" | base32 | tr -d '=\n')
  printf '%s' "$SECRET" > "$SECRET_FILE"; chmod 600 "$SECRET_FILE"
  echo "  first login: enrolling TOTP"
  echo "  secret (add this to an authenticator app to log in by hand): $SECRET"
  ACTION=$(grep -oE 'action="[^"]*login-actions/[^"]*"' <<<"$PAGE" | head -1 | sed 's/^action="//;s/"$//' | sed 's/&amp;/\&/g')
  CODE=$(oathtool --totp -b "$SECRET")
  [ -n "$CODE" ] || bad "could not compute a TOTP code from the enrolled secret"
  PAGE=$(curl "${CURL[@]}" -L \
    -d "totp=${CODE}" -d "userLabel=bigip-mgt-mfa-demo" --data-urlencode "totpSecret=${RAW}" "$ACTION")
  ok "enrolled and verified"
else
  [ -s "$SECRET_FILE" ] || bad "OTP required but no enrolled secret cached at ${SECRET_FILE##*/}"
  SECRET=$(cat "$SECRET_FILE")
  ACTION=$(grep -oE 'action="[^"]*login-actions/[^"]*"' <<<"$PAGE" | head -1 | sed 's/^action="//;s/"$//' | sed 's/&amp;/\&/g')
  [ -n "$ACTION" ] || bad "OTP form not found"
  CODE=$(oathtool --totp -b "$SECRET")
  # The enrollment form calls the field `totp`; the plain OTP challenge calls it `otp`.
  # Posting the wrong one is silently ignored and Keycloak just redisplays the form.
  FIELD=totp; grep -q 'name="otp"' <<<"$PAGE" && FIELD=otp
  PAGE=$(curl "${CURL[@]}" -L -w '\n%{url_effective}' -d "${FIELD}=${CODE}" "$ACTION")
  grep -q "${MFA_WEBTOP_FQDN}" <<<"$PAGE" || bad "OTP rejected — Keycloak did not redirect back to APM"
  ok "second factor accepted"
fi

step "5. webtop"
FINAL=$(curl "${CURL[@]}" -L "${WEBTOP}/")
grep -q '"pageType": *"webtop"' <<<"$FINAL" \
  && ok "webtop served (policy reached Allow)" \
  || { printf '%s' "$FINAL" > /tmp/wl-webtop.html; bad "did not land on the webtop — dump in /tmp/wl-webtop.html"; }

step "6. resources assigned to the session"
# Asserted against the BIG-IP session table, not the returned HTML: the modern webtop loads
# its resource list asynchronously, so scraping the first response reports "no resources"
# even on a perfectly good session. session.assigned.resources.pa is the authoritative answer.
DUMP=$(curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" -X POST -H 'Content-Type: application/json' \
  "https://${BIGIP_A_MGMT}/mgmt/tm/util/bash" \
  -d '{"command":"run","utilCmdArgs":"-c \"sessiondump --allkeys 2>/dev/null | grep assigned.resources.pa | tail -1\""}' \
  | jq -r '.commandResult // ""')
FOUND=0
grep -q 'bigip-mgt-mfa-bigip-a-tmui' <<<"$DUMP" && { ok "BIG-IP A TMUI published to the webtop"; FOUND=$((FOUND+1)); }
grep -q 'bigip-mgt-mfa-bigip-b-tmui' <<<"$DUMP" && { ok "BIG-IP B TMUI published to the webtop"; FOUND=$((FOUND+1)); }
[ "$FOUND" = 2 ] || bad "expected both TMUI resources on the session, got: ${DUMP:-<empty>}"

printf '\n\033[32m%s: password -> LDAP -> Keycloak TOTP -> webtop, with both BIG-IPs published.\033[0m\n' "$USER_ID"
