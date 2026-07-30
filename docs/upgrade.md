# Upgrade, rollback & teardown

warden-lite is configuration, not a running product, so "upgrading" means re-applying it from a
newer revision, newer container images, or an edited `.env`. Both halves of `deploy.sh` are
idempotent, so in every case the upgrade procedure is a re-run.

_Last validated: 2026-07-30_

## Supported paths

| From | To | How |
|---|---|---|
| An older revision of this repo | `main` | `git pull`, then `./deploy.sh` (or one half) |
| The currently pinned container images | Newer images | Edit the tags in `docker-compose.yml`, then `./deploy.sh --stack` |
| A `.env` you have edited | The change applied | `./deploy.sh` — leaf certificates are reissued and the BIG-IP objects converge |
| The current demo CA | A fresh CA | `WL_REGEN_CA=1 ./deploy.sh --stack`, then `./deploy.sh --bigip` — [operations/runbooks/rotate-ca.md](operations/runbooks/rotate-ca.md) |
| Bundled OpenLDAP | Your own AD / FreeIPA / LDAP | Set `WL_DIRECTORY_MODE=external` and the `WL_LDAP_*` block, then re-deploy — [directory.md](directory.md) |

Downgrading is the same operation against an older revision or an older image tag, with the
rollback caveat below.

## Pre-upgrade checks
Confirm the current state is healthy before you change it, so a failure afterwards is
unambiguous rather than pre-existing:

```bash
./scripts/validate.sh; echo "failed checks: $?"
docker compose --profile bundled ps
git log --oneline -1
```

Record the CA identity. A normal re-deploy reuses it, and being able to prove that afterwards
rules the CA out as a cause:

```bash
openssl x509 -in certs/ca.crt -noout -fingerprint -sha256 -enddate
```

If the pair is in HA, confirm it is actually in sync before you push a new build through it:

```bash
curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" \
  "https://${BIGIP_A_MGMT}/mgmt/tm/cm/sync-status" \
  | jq -r '.entries[].nestedStats.entries.status.description'
```

## Procedure
### Upgrading the container images
The images are pinned by tag in `docker-compose.yml` — `quay.io/keycloak/keycloak:26.4`,
`docker.io/coredns/coredns:1.12.0` and `osixia/openldap:1.5.0`. Change the tag, then re-run the
stack half; Compose pulls the new image and recreates only the services whose definition
changed:

```bash
$EDITOR docker-compose.yml        # bump the pinned tag(s)
./deploy.sh --stack
docker compose --profile bundled ps
```

The named volumes survive, so enrolled TOTP secrets and the seeded directory carry across. That
persistence has one consequence worth knowing: the realm is imported at container start from
`keycloak/import/`, and a realm that already exists in the persisted store is kept as-is. If you
edit `keycloak/warden-lite-realm.json.tmpl` and need the change to actually land, the realm has
to be re-imported into an empty store — which means dropping `kcdata` and re-enrolling every
user, so treat it as a rebuild rather than an upgrade:

```bash
docker compose --profile bundled down -v && ./deploy.sh --stack
```

A Keycloak upgrade does not touch the BIG-IP as long as the issuer string is unchanged. APM
validates the issuer literally, so if you change `WL_KEYCLOAK_FQDN`, `WL_KEYCLOAK_PORT` or
`WL_KEYCLOAK_REALM`, run the BIG-IP half afterwards as well.

### Re-running after editing `.env`

```bash
$EDITOR .env
./deploy.sh                       # or --stack / --bigip for one half
```

`gen-certs.sh` reissues the leaf certificates on every run, so a changed `WL_HOST_IP`,
`WL_KEYCLOAK_FQDN`, `WL_WEBTOP_FQDN` or `WL_APM_VIP` produces correct SANs immediately — but the
new `webtop.crt` only reaches the appliances via the BIG-IP half, and Keycloak and OpenLDAP read
their certificate files at process start. `docker compose up -d` does not restart a service
whose definition has not changed, so restart them explicitly when the certificates moved:

```bash
docker compose --profile bundled restart keycloak openldap
./deploy.sh --bigip
```

Changes to the directory block (`BASE_DN`, `WL_ADMIN_GROUP_DN`, `WL_ADMIN_ROLE_ATTRIBUTE`,
`WL_LOGIN_ATTR`) affect all three consumers — the APM AAA agent, the BIG-IP `remote-role`, and
Keycloak's federation — so they need both halves. Re-seeding is additive: `deploy.sh` will not
move existing entries to a new `BASE_DN`, so a base-DN change is a rebuild
([Teardown](#teardown), then a fresh deploy).

### Rolling the CA
A new CA invalidates every browser trust import and both BIG-IP trust anchors, so it is opt-in
and always takes two steps:

```bash
WL_REGEN_CA=1 ./deploy.sh --stack   # mint a new CA and reissue every leaf certificate
docker compose --profile bundled restart keycloak openldap
./deploy.sh --bigip                 # push the new anchor + VIP certificate to the appliances
```

Then re-import `certs/ca.crt` into every browser and OS trust store that had the old one.
The full procedure, including what to back up first, is
[operations/runbooks/rotate-ca.md](operations/runbooks/rotate-ca.md).

## Verification
```bash
./scripts/validate.sh; echo "failed checks: $?"
scripts/demo-login.sh alice.admin
scripts/demo-login.sh bob.user
```

Expected, unchanged from [deploy.md](deploy.md#verification): zero failed checks; alice reaches
the webtop with both TMUI resources on the session and lands in TMUI as Administrator; bob
reaches the same webtop and lands read-only. If the CA fingerprint changed, browsers that have
not re-imported it will fail at the OIDC redirect rather than with a visible certificate
warning.

## Rollback
Both halves converge, so rolling back is rolling forward to the older revision:

```bash
git checkout <previous-revision>
./deploy.sh
```

For an image rollback, restore the previous tag in `docker-compose.yml` and re-run the stack
half. Keycloak's persisted store is not guaranteed to be readable by an older release, so if the
container fails to start after a downgrade, drop the volume and rebuild — accepting that
enrolled TOTP secrets are lost:

```bash
git checkout <previous-revision> -- docker-compose.yml
./deploy.sh --stack
docker compose logs --tail 50 keycloak     # if it will not start on the older image:
docker compose --profile bundled down -v && ./deploy.sh --stack
```

To back the appliances out rather than roll them back, see
[deploy.md](deploy.md#rollback) — restore `auth source type local` first, then delete objects.

## Teardown
Remove the stack, its volumes and the generated material:

```bash
docker compose --profile bundled down -v            # containers, network and all three volumes
sudo chown -R "$(id -u):$(id -g)" certs             # openldap chowns this dir at startup
rm -rf certs keycloak/import dns/Corefile
```

`-v` destroys `kcdata`, and with it **every enrolled TOTP secret**. That is the intended
behaviour for a demo you rebuild, but it is not recoverable — to reset a single user instead,
use [operations/runbooks/reset-user-mfa.md](operations/runbooks/reset-user-mfa.md).

Then back the BIG-IPs out, in this order — auth source first, so remote authentication is never
left pointing at a half-removed configuration:

```bash
for u in "${BIGIP_A_MGMT}" "${BIGIP_B_MGMT}"; do
  curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" -X PATCH -H 'Content-Type: application/json' \
    -d '{"type":"local"}' "https://${u}/mgmt/tm/auth/source" | jq -r .type
done
```

Then delete the APM objects listed in `bigip/lib/objects.sh` and config-sync, exactly as in
[deploy.md](deploy.md#rollback).

What teardown deliberately leaves alone: the BIG-IPs' local accounts, licence and provisioning;
and **an external directory** — warden-lite creates nothing in yours, binds read-only, and never
writes, so there is nothing of its making to delete there ([directory.md](directory.md)).

### Verification
```bash
docker ps --format '{{.Names}}'                     # no keycloak / warden-lite-dns / openldap
curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" "https://${BIGIP_A_MGMT}/mgmt/tm/auth/source" | jq -r .type
```

Expected: no warden-lite containers, and `local` from each unit. Confirm you can still log in to
both TMUIs as the local `admin` before you walk away.
