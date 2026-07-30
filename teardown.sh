#!/usr/bin/env bash
# Remove what warden-lite created. Two halves, mirroring deploy.sh:
#
#   ./teardown.sh --stack    stop the containers. Add --volumes to delete their data, which
#                            DESTROYS every enrolled TOTP secret.
#   ./teardown.sh --bigip    delete the APM objects and restore local-only admin auth on
#                            BOTH units.
#   ./teardown.sh            both.
#
# The BIG-IP half is deliberately conservative: it removes the access tier and returns the
# appliances to local authentication, but leaves the trust anchors and the demo CA in place.
# Those are inert on their own and removing them is not worth the chance of disturbing
# something else on a shared lab appliance.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

[ -f .env ] || { echo "no .env — nothing to tear down" >&2; exit 1; }
_PASS_IN="${BIGIP_PASS:-}"
set -a; . ./.env; set +a
[ -n "$_PASS_IN" ] && BIGIP_PASS="$_PASS_IN"
# shellcheck disable=SC1091
. scripts/lib/directory.sh
# shellcheck disable=SC1091
. bigip/lib/objects.sh

DO_STACK=0; DO_BIGIP=0; VOLUMES=0
for a in "${@:---all}"; do
  case "$a" in
    --stack) DO_STACK=1;;
    --bigip) DO_BIGIP=1;;
    --volumes) VOLUMES=1;;
    --all) DO_STACK=1; DO_BIGIP=1;;
    -h|--help) sed -n '2,14p' "$0"; exit 0;;
    *) echo "usage: $0 [--stack|--bigip] [--volumes]" >&2; exit 2;;
  esac
done
[ "$DO_STACK$DO_BIGIP" = "00" ] && { DO_STACK=1; DO_BIGIP=1; }

say(){ printf '\n\033[36m==> %s\033[0m\n' "$*"; }

if [ "$DO_BIGIP" = 1 ]; then
  : "${BIGIP_PASS:?set BIGIP_PASS}"
  P=warden-lite; PART=Common
  for unit in "${BIGIP_A_MGMT}" "${BIGIP_B_MGMT}"; do
    say "restoring local authentication on ${unit}"
    # First, so that a failure later cannot leave the unit pointed at a directory that is
    # about to disappear. admin and root are local accounts, so this cannot lock anyone out.
    curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" -o /dev/null -w '  auth source -> %{http_code}\n' \
      -X PATCH -H 'Content-Type: application/json' -d '{"type":"local"}' \
      "https://${unit}/mgmt/tm/auth/source"
    curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" -o /dev/null -w '  remote-role  -> %{http_code}\n' \
      -X DELETE "https://${unit}/mgmt/tm/auth/remote-role/role-info/warden_lite_admins"
  done

  say "deleting the APM access tier on ${BIGIP_A_MGMT}"
  B="https://${BIGIP_A_MGMT}"; A=(-sk -u "${BIGIP_USER}:${BIGIP_PASS}")
  # Same list the build uses, so the two cannot drift.
  while IFS= read -r o; do
    curl "${A[@]}" -o /dev/null -w "  DEL ${o##*~} -> %{http_code}\n" -X DELETE "$B/mgmt/tm/${o}"
  done < <(wl_apm_objects "$P" "$PART")
  # Then the supporting objects the build creates outside that list.
  for o in \
    "ltm/virtual/~${PART}~${P}-shadow-a-vs" "ltm/virtual/~${PART}~${P}-shadow-b-vs" \
    "apm/resource/portal-access/~${PART}~${P}-bigip-a-tmui" \
    "apm/resource/portal-access/~${PART}~${P}-bigip-b-tmui" \
    "apm/resource/webtop/~${PART}~${P}-webtop" \
    "apm/sso/form-based/~${PART}~${P}-tmui-sso" \
    "apm/profile/connectivity/~${PART}~${P}-connectivity" \
    "ltm/rule/~${PART}~${P}-shadow-a-node" "ltm/rule/~${PART}~${P}-shadow-b-node" \
    "ltm/rule/~${PART}~${P}-referer-strip" \
    "apm/aaa/oauth-server/~${PART}~${P}-oauth-server" \
    "apm/aaa/oauth-request/~${PART}~${P}-auth-redirect" \
    "apm/aaa/oauth-request/~${PART}~${P}-token-by-code" \
    "apm/aaa/oauth-request/~${PART}~${P}-token-refresh" \
    "apm/aaa/oauth-provider/~${PART}~${P}-keycloak" \
    "apm/aaa/ldap/~${PART}~${P}-ldap-aaa" "ltm/pool/~${PART}~${P}-ldap-aaa-pool" \
    "net/dns-resolver/~${PART}~${P}-resolver" \
    "ltm/profile/client-ssl/~${PART}~${P}-clientssl" \
    "ltm/profile/server-ssl/~${PART}~${P}-serverssl-oauth" ; do
    curl "${A[@]}" -o /dev/null -w "  DEL ${o##*~} -> %{http_code}\n" -X DELETE "$B/mgmt/tm/${o}"
  done
  curl "${A[@]}" -o /dev/null -X POST -H 'Content-Type: application/json' \
    -d '{"command":"save"}' "$B/mgmt/tm/sys/config"

  DG="${WL_DEVICE_GROUP:-}"
  [ -z "$DG" ] && DG=$(curl "${A[@]}" "$B/mgmt/tm/cm/device-group" \
      | jq -r '[.items[]? | select(.type=="sync-failover") | .name] | first // empty')
  if [ -n "$DG" ]; then
    say "config-sync to ${DG}"
    curl "${A[@]}" -X POST -H 'Content-Type: application/json' "$B/mgmt/tm/util/bash" \
      -d "$(jq -n --arg u "-c 'tmsh run cm config-sync to-group ${DG} 2>&1 | tail -1'" '{command:"run",utilCmdArgs:$u}')" \
      | jq -r '.commandResult // "  sync requested"'
  fi
fi

if [ "$DO_STACK" = 1 ]; then
  say "stopping containers"
  if [ "$VOLUMES" = 1 ]; then
    echo "  --volumes: deleting data, including every enrolled TOTP secret"
    docker compose --profile bundled down -v
    rm -f certs/.totp-* 2>/dev/null || true
  else
    docker compose --profile bundled down
    echo "  volumes kept — re-running ./deploy.sh --stack restores the same directory and enrolments"
  fi
fi

say "done"
