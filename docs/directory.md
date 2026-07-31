# Bringing your own directory

bigip-mgt-mfa ships a directory so the demo works with nothing but a Docker host, and it points
at yours with a configuration change rather than a different design. Both modes use the same
authorization expression — `memberOf=<admin group DN>` — so what you demonstrate against the
bundled directory is what happens against a real one.

## What bigip-mgt-mfa does to your directory
Nothing. In `external` mode it creates no objects, writes no attributes, and resets no
passwords. The entire contact surface is three read-only interactions:

| Consumer | Operation | Needs |
|---|---|---|
| APM (`aaa-ldap`, type `auth`) | Search for the user, then BIND as them | Search on the user subtree |
| BIG-IP `auth ldap system-auth` | Resolve the user and read `memberOf` | Search + read `memberOf` |
| Keycloak federation | Import identities, `editMode: READ_ONLY` | Search on the user subtree |

Passwords are verified by BIND, never by reading a hash, so the bind account needs no
privilege beyond search. That is what makes it reasonable to point this demo at a production
Active Directory.

## Switching to external mode
Set the mode and the connection details in `.env`:

```bash
MFA_DIRECTORY_MODE=external
MFA_LDAP_HOST=dc01.example.com
MFA_LDAP_SCHEMA=ad                 # or openldap for FreeIPA / OpenLDAP / 389
MFA_LDAP_CA_FILE=/path/to/dc-ca.pem
MFA_BIND_DN=CN=bigip-bind,OU=Service,DC=example,DC=com
MFA_BIND_PW=<bind account password>
MFA_USER_SEARCH_BASE=OU=Users,DC=example,DC=com
MFA_ADMIN_GROUP_DN=CN=bigip-admins,OU=Groups,DC=example,DC=com
```

Then redeploy. The OpenLDAP container does not start in this mode:

```bash
./deploy.sh --stack
./deploy.sh --bigip
./scripts/validate.sh
```

## What `MFA_LDAP_SCHEMA` changes
Schema differences are derived in one place, `scripts/lib/directory.sh`, rather than
scattered through the build scripts:

| Setting | `openldap` | `ad` |
|---|---|---|
| Login attribute | `uid` | `sAMAccountName` |
| Keycloak federation vendor | `other` | `ad` |
| Keycloak UUID attribute | `entryUUID` | `objectGUID` |
| Keycloak user object classes | `inetOrgPerson, organizationalPerson` | `person, organizationalPerson, user` |

Getting the vendor or UUID attribute wrong makes Keycloak's federation import zero users
without a useful error, which is why these are derived rather than typed.

Any of them can still be overridden explicitly — `MFA_LOGIN_ATTR`, `MFA_KC_LDAP_VENDOR`,
`MFA_KC_LDAP_UUID_ATTR`, `MFA_KC_LDAP_USER_CLASSES` — for a directory that does not match either
profile.

## LDAPS and the CA
The BIG-IP's `auth ldap system-auth` connects over LDAPS and validates the certificate. In
bundled mode bigip-mgt-mfa issues that certificate itself. In external mode, export the CA that
signed your directory's LDAPS certificate to a PEM file and point `MFA_LDAP_CA_FILE` at it —
for Active Directory, that is the issuing CA of the domain controller's certificate.

Validation fails closed. A missing or wrong CA produces authentication failures on the
appliance rather than an obvious TLS error.

## Active Directory specifics
- Users log in as `sAMAccountName`, but their DN uses `CN=<display name>`. bigip-mgt-mfa only
  ever searches and binds, so it does not need to construct DNs — but keep it in mind when
  setting `MFA_USER_SEARCH_BASE`.
- `memberOf` in Active Directory reflects direct membership. If your admin group is nested,
  the `remote-role` rule will not match through the nesting; use a group users are directly
  members of, or set `MFA_ADMIN_ROLE_ATTRIBUTE` to an attribute you do populate directly.
- The bind account should be an ordinary service account with no delegated rights. It never
  needs to write.

## Before touching a BIG-IP
Prove the directory first. `./deploy.sh --stack` contacts no appliance, and Keycloak's
federation is the fastest end-to-end check that the bind account, search base, and schema
settings are right: if users appear in the Keycloak admin console under realm
`${MFA_KEYCLOAK_REALM}`, the same credentials will work for APM and for the BIG-IPs.

```bash
ldapwhoami -x -H "ldap://${MFA_LDAP_HOST}:${MFA_LDAP_PORT}" -D "${MFA_BIND_DN}" -w "${MFA_BIND_PW}"
ldapsearch -x -LLL -H "ldap://${MFA_LDAP_HOST}:${MFA_LDAP_PORT}" -D "${MFA_BIND_DN}" -w "${MFA_BIND_PW}" \
  -b "${MFA_USER_SEARCH_BASE}" "(${MFA_LOGIN_ATTR}=alice.admin)" memberOf
```

The second command is the one that matters: if it returns no `memberOf`, nobody will ever be
elevated to administrator, and the cause is the directory rather than the BIG-IP. See
[operations/troubleshooting.md](operations/troubleshooting.md#memberof-is-empty).
