# Install — the bigip-mgt-mfa stack

Stand up the Docker half of the demo: the demo CA, CoreDNS, Keycloak, and (in bundled mode)
OpenLDAP with the two demo principals. This half touches **no BIG-IP**, which is the point of
running it first — every failure you hit here is a failure you did not have to diagnose on an
appliance. The BIG-IP half is [deploy.md](deploy.md); `./deploy.sh` with no argument runs both,
in that order.

_Last validated: 2026-07-30_

## Prerequisites
- A Linux host with `docker` and the **Compose v2 plugin**. Every script invokes it as
  `docker compose` (Debian/Ubuntu: `apt-get install -y docker-compose-v2`); `deploy.sh` refuses
  to run against the end-of-life standalone `docker-compose` v1 binary.
- Host packages: `openssl`, `jq`, `gettext-base` (for `envsubst`), and `curl` — `deploy.sh`
  checks for all four and exits naming the missing one. `scripts/validate.sh` additionally uses
  `dig` (`dnsutils`) and `ldapsearch`/`ldapwhoami` (`ldap-utils`); `scripts/demo-login.sh`
  additionally needs `oathtool` to compute TOTP codes.
- Free host ports, because the containers publish them: `${MFA_KEYCLOAK_PORT}` (default `8443`)
  for Keycloak, `389` and `636` for the bundled OpenLDAP, and `${MFA_DNS_PORT}` (default `53`)
  on `${MFA_HOST_IP}` for CoreDNS. CoreDNS binds the host's lab address rather than the wildcard
  so it can coexist with a stub resolver on `127.0.0.53`; if something else already holds `:53`
  on that address, move it with `MFA_DNS_PORT`.
- The BIG-IP pair must be able to reach this host on the LDAP/LDAPS, Keycloak and DNS ports
  above. Nothing in this half connects *to* a BIG-IP, but the addresses you choose here are the
  ones the appliances will use later.
- A licensed BIG-IP HA pair with **LTM and APM provisioned** is a prerequisite of the next half,
  not this one. You can complete and verify this page without one.

## Procedure
### 1. Configure
`deploy.sh` refuses to start without a `.env`. Copy the example and fill in the
`<angle-bracket>` values — `MFA_HOST_IP`, the two passwords in the directory block, the Keycloak
admin password and OIDC client secret, the `BIGIP_*` block, and `MFA_APM_VIP`:

```bash
cp .env.example .env
$EDITOR .env
```

`.env` is gitignored. Everything not in a REQUIRED block has a working default; the defaults
are resolved in `scripts/lib/directory.sh`, which is the single source of truth for the base
DN, the bind account, the identity subtree and how admin-ness is expressed.

In **external** directory mode (`MFA_DIRECTORY_MODE=external`) bigip-mgt-mfa creates nothing in
your directory and the deployer seeds nothing, so prove the bind, the subtree and the group
expression before you go any further. `scripts/preflight-directory.sh` is read-only and touches
no BIG-IP:

```bash
scripts/preflight-directory.sh            # or: scripts/preflight-directory.sh <test-user>
```

### 2. Run the stack half

```bash
./deploy.sh --stack
```

In order, it:

1. **Mints the CA and server certificates** (`scripts/gen-certs.sh`) — `keycloak.*`, `webtop.*`,
   and in bundled mode `ldap.*`, all under `certs/`. An existing CA is reused; see
   [Idempotency in deploy.md](deploy.md#idempotency). Each SAN covers both the DNS name a
   browser uses and the IP address the BIG-IP uses, because every one of these endpoints is
   reached from both sides.
2. **Renders the DNS zone** to `dns/Corefile` — CoreDNS is authoritative for `${MFA_DOMAIN}` and
   forwards everything else to `MFA_DNS_UPSTREAM`.
3. **Renders the Keycloak realm** to `keycloak/import/` (`envsubst`, then `jq` strips the
   `_comment*` keys, which Keycloak's importer would reject rather than ignore). A rendering
   failure here is almost always an unset variable in `.env`.
4. **Starts the containers** — `docker compose --profile bundled up -d` in bundled mode, and
   without the profile in external mode, where OpenLDAP never runs.
5. **Seeds the directory** (bundled only): the `memberof`/`refint` overlays and the bind-account
   ACL first, then `ldap/seed.ldif` and `ldap/demo-users.ldif`. The order is load-bearing —
   `memberOf` is only computed for changes made *after* the overlay is active, so seeding the
   group first yields a directory with no admins and no error.
6. **Waits for realm discovery**, polling the well-known OpenID configuration until Keycloak
   publishes an issuer. It gives up after five minutes and points you at
   `docker compose logs keycloak`.

### 3. Make the names resolve for your browser
The BIG-IP is pointed at CoreDNS automatically by the next half (`bigip/apm-build.sh` creates a
TMOS `net dns-resolver`), but your workstation is not. Either point it at this host's resolver,
or add the two demo names to its hosts file:

```bash
# on the workstation, or on this host if you browse from it
printf '%s\t%s\n%s\t%s\n' \
  "${MFA_HOST_IP}" "${MFA_KEYCLOAK_FQDN}" \
  "${MFA_APM_VIP}" "${MFA_WEBTOP_FQDN}" | sudo tee -a /etc/hosts
```

Import `certs/ca.crt` into the browser or OS trust store as well. The webtop VIP is the OIDC
`redirect_uri` origin, so a certificate the browser distrusts surfaces as a failed OAuth
redirect rather than as a certificate warning.

## Verification
```bash
docker compose --profile bundled ps
dig +short "@${MFA_HOST_IP}" -p "${MFA_DNS_PORT:-53}" "${MFA_KEYCLOAK_FQDN}"
curl -sk --resolve "${MFA_KEYCLOAK_FQDN}:${MFA_KEYCLOAK_PORT}:${MFA_HOST_IP}" \
  "https://${MFA_KEYCLOAK_FQDN}:${MFA_KEYCLOAK_PORT}/realms/${MFA_KEYCLOAK_REALM}/.well-known/openid-configuration" \
  | jq -r .issuer
```

Expected: `keycloak`, `bigip-mgt-mfa-dns` and `openldap` all `running`; the Keycloak FQDN resolves
to `MFA_HOST_IP`; the issuer is exactly
`https://${MFA_KEYCLOAK_FQDN}:${MFA_KEYCLOAK_PORT}/realms/${MFA_KEYCLOAK_REALM}`. APM validates that
string literally, so a mismatch here becomes an opaque token-validation failure later.

Then confirm the one directory fact the whole demo rests on — alice is in the admin group and
bob is not:

```bash
ldapsearch -x -LLL -H "ldap://${MFA_HOST_IP}:${MFA_LDAP_PORT:-389}" \
  -D "cn=bigip-bind,ou=svc,${BASE_DN}" -w "${MFA_BIND_PW}" \
  -b "ou=people,${BASE_DN}" '(uid=alice.admin)' memberOf
```

Expected: one `memberOf: cn=bigip-admins,ou=groups,<BASE_DN>` line. If it is empty, the overlay
landed after the group was created; re-seed by removing the volumes as in
[Uninstall](#uninstall) and re-running `./deploy.sh --stack`.

`scripts/validate.sh` runs all of the above plus the BIG-IP assertions, and exits with the
number of failed checks. Run it now if you want the full picture — the container, DNS, directory
and Keycloak sections should be green, and the BIG-IP sections will fail until
[deploy.md](deploy.md) is done:

```bash
./scripts/validate.sh; echo "failed checks: $?"
```

## Uninstall
`./teardown.sh --stack` removes this half and leaves the BIG-IP configuration alone; back that
out separately with [deploy.md](deploy.md#rollback) or `./teardown.sh --bigip`.

```bash
./teardown.sh --stack             # containers and network; volumes survive
./teardown.sh --stack --volumes   # also drop ldapdata, ldapconf and kcdata
```

Those are `docker compose --profile bundled down` and `down -v` respectively, plus the removal
of any cached `certs/.totp-*` secrets.

`--volumes` **destroys every enrolled TOTP secret**, because Keycloak's H2 store lives in the
`kcdata` volume. Users re-enrol on their next login; if you only want to reset one user, leave
the volumes alone and use
[operations/runbooks/reset-user-mfa.md](operations/runbooks/reset-user-mfa.md). Without
`--volumes`, re-running `./deploy.sh --stack` restores the same directory and the same
enrolments.

To remove the generated material as well:

```bash
sudo chown -R "$(id -u):$(id -g)" certs   # the openldap container chowns this dir at startup
rm -rf certs keycloak/import dns/Corefile
```

Dropping `certs/` discards the CA, so the next `./deploy.sh --stack` mints a new one and every
browser trust import and BIG-IP trust anchor must be replaced —
[operations/runbooks/rotate-ca.md](operations/runbooks/rotate-ca.md) covers that path
deliberately.
