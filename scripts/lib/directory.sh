# directory.sh — source this AFTER .env. Single source of truth for "which directory does
# bigip-mgt-mfa use, and how is the BIG-IP admin group expressed there". Every consumer (APM
# AAA, BIG-IP system-auth, the Keycloak realm render, validation) reads these rather than
# hardcoding DNs.
#
# Two modes:
#   bundled  (default) — bigip-mgt-mfa runs its own OpenLDAP in compose and seeds it. Zero config.
#   external           — you bring AD / FreeIPA / any LDAP. bigip-mgt-mfa creates NOTHING in it
#                        and never writes to it: APM binds to check a password, the BIG-IP
#                        reads memberOf, Keycloak federates READ_ONLY. That is the whole
#                        interaction, which is why this demo is safe to point at a real AD.
#
# Unlike Warden there is exactly ONE subtree in play. There are no privileged accounts to
# rotate, because the user's own credential is what gets single-signed-on to TMUI.

MFA_DIRECTORY_MODE="${MFA_DIRECTORY_MODE:-bundled}"
case "$MFA_DIRECTORY_MODE" in
  bundled|external) ;;
  *) echo "MFA_DIRECTORY_MODE must be 'bundled' or 'external' (got '$MFA_DIRECTORY_MODE')" >&2; return 1 2>/dev/null || exit 1;;
esac
mfa_is_bundled() { [ "$MFA_DIRECTORY_MODE" = bundled ]; }

: "${BASE_DN:?set BASE_DN in .env}"

# ─── where the directory lives ───────────────────────────────────────────────
if mfa_is_bundled; then
  MFA_LDAP_HOST="${MFA_LDAP_HOST:-${MFA_HOST_IP:?set MFA_HOST_IP in .env}}"
else
  : "${MFA_LDAP_HOST:?external mode: set MFA_LDAP_HOST to your AD/LDAP address}"
fi
MFA_LDAP_PORT="${MFA_LDAP_PORT:-389}"
MFA_LDAPS_PORT="${MFA_LDAPS_PORT:-636}"

# openldap | ad — drives the login attribute and the Keycloak federation vendor below.
MFA_LDAP_SCHEMA="${MFA_LDAP_SCHEMA:-openldap}"

# ─── binds and subtrees ──────────────────────────────────────────────────────
# One read-only bind, shared by all three consumers. It never needs write access and never
# needs to read userPassword — passwords are verified by BIND, not by comparison.
MFA_BIND_DN="${MFA_BIND_DN:-cn=bigip-bind,ou=svc,${BASE_DN}}"
MFA_USER_SEARCH_BASE="${MFA_USER_SEARCH_BASE:-ou=people,${BASE_DN}}"

if [ "$MFA_LDAP_SCHEMA" = ad ]; then
  MFA_LOGIN_ATTR="${MFA_LOGIN_ATTR:-sAMAccountName}"
else
  MFA_LOGIN_ATTR="${MFA_LOGIN_ATTR:-uid}"
fi

# ─── the BIG-IP admin group ──────────────────────────────────────────────────
# Members get Administrator on BOTH units; everyone else who authenticates falls through to
# the default role (guest / read-only). This is the ONLY difference between the two demo
# users, and the BIG-IP — not APM, not Keycloak — is what evaluates it.
MFA_ADMIN_GROUP_DN="${MFA_ADMIN_GROUP_DN:-cn=bigip-admins,ou=groups,${BASE_DN}}"
# Group membership, not an attribute stamp: bigip-mgt-mfa has no account-provisioning step, so
# there is nothing to stamp and memberOf is what a real directory already carries. This is
# the same expression in bundled and external mode, which is what makes the AD path a
# configuration change rather than a different design.
MFA_ADMIN_ROLE_ATTRIBUTE="${MFA_ADMIN_ROLE_ATTRIBUTE:-memberOf=${MFA_ADMIN_GROUP_DN}}"

# ─── TLS material the BIG-IP validates LDAPS against ─────────────────────────
if mfa_is_bundled; then
  MFA_LDAP_CA_FILE="${MFA_LDAP_CA_FILE:-certs/ca.crt}"
  MFA_LDAP_CA_NAME="${MFA_LDAP_CA_NAME:-bigip-mgt-mfa-ca.crt}"
else
  : "${MFA_LDAP_CA_FILE:?external mode: set MFA_LDAP_CA_FILE to your directory CA PEM (LDAPS validates against it)}"
  MFA_LDAP_CA_NAME="${MFA_LDAP_CA_NAME:-bigip-mgt-mfa-dir-ca.crt}"
fi


# Three groups, three TMOS roles, plus the default. One group would demonstrate a boolean;
# a spectrum is what an operations team actually has, and it makes "the BIG-IP decides, from
# the directory" visible rather than asserted.
MFA_OPERATOR_GROUP_DN="${MFA_OPERATOR_GROUP_DN:-cn=bigip-operators,ou=groups,${BASE_DN}}"
MFA_AUDITOR_GROUP_DN="${MFA_AUDITOR_GROUP_DN:-cn=bigip-auditors,ou=groups,${BASE_DN}}"
MFA_OPERATOR_ROLE_ATTRIBUTE="${MFA_OPERATOR_ROLE_ATTRIBUTE:-memberOf=${MFA_OPERATOR_GROUP_DN}}"
MFA_AUDITOR_ROLE_ATTRIBUTE="${MFA_AUDITOR_ROLE_ATTRIBUTE:-memberOf=${MFA_AUDITOR_GROUP_DN}}"

# Per-user demo passwords. MFA_TEST_USER_PW remains the fallback so an existing .env keeps
# working, but each principal having its own is what makes per-user attribution provable.
MFA_PW_ALICE="${MFA_PW_ALICE:-${MFA_TEST_USER_PW:-}}"
MFA_PW_BOB="${MFA_PW_BOB:-${MFA_TEST_USER_PW:-}}"
MFA_PW_CAROL="${MFA_PW_CAROL:-${MFA_TEST_USER_PW:-}}"
MFA_PW_DAVE="${MFA_PW_DAVE:-${MFA_TEST_USER_PW:-}}"

export MFA_OPERATOR_GROUP_DN MFA_AUDITOR_GROUP_DN \
       MFA_OPERATOR_ROLE_ATTRIBUTE MFA_AUDITOR_ROLE_ATTRIBUTE \
       MFA_PW_ALICE MFA_PW_BOB MFA_PW_CAROL MFA_PW_DAVE

export MFA_DIRECTORY_MODE MFA_LDAP_HOST MFA_LDAP_PORT MFA_LDAPS_PORT MFA_LDAP_SCHEMA \
       MFA_BIND_DN MFA_USER_SEARCH_BASE MFA_LOGIN_ATTR \
       MFA_ADMIN_GROUP_DN MFA_ADMIN_ROLE_ATTRIBUTE \
       MFA_LDAP_CA_FILE MFA_LDAP_CA_NAME

mfa_directory_summary() {
  echo "directory: ${MFA_DIRECTORY_MODE} @ ${MFA_LDAP_HOST} — identities under ${MFA_USER_SEARCH_BASE}"
  echo "admin group: ${MFA_ADMIN_GROUP_DN}  (BIG-IP remote-role maps: ${MFA_ADMIN_ROLE_ATTRIBUTE})"
}
