# Deploy — the BIG-IP half

Point both units of the HA pair at the directory for system authentication and authorization,
then build the APM front door on one of them and let config-sync carry it to the peer.

_Last validated: 2026-07-30_

## Scope
This page covers `./deploy.sh --bigip`: what it changes on the appliances, how to prove it, and
how to back it out. The Docker stack it depends on is [install.md](install.md), and it must be
up and green first — the BIG-IP half uploads certificates minted by the stack half and points
TMOS at the stack's LDAP and Keycloak endpoints. `./deploy.sh` with no argument runs both halves
in that order.

Two things happen here and they are deliberately separate:

- **`bigip/system-auth.sh`, on *both* units.** `auth ldap system-auth` and `auth source` are
  device-local configuration; a config-sync does **not** carry them to the peer. (`auth
  remote-role` *is* synced, but a role rule is inert on a unit with no directory configured,
  so running this on one unit only fails just the same.) This is the half that decides alice is an Administrator and bob is read-only, and the
  target BIG-IP decides it — not APM, not Keycloak
  ([adr/0003-authorization-on-remote-role.md](adr/0003-authorization-on-remote-role.md)).
- **`bigip/apm-build.sh`, on unit A only.** The access tier: the VIP certificate, the AAA LDAP
  server, the DNS resolver, the Keycloak OAuth provider and server, the policy graph, the webtop
  and the two portal resources. This *is* synced, so it is built once and pushed.

## Prerequisites
- A licensed BIG-IP HA pair with **LTM and APM provisioned** on both units, joined in a
  sync-failover device group. A standalone unit works too — `deploy.sh` reports that it found no
  device group and skips the sync.
- REST reachability from the Docker host to `BIGIP_A_MGMT` and `BIGIP_B_MGMT` on `443`.
- `.env` complete: `BIGIP_USER`, `BIGIP_A_MGMT`, `BIGIP_B_MGMT`, `BIGIP_A_TMUI`, `BIGIP_B_TMUI`,
  `MFA_APM_VIP` and `MFA_WEBTOP_FQDN`. `BIGIP_PASS` may be set in `.env` (demo) or injected in the
  environment — an injected value wins over the file, so a production password never has to be
  written to disk.
- `BIGIP_A_TMUI`/`BIGIP_B_TMUI` must be each unit's **non-floating internal self IP**. They are
  the SSO targets behind the RFC5737 façades; a floating address would follow the failover and
  both webtop tiles would land on the same unit.
- The stack half verified: `./scripts/validate.sh` green apart from the BIG-IP sections.
- `admin` and `root` remain **local** accounts on TMOS throughout. Switching the auth source to
  LDAP cannot lock you out of the box.

## Procedure
```bash
./deploy.sh --bigip
```

### Step 1 — system auth on both units
`deploy.sh` loops over `BIGIP_A_MGMT` and `BIGIP_B_MGMT`, running `bigip/system-auth.sh` against
each. To run one unit by hand:

```bash
BIGIP_MGMT="${BIGIP_A_MGMT}" bigip/system-auth.sh
BIGIP_MGMT="${BIGIP_B_MGMT}" bigip/system-auth.sh
```

Per unit it uploads the directory CA as an `ssl-cert` object, creates or updates
`auth ldap system-auth` (LDAPS on `MFA_LDAPS_PORT`, CA-verified, bound as the read-only bind
account, `checkRolesGroup enabled`), sets `remote-user` to `defaultRole guest` with remote
console access disabled, creates the single `remote-role` rule `bigip_mgt_mfa_admins`
(`memberOf=<admin group> → administrator`), switches `auth source` to `ldap`, and saves the
config.

`checkRolesGroup` is what makes TMOS consult the remote-role rules at all. With it disabled the
rules are ignored and *every* remote user lands on the default role — the demo still logs in,
but the authorization half silently disappears.

### Step 2 — the APM front door on unit A

```bash
BIGIP_MGMT="${BIGIP_A_MGMT}" bigip/apm-build.sh
```

The policy graph it builds is
`Start → Logon Page → LDAP Auth → OAuth Client (Keycloak) → SSO Credential Mapping →
Resource Assign → Allow`, with every failure branch ending in Deny. The order is the design:
APM collects the password and proves it against the directory *first*, so the credential is in
the session and can be single-signed-on into TMUI, and only then steps up to Keycloak for the
second factor. A failed second factor denies rather than degrading to first-factor-only access.
See [adr/0001-apm-first-auth-order.md](adr/0001-apm-first-auth-order.md).

Each unit's TMUI is published behind a non-routable RFC5737 façade (`MFA_SHADOW_A`,
`MFA_SHADOW_B`) fronted by a plain LTM virtual with a `node` iRule, because APM portal access
refuses self-IPs and management addresses as targets outright, and publishing TMUI on a routable
external self-IP would be a hole in any case.

### Step 3 — config-sync
`deploy.sh` resolves the sync-failover device group (from `MFA_DEVICE_GROUP`, or by REST) and
runs `tmsh run cm config-sync to-group <group>` on unit A. To do it by hand:

```bash
tmsh run cm config-sync to-group <device-group>   # on unit A
tmsh show cm sync-status                          # expect: In Sync
```

## Idempotency
Re-running is the supported way to apply a change, and each part converges differently for a
reason:

- **The CA is reused.** `scripts/gen-certs.sh` keeps an existing `certs/ca.crt`/`ca.key` unless
  `MFA_REGEN_CA=1`, because minting a fresh CA on every run would invalidate every browser trust
  import and both BIG-IP trust anchors. The **leaf** certificates are reissued on every run, so
  changing `MFA_HOST_IP`, `MFA_KEYCLOAK_FQDN`, `MFA_WEBTOP_FQDN` or `MFA_APM_VIP` and re-running
  produces correct SANs without any extra step.
- **Directory seeding tolerates existing entries.** `ldapadd` runs with `-c` and the deployer
  reports "entries already present" rather than failing; the overlay step likewise reports
  "already present". Seeding is additive, so a re-run never rewrites a user you have changed.
- **System auth creates or updates.** Each object is probed first and PATCHed if it exists.
  The trust anchor is refreshed rather than skipped — an existing `ssl-cert` object still holds
  the *old* CA, and stale trust fails closed.
- **The APM build is teardown-first.** Before anything is created it deletes the mutable policy
  graph — the virtual server, access profile, access policy, every policy item and every agent.
  That list lives in `bigip/lib/objects.sh` (`wl_apm_objects`) and is deliberately ordered
  profile-and-policy-first, because TMOS refuses to delete an object that is still referenced.
  A half-applied change therefore cannot survive a re-run.
- **The `oauth-request` objects are delete-then-create.** `tmsh create` is not idempotent and
  there is no create-or-update form for them, so each is deleted (errors ignored) and recreated.
  They are torn down *before* the rest for the same reason: the `aaa-oauth` agent holds
  references to them and they cannot be replaced while it exists.
- **Everything else is an additive `POST` that tolerates `409 Conflict`** — pools, profiles,
  iRules, customization groups, the webtop and the portal resources.

```bash
./deploy.sh --bigip          # after editing .env or the build
./deploy.sh                  # both halves
```

## Verification
```bash
./scripts/validate.sh; echo "failed checks: $?"
```

`validate.sh` is read-only: it asserts, it never configures, and it exits with the number of
failed checks (`0` when everything passes). It covers the containers, the demo DNS zone, the
directory and both group memberships, the Keycloak issuer, `remote-role`/`auth source`/default
role **on both units**, the access profile on A *and* its arrival on B, both portal resources,
and the VIP answering.

The role assertions are read from the BIG-IP's own `pam_audit` lines in `/var/log/secure` rather
than from HTTP status codes, because the Guest role legitimately cannot use iControl REST — a
status-code test would read bob's correct `401` as a fault.

Then walk the entire login chain headlessly, including the second factor:

```bash
scripts/demo-login.sh alice.admin
scripts/demo-login.sh bob.user
```

Expected: logon page → password accepted → redirect to Keycloak → TOTP → back to APM → webtop,
with both `bigip-mgt-mfa-bigip-a-tmui` and `bigip-mgt-mfa-bigip-b-tmui` on the session. On a user's
first run it performs the TOTP enrolment Keycloak requires and prints the secret so you can add
it to a real authenticator and repeat the flow by hand; the secret is cached in
`certs/.totp-<user>` for subsequent runs.

The final human confirmation — that each webtop tile auto-logs-in, and that alice gets full
menus while bob gets a read-only TMUI on the same tile — is a browser click-through. A failover
does not change that answer, and
[operations/runbooks/failover-check.md](operations/runbooks/failover-check.md) proves it.

## Rollback
Re-running the build from the previous committed revision restores the prior policy, because it
tears the mutable graph down first:

```bash
git checkout <previous-revision>
./deploy.sh --bigip
```

To back the appliances out entirely:

```bash
./teardown.sh --bigip
```

The order it uses is deliberate. On **both** units it restores `auth source type local` and
deletes the `bigip_mgt_mfa_admins` remote-role **first**, so a failure later cannot leave a unit
pointed at a directory configuration that is about to disappear. `admin` and `root` are always
local accounts, so this step cannot lock you out. Only then does it delete the access tier on
unit A — the mutable graph from `wl_apm_objects` in `bigip/lib/objects.sh`, which is the same
list the build tears down so the two cannot drift, followed by the supporting objects the build
creates outside it (the shadow virtuals and their iRules, the portal resources, the webtop, the
form-SSO object, the OAuth provider/server/request objects, the AAA LDAP server and its pool,
the DNS resolver, and the two SSL profiles). It saves the config and triggers a config-sync so
the peer drops them too.

It deliberately leaves the trust anchors, the uploaded certificates and the demo CA in place:
they are inert on their own, and removing them is not worth the chance of disturbing something
else on a shared lab appliance.

If you only want to restore local authentication and keep the access tier, do that one step by
hand — it is reversible by re-running `bigip/system-auth.sh`:

```bash
# on each unit, from tmsh
tmsh modify auth source type local
tmsh save sys config
```

Confirm with `./scripts/validate.sh` that the checks now fail in the way you intended, and log
in to both TMUIs as the local `admin` before you walk away.
