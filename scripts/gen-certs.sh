#!/usr/bin/env bash
# Mint the demo CA and the three server certs this stack presents:
#   ldap.*      — the bundled OpenLDAP's LDAPS cert (skipped in external mode)
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
# Set MFA_REGEN_CA=1 to deliberately roll it — then re-import the CA in the browser and
# re-run ./deploy.sh --bigip so the units pick up the new anchor.
if [ -s ca.crt ] && [ -s ca.key ] && [ "${MFA_REGEN_CA:-0}" != 1 ]; then
  echo "==> reusing existing CA ($(openssl x509 -in ca.crt -noout -subject | sed 's/^subject=//'))"
  echo "    (MFA_REGEN_CA=1 to mint a new one — invalidates browser trust + BIG-IP anchors)"
else
  [ -s ca.crt ] && echo "==> MFA_REGEN_CA=1: minting a NEW CA (existing trust imports become invalid)"
  openssl req -x509 -newkey rsa:4096 -nodes -days 365 \
    -keyout ca.key -out ca.crt -subj "/CN=${MFA_CA_CN:-bigip-mgt-mfa Demo CA}"
fi
chmod 0644 ca.crt

# A leaf cert is only re-minted when it is missing or no longer verifies against the current
# CA. Re-minting on every run would be invisible but wrong: the containers read their
# certificate files once at process start, so a fresh cert on disk that nothing restarted for
# means the running service still serves the old one, and the two disagree until something
# unrelated restarts it. Re-issuing only when needed lets deploy.sh restart exactly then.
REISSUED=0

# issue <basename> <CN> <SAN-string>
issue() {
  local base="$1" cn="$2" san="$3"
  if [ "${MFA_REGEN_CA:-0}" != 1 ] && [ -s "${base}.crt" ] && [ -s "${base}.key" ] \
     && openssl verify -CAfile ca.crt "${base}.crt" >/dev/null 2>&1; then
    echo "==> ${base}.crt still valid under the current CA — keeping it"
    return 0
  fi
  REISSUED=1
  openssl req -newkey rsa:2048 -nodes -keyout "${base}.key" -out "${base}.csr" -subj "/CN=${cn}"
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$san" > "${base}-san.cnf"
  openssl x509 -req -in "${base}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 365 -extfile "${base}-san.cnf" -out "${base}.crt"
  chmod 0644 "${base}.crt"; chmod 0640 "${base}.key" || true
  echo "==> ${base}.crt  $(openssl x509 -in "${base}.crt" -noout -ext subjectAltName | tail -1 | tr -d ' ')"
}

# The APM VIP. The OIDC redirect_uri origin is this name, so the browser must trust it.
issue webtop "${MFA_WEBTOP_FQDN}" \
  "DNS:${MFA_WEBTOP_FQDN},IP:${MFA_APM_VIP}"

# LDAPS is only ours to issue in bundled mode. With your own directory it already has a
# cert and you point MFA_LDAP_CA_FILE at the CA that signed it.
if ! mfa_is_bundled; then
  echo "==> external directory: skipping the LDAPS server cert;"
  echo "    the BIG-IP will validate LDAPS against ${MFA_LDAP_CA_FILE}."
  if [ "$REISSUED" = 1 ]; then touch .reissued; else rm -f .reissued; fi
  exit 0
fi
issue ldap "openldap.${MFA_DOMAIN:-bigip-mgt-mfa.lab}" \
  "DNS:openldap.${MFA_DOMAIN:-bigip-mgt-mfa.lab},DNS:openldap,IP:${MFA_HOST_IP}"

# OpenLDAP gets its OWN copy of what it needs, in its own directory. The osixia image
# chowns whatever certs directory it is handed, on every start -- sharing one directory
# means it eventually owns webtop.key and the CA key too, and anything else reading them
# starts failing with AccessDeniedException. Start ordering hides this until a reboot.
mkdir -p ldap-certs
cp -f ldap.crt ldap.key ca.crt ldap-certs/
chmod 0644 ldap-certs/ldap.crt ldap-certs/ca.crt
chmod 0640 ldap-certs/ldap.key || true
echo "==> ldap-certs/ populated (kept apart so the container cannot chown the rest)"

# Marker consumed by deploy.sh: the containers must be restarted to pick up new certs.
# An if, not `[ ] && touch`, because under `set -e` a false test would abort the script.
if [ "$REISSUED" = 1 ]; then touch .reissued; else rm -f .reissued; fi
