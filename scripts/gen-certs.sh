#!/usr/bin/env bash
# Mint the demo CA and the three server certs this stack presents:
#   ldap.*      — the bundled OpenLDAP's LDAPS cert (skipped in external mode)
#   keycloak.*  — Keycloak's HTTPS cert; the BIG-IP validates this on the OIDC token call
#   webtop.*    — the APM VIP's cert, installed on the BIG-IP by bigip/apm-build.sh
#
# Every SAN must cover BOTH the name a browser uses and the address the BIG-IP uses, because
# each of these is reached from both sides. A SAN mismatch here fails closed and shows up as
# an opaque APM "OAuth server unreachable" — see docs/operations/troubleshooting.md.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
# shellcheck disable=SC1091
. "${HERE}/lib/directory.sh"
cd "${HERE}/../certs"

# shellcheck disable=SC1091
. "${HERE}/lib/certs.sh"
ensure_certs_writable .

# REUSE an existing CA. deploy.sh is meant to be re-runnable, and minting a fresh CA every
# run would invalidate every browser trust import and the anchors installed on both BIG-IPs.
# Set WL_REGEN_CA=1 to deliberately roll it — then re-import the CA in the browser and
# re-run ./deploy.sh --bigip so the units pick up the new anchor.
if [ -s ca.crt ] && [ -s ca.key ] && [ "${WL_REGEN_CA:-0}" != 1 ]; then
  echo "==> reusing existing CA ($(openssl x509 -in ca.crt -noout -subject | sed 's/^subject=//'))"
  echo "    (WL_REGEN_CA=1 to mint a new one — invalidates browser trust + BIG-IP anchors)"
else
  [ -s ca.crt ] && echo "==> WL_REGEN_CA=1: minting a NEW CA (existing trust imports become invalid)"
  openssl req -x509 -newkey rsa:4096 -nodes -days 365 \
    -keyout ca.key -out ca.crt -subj "/CN=${WL_CA_CN:-warden-lite Demo CA}"
fi
chmod 0644 ca.crt

# issue <basename> <CN> <SAN-string>
issue() {
  local base="$1" cn="$2" san="$3"
  openssl req -newkey rsa:2048 -nodes -keyout "${base}.key" -out "${base}.csr" -subj "/CN=${cn}"
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$san" > "${base}-san.cnf"
  openssl x509 -req -in "${base}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 365 -extfile "${base}-san.cnf" -out "${base}.crt"
  chmod 0644 "${base}.crt"; chmod 0640 "${base}.key" || true
  echo "==> ${base}.crt  $(openssl x509 -in "${base}.crt" -noout -ext subjectAltName | tail -1 | tr -d ' ')"
}

# Keycloak: browsers reach it by FQDN, the BIG-IP's OAuth server may reach it by either.
issue keycloak "${WL_KEYCLOAK_FQDN}" \
  "DNS:${WL_KEYCLOAK_FQDN},DNS:keycloak,IP:${WL_HOST_IP}"

# The APM VIP. The OIDC redirect_uri origin is this name, so the browser must trust it.
issue webtop "${WL_WEBTOP_FQDN}" \
  "DNS:${WL_WEBTOP_FQDN},IP:${WL_APM_VIP}"

# LDAPS is only ours to issue in bundled mode. With your own directory it already has a
# cert and you point WL_LDAP_CA_FILE at the CA that signed it.
if ! wl_is_bundled; then
  echo "==> external directory: skipping the LDAPS server cert;"
  echo "    the BIG-IP will validate LDAPS against ${WL_LDAP_CA_FILE}."
  exit 0
fi
issue ldap "openldap.${WL_DOMAIN:-warden-lite.lab}" \
  "DNS:openldap.${WL_DOMAIN:-warden-lite.lab},DNS:openldap,IP:${WL_HOST_IP}"
