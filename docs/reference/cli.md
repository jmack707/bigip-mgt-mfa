# CLI reference — entry-point scripts

Every runnable script in the repo, what it needs, and how it exits. All of them source
`.env` from the repo root themselves, so each can be run on its own as well as through
`deploy.sh`.

_Last validated: 2026-07._

## Overview
Two commands do everything, and the rest are the individual steps they call — useful on
their own when you are rebuilding a single layer or working through the build by hand.

| Command | Purpose |
|---|---|
| `./deploy.sh [--stack\|--bigip]` | Stand up the demo. No argument means both halves, in order |
| `./teardown.sh [--stack\|--bigip] [--volumes]` | Remove what `deploy.sh` created, in reverse order |
| `scripts/validate.sh` | Assert a deployed demo, read-only. Exit code is the number of failed checks |
| `scripts/demo-login.sh [username]` | Walk the entire login chain headlessly, for one user, with no browser |

Two conventions hold throughout:

- **Every script sources `.env` itself.** There is no wrapper that exports configuration for
  the others, and no script depends on being invoked from a particular directory — each
  resolves the repo root from its own path. The BIG-IP-facing scripts additionally save
  `BIGIP_PASS` from the environment *before* sourcing `.env` and restore it afterwards, so
  an injected secret beats the file and `.env` can leave the field empty.
- **Re-running is safe.** Certificates are reused unless `MFA_REGEN_CA=1`, directory seeding
  tolerates entries that already exist, the additive BIG-IP calls tolerate `409`, and the
  mutable APM policy graph is deleted and rebuilt from one shared object list rather than
  patched in place.

Exit codes follow the shell convention: `0` success, non-zero failure, and `2` from
`deploy.sh` or `teardown.sh` specifically means bad invocation. `scripts/validate.sh` and
`scripts/preflight-directory.sh` are the two deliberate exceptions, described in their
sections below.

## `deploy.sh`
Orchestrates the whole demo. Two halves, deliberately separable: prove the Docker half works
before pointing anything at your appliances.

```bash
./deploy.sh            # both halves, stack first
./deploy.sh --stack    # Keycloak, CoreDNS and the directory only — touches no BIG-IP
./deploy.sh --bigip    # the BIG-IP half, against a stack that is already up
./deploy.sh --all      # same as no argument
./deploy.sh -h         # print the header comment and exit 0
```

`--help` is accepted as a synonym for `-h`. Any other argument prints a usage line and exits
`2`.

**Environment.** A `.env` file must exist in the repo root; the script exits `1` with a
pointer to `.env.example` if it does not. `openssl`, `jq`, `envsubst`, `curl` and the Docker
Compose **V2** plugin must be on `PATH` — the standalone v1 `docker-compose` binary is
rejected explicitly, because the invocation is `docker compose`. The `--bigip` half
additionally asserts `BIGIP_PASS`, `BIGIP_A_MGMT` and `BIGIP_B_MGMT` are set before it makes
a single call.

**What `--stack` does.** Prints the resolved directory model; mints certificates; renders
`dns/Corefile` and the Keycloak realm import; starts the containers, adding the `bundled`
Compose profile when `MFA_DIRECTORY_MODE=bundled`; in bundled mode applies the `memberof` and
`refint` overlays, then the bind-account ACL, then the seed and demo-user LDIFs; and finally
polls the realm's OpenID discovery document for up to five minutes, printing the issuer it
found. The overlay must land before the group is created — `memberOf` is only computed for
changes made after the overlay is active, so the reverse order silently yields no admins.

**What `--bigip` does.** Runs `bigip/system-auth.sh` against unit A and unit B in turn, then
`bigip/apm-build.sh` against unit A only, then triggers a config-sync to the device group
(discovered when `MFA_DEVICE_GROUP` is empty; skipped with a message when the unit is
standalone).

**Exit behaviour.** `set -euo pipefail`, so the first failing command stops the run. Missing
`.env`, a missing prerequisite command, an unrenderable realm template, or a Keycloak that
never publishes its realm all exit `1` with a one-line reason on stderr. Bad usage exits `2`.

## `teardown.sh`
Removes what `deploy.sh` created, mirroring its two halves.

```bash
./teardown.sh              # both halves
./teardown.sh --stack      # stop the containers, keep their data
./teardown.sh --bigip      # remove the access tier and restore local authentication
./teardown.sh --stack --volumes
./teardown.sh -h           # print the header comment and exit 0
```

Flags may be combined and are parsed in a loop, so `--stack --volumes` is valid. `--all` is
accepted, and no argument at all means both halves. `--volumes` applies to the stack half:
it adds `-v` to `docker compose down` and removes the cached TOTP secrets under `certs/`,
which **destroys every enrolled second factor** — the users will re-enrol on their next
login. Without it the volumes are kept and re-running `./deploy.sh --stack` restores the
same directory and the same enrolments. Any unrecognised argument prints a usage line and
exits `2`.

**Order matters in the BIG-IP half.** It flips `auth source` back to `local` and deletes the
remote-role rule on **both** units *first*, so that a failure later cannot leave an appliance
pointed at a directory that is about to disappear. `admin` and `root` are local accounts, so
neither direction of the flip can lock anyone out. It then deletes the mutable policy graph
from the same `bigip/lib/objects.sh` list the build uses, then the supporting objects the
build creates outside that list — façades, portal resources, webtop, form SSO, iRules, the
OAuth objects, the AAA LDAP server and pool, the resolver and the SSL profiles — saves the
configuration and triggers a config-sync.

The teardown is deliberately conservative about trust material: it leaves the installed CA
anchors and the demo CA in place. They are inert on their own, and removing them is not
worth the chance of disturbing something else on a shared lab appliance.

**Environment.** A `.env` must exist; a missing one exits `1`, since there is nothing to
address without it. The `--bigip` half asserts `BIGIP_PASS`, which may be injected. Needs
`curl`, `jq` and the Docker Compose V2 plugin.

**Exit behaviour.** `set -uo pipefail` without `-e`: teardown must keep going past objects
that are already gone. Individual `DELETE` statuses are printed but not checked, so a
transcript full of `404` is a clean teardown. Bad usage exits `2`; missing `.env` or an
unset `BIGIP_PASS` exits `1`.

## `scripts/gen-certs.sh`
Mints the demo CA and the server certificates the stack presents.

```bash
scripts/gen-certs.sh
MFA_REGEN_CA=1 scripts/gen-certs.sh    # deliberately roll the CA
```

Takes no arguments. Issues three leaf certificates into `certs/`: `keycloak.*` (the BIG-IP
validates this on the OAuth back-channel), `webtop.*` (installed on the VIP by
`bigip/apm-build.sh`; the browser must trust it because it is the OIDC `redirect_uri`
origin), and — bundled mode only — `ldap.*` for OpenLDAP's LDAPS listener. Each SAN covers
both the name a browser uses and the address the BIG-IP uses, because every one of these is
reached from both sides; a SAN mismatch fails closed and surfaces as an opaque APM error
rather than as a certificate warning.

**Environment.** `.env` for `MFA_HOST_IP`, `MFA_KEYCLOAK_FQDN`, `MFA_WEBTOP_FQDN`,
`MFA_APM_VIP`, `MFA_DOMAIN` and the directory mode. `openssl` on `PATH`. `MFA_CA_CN` overrides
the CA subject; `MFA_REGEN_CA=1` forces a new CA instead of reusing an existing one.

An existing CA is reused by default and that is load-bearing: `deploy.sh` is meant to be
re-runnable, and minting a fresh CA on every run would invalidate every browser trust import
and the anchors installed on both BIG-IPs. After a deliberate `MFA_REGEN_CA=1` roll, re-import
the CA in the browser and re-run `./deploy.sh --bigip` so the units pick up the new anchor.

The script also reclaims ownership of `certs/` before writing: the `osixia/openldap`
container chowns that bind-mounted directory at every startup, so local signing after the
stack has been up finds it root-owned. It uses `sudo` if available and otherwise fails early
with the exact `chown` to run.

**Exit behaviour.** `set -euo pipefail`. Exits `0` early in external mode after skipping the
LDAPS certificate, naming the CA file the BIG-IP will validate against instead. Exits
non-zero if `certs/` cannot be made writable or if `openssl` fails.

## `scripts/preflight-directory.sh`
Proves an **external** directory works before any BIG-IP is touched. Read-only: it binds,
searches and reads, and writes nothing.

```bash
scripts/preflight-directory.sh              # default test user: alice.admin
scripts/preflight-directory.sh jdoe
```

Takes one optional argument, the username to probe. Five checks: the bind account can bind;
the search base is readable *by that bind account*, because a base that exists but is not
readable looks identical to one that does not exist; the login attribute resolves the test
user to a DN; `memberOf` is actually **returned** for that user, and whether it names the
admin group; and an LDAPS bind on `MFA_LDAPS_PORT` validates against `MFA_LDAP_CA_FILE`.

Every failure it catches is one that would otherwise surface as an opaque authentication
error on the appliance, where the cause is invisible. The `memberOf` check earns its place
twice over: some directories compute the attribute but strip it from unprivileged reads, and
remote-role maps on it, so if it is missing here no user is ever elevated and nothing else
indicates why. Nested groups do not appear in `memberOf`, so the admin group must be one with
direct membership.

**Environment.** `.env`; `ldapwhoami` and `ldapsearch` on `PATH`. It reads the external block
described in [configuration.md](configuration.md) — `MFA_LDAP_HOST`, both ports,
`MFA_BIND_DN`, `MFA_BIND_PW`, `MFA_USER_SEARCH_BASE`, `MFA_LOGIN_ATTR`, `MFA_ADMIN_GROUP_DN` and
`MFA_LDAP_CA_FILE`.

**Exit behaviour.** Like the validator, `set -uo pipefail` and **the exit code is the number
of failed checks**. `0` means the directory is usable and `./deploy.sh --bigip` is safe to
run. A user who is simply not in the admin group is reported as a note, not a failure — it is
a legitimate outcome, and the read-only half of the demo depends on it.

## `scripts/validate.sh`
End-to-end assertions against a deployed demo. Read-only: it asserts, it never configures.

```bash
scripts/validate.sh
BIGIP_PASS='<bigip-admin-pw>' scripts/validate.sh   # injected rather than from .env
```

Takes no arguments. Seven sections: containers running; the two demo DNS records answering
from CoreDNS; the directory (bind account, both demo users, and that `alice.admin` is in the
admin group while `bob.user` is not); Keycloak's realm discovery and issuer; the BIG-IP
access tier on both units; the resulting role for each demo user; and the VIP answering on
`https://${MFA_WEBTOP_FQDN}/`.

The role check is asserted from each BIG-IP's own `/var/log/secure` audit line rather than
from an HTTP status code. F5's Guest role is denied iControl REST outright, so a correctly
read-only user answers `401` to `curl` — a status-code test would read the demo working as
the demo broken. The `pam_audit` line records the role TMOS actually assigned, which is the
question being asked.

**Environment.** `.env`; `docker`, `dig`, `ldapwhoami`, `ldapsearch`, `curl` and `jq` on
`PATH`. `BIGIP_PASS` may be injected. If it is empty the BIG-IP and role sections are
skipped rather than failed, and the run still exercises the whole Docker half.

**Exit behaviour.** `set -uo pipefail` without `-e`, on purpose: a failing check must record
a `FAIL` and continue rather than abort the run. **The exit code is the number of failed
checks** — `0` means everything passed, `3` means three assertions failed. Do not test it
for `1`.

## `scripts/demo-login.sh`
Walks the entire login chain for one demo user, headlessly, with no browser: APM logon page,
LDAP Auth, Keycloak username and TOTP, back to APM, webtop, resources.

```bash
scripts/demo-login.sh                # default: alice.admin
scripts/demo-login.sh bob.user
```

It exists because "the objects were created" and "a user can actually log in" are very
different claims, and only the second is worth demoing. It uses `curl --resolve` for both
the webtop FQDN and the Keycloak FQDN, so it works from a host that has not been pointed at
the demo resolver, as long as it has layer-3 reachability to the VIP.

**Environment.** `.env` for the FQDNs, `MFA_APM_VIP`, `MFA_HOST_IP`, `MFA_TEST_USER_PW` and —
for the final step — `BIGIP_USER`, `BIGIP_PASS` and `BIGIP_A_MGMT`. Needs `curl`, `jq`,
`base32` and **`oathtool`** (`apt install oathtool`), which is what computes the TOTP code.

**TOTP enrolment and the cached secret.** The realm makes `CONFIGURE_TOTP` a default required
action, so the first run for a given user is met with Keycloak's enrolment page. The script
reads the raw secret out of that form, base32-encodes it, prints it so you can add it to a
real authenticator app and repeat the flow by hand, and caches it at
`certs/.totp-<username>` with mode `0600`. `certs/` is gitignored in full, so the secret is
never committed. Every later run reads the cached file; if the OTP challenge appears and no
cached secret exists, the script stops and says so rather than guessing. Deleting the cache
file does **not** re-enrol — Keycloak still holds the credential — so to start over, remove
the OTP credential from the user in the Keycloak console first.

**Exit behaviour.** `set -uo pipefail`. Any failed step prints one red line and exits `1`;
the final step also dumps the last response to `/tmp/wl-webtop.html` when the session does
not land on the webtop. A complete run exits `0` after confirming that both units' TMUI
resources are attached to the session — asserted from the BIG-IP session table
(`session.assigned.resources.pa`), not from the returned HTML, because the modern webtop
loads its resource list asynchronously and scraping the first response reports no resources
even on a perfectly good session.

## `bigip/system-auth.sh`
Per-unit remote authentication and authorization. **Run against each unit of the pair.**

```bash
BIGIP_MGMT=<bigip-a-mgmt-ip> bigip/system-auth.sh
BIGIP_MGMT=<bigip-b-mgmt-ip> bigip/system-auth.sh
```

Takes no arguments; the unit is selected by `BIGIP_MGMT`, which the script requires and does
not default. `deploy.sh --bigip` sets it per unit and calls this twice. Running it against
only one unit is the classic "works until failover" bug: `auth ldap system-auth` and `auth
source` live in the device-local configuration and a config-sync does not carry them.
(`auth remote-role` does sync, but it cannot authenticate anyone on its own.)

Five steps: upload the directory CA and create-or-**update** the `ssl-cert` object (an
existing object still holds the old CA, and stale trust fails closed); write the LDAPS
`system-auth` object with `checkRolesGroup` enabled; set `remote-user` to `defaultRole:
guest` with remote console access disabled; write the single `bigip_mgt_mfa_admins`
remote-role rule from `MFA_ADMIN_ROLE_ATTRIBUTE`; then flip `auth source` to `ldap` and save
the configuration.

**Environment.** `.env` plus `BIGIP_MGMT`. `BIGIP_PASS` is required and may be injected.
`MFA_LDAP_CA_FILE` must point at a readable PEM — a relative value is resolved against the
repo root, and a missing file exits `1` before any call is made. `curl` and `jq` on `PATH`.

`admin` and `root` remain local TMOS accounts, so switching the auth source cannot lock you
out of the box.

**Exit behaviour.** `set -euo pipefail`, and no tolerated failures: the request helper prints
the response body and exits `1` on any status `>= 400`, or on no HTTP response at all. A
half-configured auth source is worse than none.

## `bigip/apm-build.sh`
Builds the whole APM access tier on **one** unit; the config-sync `deploy.sh` triggers
carries it to the peer.

```bash
bigip/apm-build.sh                                  # defaults to BIGIP_A_MGMT
BIGIP_MGMT=<bigip-a-mgmt-ip> bigip/apm-build.sh     # explicit target
```

Takes no arguments. `BIGIP_MGMT` selects the target and defaults to `BIGIP_A_MGMT`. Eleven
steps, in order: install the VIP certificate and the demo CA; delete the mutable policy
graph; create the AAA LDAP server and its pool; create the DNS resolver; create the OAuth
provider, server and the three request objects; create the customization groups; create the
policy agents; create the shadow façades and their `node` iRules; create the webtop, the
TMUI form SSO and one portal resource per unit; assemble the policy graph inside a single
transaction; and create the webtop virtual server, then save the configuration.

The policy order is the design: logon page, LDAP Auth, OAuth Client, SSO credential mapping,
resource assign, Allow — with any failure ending in Deny. APM collects the password and
proves it against the directory *first*, which is what puts the credential in the session
where it can be single-signed-on to TMUI. Only then does it step up to Keycloak for the
second factor. Reverse the order and APM never sees a password, which is the design that
needs a vault.

**Environment.** `.env`; `BIGIP_PASS`, `MFA_BIND_PW` and `MFA_APM_VIP` are asserted explicitly
and the script exits `1` naming whichever is missing. Needs `curl`, `jq` and `stat`, and the
certificates `scripts/gen-certs.sh` produces — it uploads `certs/webtop.crt`,
`certs/webtop.key` and `certs/ca.crt` from the repo.

**Idempotency.** The mutable graph is torn down before the OAuth objects are rebuilt, not
after: the `aaa-oauth` agent holds references to the request objects, so they cannot be
recreated while it still exists. Tearing down first is what makes a re-run genuinely
converge rather than silently keep the previous values. Everything else is additive and
tolerates `409`.

**Exit behaviour.** `set -euo pipefail`. The additive helper accepts `200`, `201` and `409`
and returns non-zero on anything else, printing the response body. A transaction commit that
does not come back `COMPLETED` is printed in full — the graph was rejected as a unit and
nothing was applied. Deletes are not checked, because `404` is the desired end state.

## Sourced libraries
Not entry points. They are sourced by the scripts above and do nothing on their own.

| File | Provides |
|---|---|
| `scripts/lib/directory.sh` | The single source of truth for the directory model: validates `MFA_DIRECTORY_MODE`, derives every DN, port, login attribute, CA name and Keycloak federation setting, exports them, and defines `wl_is_bundled` and `wl_directory_summary` |
| `scripts/lib/certs.sh` | `ensure_certs_writable`, which reclaims `certs/` after the OpenLDAP container has chowned it |
| `bigip/lib/objects.sh` | `wl_apm_objects <prefix> <partition>`, the ordered list of mutable APM objects — policy and profile first, then the items they reference, or TMOS refuses the delete as in use |

Source them after `.env`, never before: each is written to fill in defaults around values
that `.env` has already set.

## Related
- [configuration.md](configuration.md) — every variable these scripts read.
- [api.md](api.md) — the endpoints they call.
- [../deploy.md](../deploy.md) — the order to run them in, and what to check between steps.
- [../operations/troubleshooting.md](../operations/troubleshooting.md) — what to do when one
  of them fails.

## `scripts/enroll-totp.sh`

Issues, lists and revokes the soft-token seeds that the BIG-IP verifies against. This is the
piece a commercial MFA product would provide as a self-service portal.

```bash
scripts/enroll-totp.sh <username> [<username> ...]   # issue (or replace) a token
scripts/enroll-totp.sh --list                        # who holds a token
scripts/enroll-totp.sh --revoke <username>           # remove one
```

Generates a 20-byte base32 seed per user, writes it to `certs/totp-seeds.env` (mode 600,
gitignored) and prints both a scannable QR and a typeable setup key. Re-running for a user
replaces their seed.

**It does not touch the BIG-IP.** `./deploy.sh --bigip` is what loads the seeds into the
`bigip_mgt_mfa_totp_dg` data group. Enrolling without that step produces codes the appliance
rejects, which is indistinguishable from a broken authenticator.

Environment: reads `.env` for `MFA_TOTP_PERIOD` and `MFA_TOTP_ISSUER`. Needs `openssl`, and
`qrencode` for the QR. Exit code 0 on success, 1 on a usage or environment error.

## `scripts/test-mfa-matrix.sh`

Drives real logins against the webtop and asserts the full accept/deny matrix.

```bash
scripts/test-mfa-matrix.sh
```

Seven cases: each demo user with their own correct code, and five that must be refused —
including **a correct password paired with another user's code**. That case is the reason the
previous Keycloak design was discarded, and no manual test thinks to try it.

Generates codes on `MFA_TOTP_PERIOD`, so it stays correct when the period changes. Requires
`oathtool`, `.env`, and enrolled seeds. Prints PASS/FAIL per case; exit code 0 when every
case behaves as expected.
