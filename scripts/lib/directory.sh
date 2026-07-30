# directory.sh — source this AFTER .env. Single source of truth for "which directory does
# warden-lite use, and how is the BIG-IP admin group expressed there". Every consumer (APM
# AAA, BIG-IP system-auth, the Keycloak realm render, validation) reads these rather than
# hardcoding DNs.
#
# Two modes:
#   bundled  (default) — warden-lite runs its own OpenLDAP in compose and seeds it. Zero config.
#   external           — you bring AD / FreeIPA / any LDAP. warden-lite creates NOTHING in it
#                        and never writes to it: APM binds to check a password, the BIG-IP
#                        reads memberOf, Keycloak federates READ_ONLY. That is the whole
#                        interaction, which is why this demo is safe to point at a real AD.
#
# Unlike Warden there is exactly ONE subtree in play. There are no privileged accounts to
# rotate, because the user's own credential is what gets single-signed-on to TMUI.

WL_DIRECTORY_MODE="${WL_DIRECTORY_MODE:-bundled}"
case "$WL_DIRECTORY_MODE" in
  bundled|external) ;;
  *) echo "WL_DIRECTORY_MODE must be 'bundled' or 'external' (got '$WL_DIRECTORY_MODE')" >&2; return 1 2>/dev/null || exit 1;;
esac
wl_is_bundled() { [ "$WL_DIRECTORY_MODE" = bundled ]; }

: "${BASE_DN:?set BASE_DN in .env}"

# ─── where the directory lives ───────────────────────────────────────────────
if wl_is_bundled; then
  WL_LDAP_HOST="${WL_LDAP_HOST:-${WL_HOST_IP:?set WL_HOST_IP in .env}}"
else
  : "${WL_LDAP_HOST:?external mode: set WL_LDAP_HOST to your AD/LDAP address}"
fi
WL_LDAP_PORT="${WL_LDAP_PORT:-389}"
WL_LDAPS_PORT="${WL_LDAPS_PORT:-636}"

# openldap | ad — drives the login attribute and the Keycloak federation vendor below.
WL_LDAP_SCHEMA="${WL_LDAP_SCHEMA:-openldap}"

# ─── binds and subtrees ──────────────────────────────────────────────────────
# One read-only bind, shared by all three consumers. It never needs write access and never
# needs to read userPassword — passwords are verified by BIND, not by comparison.
WL_BIND_DN="${WL_BIND_DN:-cn=bigip-bind,ou=svc,${BASE_DN}}"
WL_USER_SEARCH_BASE="${WL_USER_SEARCH_BASE:-ou=people,${BASE_DN}}"

if [ "$WL_LDAP_SCHEMA" = ad ]; then
  WL_LOGIN_ATTR="${WL_LOGIN_ATTR:-sAMAccountName}"
else
  WL_LOGIN_ATTR="${WL_LOGIN_ATTR:-uid}"
fi

# ─── the BIG-IP admin group ──────────────────────────────────────────────────
# Members get Administrator on BOTH units; everyone else who authenticates falls through to
# the default role (guest / read-only). This is the ONLY difference between the two demo
# users, and the BIG-IP — not APM, not Keycloak — is what evaluates it.
WL_ADMIN_GROUP_DN="${WL_ADMIN_GROUP_DN:-cn=bigip-admins,ou=groups,${BASE_DN}}"
# Group membership, not an attribute stamp: warden-lite has no account-provisioning step, so
# there is nothing to stamp and memberOf is what a real directory already carries. This is
# the same expression in bundled and external mode, which is what makes the AD path a
# configuration change rather than a different design.
WL_ADMIN_ROLE_ATTRIBUTE="${WL_ADMIN_ROLE_ATTRIBUTE:-memberOf=${WL_ADMIN_GROUP_DN}}"

# ─── TLS material the BIG-IP validates LDAPS against ─────────────────────────
if wl_is_bundled; then
  WL_LDAP_CA_FILE="${WL_LDAP_CA_FILE:-certs/ca.crt}"
  WL_LDAP_CA_NAME="${WL_LDAP_CA_NAME:-warden-lite-ca.crt}"
else
  : "${WL_LDAP_CA_FILE:?external mode: set WL_LDAP_CA_FILE to your directory CA PEM (LDAPS validates against it)}"
  WL_LDAP_CA_NAME="${WL_LDAP_CA_NAME:-warden-lite-dir-ca.crt}"
fi

# ─── Keycloak's view of the same directory ───────────────────────────────────
# Bundled: Keycloak reaches OpenLDAP over the compose network by service name. External: over
# the wire to your DC. Vendor/UUID/objectClass differ between AD and everything else, and
# getting them wrong makes federation import zero users with no useful error.
if wl_is_bundled; then
  WL_KC_LDAP_HOST="${WL_KC_LDAP_HOST:-openldap}"
else
  WL_KC_LDAP_HOST="${WL_KC_LDAP_HOST:-${WL_LDAP_HOST}}"
fi
if [ "$WL_LDAP_SCHEMA" = ad ]; then
  WL_KC_LDAP_VENDOR="${WL_KC_LDAP_VENDOR:-ad}"
  WL_KC_LDAP_UUID_ATTR="${WL_KC_LDAP_UUID_ATTR:-objectGUID}"
  WL_KC_LDAP_USER_CLASSES="${WL_KC_LDAP_USER_CLASSES:-person, organizationalPerson, user}"
else
  WL_KC_LDAP_VENDOR="${WL_KC_LDAP_VENDOR:-other}"
  WL_KC_LDAP_UUID_ATTR="${WL_KC_LDAP_UUID_ATTR:-entryUUID}"
  WL_KC_LDAP_USER_CLASSES="${WL_KC_LDAP_USER_CLASSES:-inetOrgPerson, organizationalPerson}"
fi

export WL_DIRECTORY_MODE WL_LDAP_HOST WL_LDAP_PORT WL_LDAPS_PORT WL_LDAP_SCHEMA \
       WL_BIND_DN WL_USER_SEARCH_BASE WL_LOGIN_ATTR \
       WL_ADMIN_GROUP_DN WL_ADMIN_ROLE_ATTRIBUTE \
       WL_LDAP_CA_FILE WL_LDAP_CA_NAME \
       WL_KC_LDAP_HOST WL_KC_LDAP_VENDOR WL_KC_LDAP_UUID_ATTR WL_KC_LDAP_USER_CLASSES

wl_directory_summary() {
  echo "directory: ${WL_DIRECTORY_MODE} @ ${WL_LDAP_HOST} — identities under ${WL_USER_SEARCH_BASE}"
  echo "admin group: ${WL_ADMIN_GROUP_DN}  (BIG-IP remote-role maps: ${WL_ADMIN_ROLE_ATTRIBUTE})"
}
