#!/usr/bin/env bash
# bigip-mgt-mfa deployer. Two halves, deliberately separable:
#
#   ./deploy.sh --stack    the directory + DNS, in Docker. Touches NO BIG-IP. Prove
#                          this half works before pointing anything at your appliances.
#   ./deploy.sh --bigip    the BIG-IP half: trust anchors, remote-role on both units, and
#                          the APM access policy on unit A (config-sync carries it
#                          to the peer).
#   ./deploy.sh            both, in that order.
#
# Re-running is safe: certs are reused unless MFA_REGEN_CA=1, LDAP seeding tolerates
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
  mfa_directory_summary

  say "certificates (CA, webtop VIP$(mfa_is_bundled && echo ", LDAPS"))"
  scripts/gen-certs.sh

  say "rendering the demo DNS zone"
  envsubst < dns/Corefile.tmpl > dns/Corefile
  echo "  ${MFA_WEBTOP_FQDN} -> ${MFA_APM_VIP}"

  say "starting containers"
  if mfa_is_bundled; then
    docker compose --profile bundled up -d
  else
    docker compose up -d
  fi

  # `up -d` will not recreate a service whose definition has not changed, and OpenLDAP reads
  # its certificate files once at process start. So when gen-certs.sh has
  # actually re-issued a leaf certificate, the running containers are still serving the old
  # one and must be restarted explicitly — otherwise the CA on disk and the certificate on
  # the wire disagree, and the BIG-IP's back-channel validation fails for reasons nothing
  # in the logs connects to a certificate.
  if [ -f certs/.reissued ]; then
    say "certificates were re-issued — restarting the services that present them"
    if mfa_is_bundled; then
      docker compose --profile bundled restart openldap
    fi
    rm -f certs/.reissued
  fi

  if mfa_is_bundled; then
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
        ldapadd -x -D "cn=admin,${BASE_DN}" -w "${MFA_LDAP_ADMIN_PW}" -c >/dev/null 2>&1 \
        && echo "  ${1##*/} applied" || echo "  ${1##*/} applied (entries already present)"
    }
    ldap_add ldap/seed.ldif
    ldap_add ldap/demo-users.ldif
  else
    say "external directory — creating nothing in it"
    echo "  validate reachability and the bind first: scripts/preflight-directory.sh"
  fi

  say "stack ready"
  echo "  Enrol a user's authenticator: ./scripts/enroll-totp.sh <username>"
  echo "  Next: ./deploy.sh --bigip"
fi

# ── the BIG-IP half ─────────────────────────────────────────────────────────
if [ "$DO_BIGIP" = 1 ]; then
  : "${BIGIP_PASS:?set BIGIP_PASS in .env or export it}"
  : "${BIGIP_A_MGMT:?set BIGIP_A_MGMT}"

  # BIGIP_B_MGMT is OPTIONAL. An HA pair is the interesting demo, but most UDF blueprints and
  # many personal labs give you a single BIG-IP, and there is nothing about MFA at the
  # management edge that needs two. Leave it unset and everything below simply runs once.
  UNITS=("$BIGIP_A_MGMT")
  [ -n "${BIGIP_B_MGMT:-}" ] && UNITS+=("$BIGIP_B_MGMT")

  if [ "${#UNITS[@]}" -eq 1 ]; then
    say "system auth + remote-role (single unit — BIGIP_B_MGMT not set)"
  else
    say "system auth + remote-role on BOTH units"
  fi
  # Per-unit: `auth ldap system-auth` and `auth source` are device-local and a config-sync
  # does NOT carry them to the peer. (`auth remote-role` does sync, but on its own it cannot
  # authenticate anyone.) Skipping B is the classic "works until failover" bug.
  for unit in "${UNITS[@]}"; do
    echo "  --- $unit ---"
    BIGIP_MGMT="$unit" bigip/system-auth.sh
  done

  say "APM access policy on unit A ($BIGIP_A_MGMT)"
  BIGIP_MGMT="$BIGIP_A_MGMT" bigip/apm-build.sh

  say "config-sync to the peer"
  # Resolve the device group here rather than inside a remote shell: the name has to be
  # substituted as a literal, and nesting quotes through /util/bash is how you end up asking
  # TMOS to sync to a group called "{".
  DG="${MFA_DEVICE_GROUP:-}"
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
  echo "  Browse to https://${MFA_WEBTOP_FQDN}/  (VIP ${MFA_APM_VIP})"
  echo "  Verify with: scripts/validate.sh"
fi
