#!/usr/bin/env bash
# warden-lite deployer. Two halves, deliberately separable:
#
#   ./deploy.sh --stack    Keycloak + the directory, in Docker. Touches NO BIG-IP. Prove
#                          this half works before pointing anything at your appliances.
#   ./deploy.sh --bigip    the BIG-IP half: trust anchors, remote-role on both units, and
#                          the APM access policy on unit A (config-sync carries it
#                          to the peer).
#   ./deploy.sh            both, in that order.
#
# Re-running is safe: certs are reused unless WL_REGEN_CA=1, LDAP seeding tolerates
# "already exists", and the APM build tears down and rebuilds only the mutable policy graph.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

[ -f .env ] || { echo "no .env — copy .env.example and fill it in" >&2; exit 1; }
_PASS_IN="${BIGIP_PASS:-}"
set -a; . ./.env; set +a
[ -n "$_PASS_IN" ] && BIGIP_PASS="$_PASS_IN"     # an injected secret beats the file
# shellcheck disable=SC1091
. scripts/lib/directory.sh

DO_STACK=0; DO_BIGIP=0
case "${1:-all}" in
  --stack) DO_STACK=1;;
  --bigip) DO_BIGIP=1;;
  all|--all) DO_STACK=1; DO_BIGIP=1;;
  -h|--help) sed -n '2,12p' "$0"; exit 0;;
  *) echo "usage: $0 [--stack|--bigip]" >&2; exit 2;;
esac

say(){ printf '\n\033[36m==> %s\033[0m\n' "$*"; }
die(){ printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need openssl; need jq; need envsubst; need curl
docker compose version >/dev/null 2>&1 || die "needs the docker compose V2 plugin ('docker compose'), not the standalone v1 binary"

# ── the Docker half ─────────────────────────────────────────────────────────
if [ "$DO_STACK" = 1 ]; then
  say "directory model"
  wl_directory_summary

  say "certificates (CA, Keycloak, webtop VIP$(wl_is_bundled && echo ", LDAPS"))"
  scripts/gen-certs.sh

  say "rendering the demo DNS zone"
  envsubst < dns/Corefile.tmpl > dns/Corefile
  echo "  ${WL_KEYCLOAK_FQDN} -> ${WL_HOST_IP};  ${WL_WEBTOP_FQDN} -> ${WL_APM_VIP}"

  say "rendering the Keycloak realm"
  mkdir -p keycloak/import
  # Two transforms. envsubst fills our placeholders (the realm JSON has no other $ syntax to
  # protect). jq then strips every "_comment*" key: the template carries its rationale inline
  # where the config is, but Keycloak's importer rejects unknown fields outright rather than
  # ignoring them, so the comments must not reach it.
  envsubst < keycloak/warden-lite-realm.json.tmpl \
    | jq 'walk(if type == "object" then with_entries(select(.key | startswith("_comment") | not)) else . end)' \
    > keycloak/import/warden-lite-realm.json \
    || die "rendered realm is not valid JSON — check for unset variables in .env"
  echo "  keycloak/import/warden-lite-realm.json"

  say "starting containers"
  if wl_is_bundled; then
    docker compose --profile bundled up -d
  else
    docker compose up -d
  fi

  # `up -d` will not recreate a service whose definition has not changed, and Keycloak and
  # OpenLDAP read their certificate files once at process start. So when gen-certs.sh has
  # actually re-issued a leaf certificate, the running containers are still serving the old
  # one and must be restarted explicitly — otherwise the CA on disk and the certificate on
  # the wire disagree, and the BIG-IP's back-channel validation fails for reasons nothing
  # in the logs connects to a certificate.
  if [ -f certs/.reissued ]; then
    say "certificates were re-issued — restarting the services that present them"
    if wl_is_bundled; then
      docker compose --profile bundled restart keycloak openldap
    else
      docker compose restart keycloak
    fi
    rm -f certs/.reissued
  fi

  if wl_is_bundled; then
    say "seeding the directory"
    # The overlay MUST land before the group: memberOf is only computed for changes made
    # after it is active, so seeding in the other order silently yields no admins.
    for i in $(seq 1 30); do
      docker exec openldap ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1 && break
      sleep 2
    done
    docker exec -i openldap ldapmodify -Y EXTERNAL -H ldapi:/// -c < ldap/memberof-overlay.ldif >/dev/null 2>&1 \
      || echo "  memberof/refint overlays already present"
    envsubst < ldap/acl-bigip-bind.ldif | docker exec -i openldap ldapmodify -Y EXTERNAL -H ldapi:/// >/dev/null \
      || die "failed to apply the bind-account ACL"
    echo "  overlays + ACL applied"

    ldap_add(){ # ldap_add <file>
      envsubst < "$1" | docker exec -i openldap \
        ldapadd -x -D "cn=admin,${BASE_DN}" -w "${WL_LDAP_ADMIN_PW}" -c >/dev/null 2>&1 \
        && echo "  ${1##*/} applied" || echo "  ${1##*/} applied (entries already present)"
    }
    ldap_add ldap/seed.ldif
    ldap_add ldap/demo-users.ldif
  else
    say "external directory — creating nothing in it"
    echo "  validate reachability and the bind first: scripts/preflight-directory.sh"
  fi

  say "waiting for Keycloak"
  KC="https://${WL_KEYCLOAK_FQDN}:${WL_KEYCLOAK_PORT}"
  DISC="${KC}/realms/${WL_KEYCLOAK_REALM}/.well-known/openid-configuration"
  ok=0
  for i in $(seq 1 60); do
    if curl -sk --resolve "${WL_KEYCLOAK_FQDN}:${WL_KEYCLOAK_PORT}:${WL_HOST_IP}" -m5 "$DISC" | jq -e .issuer >/dev/null 2>&1; then
      ok=1; break
    fi
    sleep 5
  done
  [ "$ok" = 1 ] || die "Keycloak did not publish the ${WL_KEYCLOAK_REALM} realm — 'docker compose logs keycloak'"
  echo "  issuer: $(curl -sk --resolve "${WL_KEYCLOAK_FQDN}:${WL_KEYCLOAK_PORT}:${WL_HOST_IP}" -m5 "$DISC" | jq -r .issuer)"

  say "stack ready"
  echo "  Keycloak admin console: ${KC}/admin/  (${WL_KEYCLOAK_ADMIN})"
  echo "  Next: ./deploy.sh --bigip"
fi

# ── the BIG-IP half ─────────────────────────────────────────────────────────
if [ "$DO_BIGIP" = 1 ]; then
  : "${BIGIP_PASS:?set BIGIP_PASS in .env or export it}"
  : "${BIGIP_A_MGMT:?set BIGIP_A_MGMT}"; : "${BIGIP_B_MGMT:?set BIGIP_B_MGMT}"

  say "system auth + remote-role on BOTH units"
  # Per-unit: `auth ldap system-auth` and `auth source` are device-local and a config-sync
  # does NOT carry them to the peer. (`auth remote-role` does sync, but on its own it cannot
  # authenticate anyone.) Skipping B is the classic "works until failover" bug.
  for unit in "$BIGIP_A_MGMT" "$BIGIP_B_MGMT"; do
    echo "  --- $unit ---"
    BIGIP_MGMT="$unit" bigip/system-auth.sh
  done

  say "APM access policy on unit A ($BIGIP_A_MGMT)"
  BIGIP_MGMT="$BIGIP_A_MGMT" bigip/apm-build.sh

  say "config-sync to the peer"
  # Resolve the device group here rather than inside a remote shell: the name has to be
  # substituted as a literal, and nesting quotes through /util/bash is how you end up asking
  # TMOS to sync to a group called "{".
  DG="${WL_DEVICE_GROUP:-}"
  if [ -z "$DG" ]; then
    DG=$(curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" "https://${BIGIP_A_MGMT}/mgmt/tm/cm/device-group" \
         | jq -r '[.items[]? | select(.type=="sync-failover") | .name] | first // empty')
  fi
  if [ -z "$DG" ]; then
    echo "  no sync-failover device group found — standalone unit, nothing to sync"
  else
    echo "  device group: $DG"
    curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" -X POST -H 'Content-Type: application/json' \
      "https://${BIGIP_A_MGMT}/mgmt/tm/util/bash" \
      -d "$(jq -n --arg u "-c 'tmsh run cm config-sync to-group ${DG} 2>&1 | tail -2'" '{command:"run",utilCmdArgs:$u}')" \
      | jq -r '.commandResult // "  sync requested"'
  fi

  say "done"
  echo "  Browse to https://${WL_WEBTOP_FQDN}/  (VIP ${WL_APM_VIP})"
  echo "  Verify with: scripts/validate.sh"
fi
