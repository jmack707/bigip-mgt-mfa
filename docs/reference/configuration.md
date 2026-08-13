# Configuration reference

Every setting that governs bigip-mgt-mfa: the `.env` keys you edit, the values
`scripts/lib/directory.sh` derives from them, and the handful of environment overrides the
scripts honour but `.env.example` does not list. Site-specific values use the angle-bracket
form, e.g. `<bigip-a-mgmt-ip>`.

_Last validated: 2026-08._

## Overview
`.env` is the only file you edit. Copy [`.env.example`](../../.env.example) to `.env` — the
copy is gitignored — fill in the angle-bracket values, and every other artefact is rendered
in the repo hardcodes a DN, a port or an address.

Three rules make the rest of this page readable:

- **Required** means a script refuses to run without the value. Which values are required
  depends on what you run. `./deploy.sh --stack` needs no `BIGIP_*` at all;
  `./deploy.sh --bigip` needs them and nothing else; `MFA_DIRECTORY_MODE=external` swaps the
  bundled-directory keys for the external block.
- **Empty is meaningful** for several keys. `MFA_ADMIN_GROUP_DN`, `MFA_ADMIN_ROLE_ATTRIBUTE`,
  `MFA_BIND_DN`, `MFA_USER_SEARCH_BASE`, `MFA_LOGIN_ATTR` and `MFA_DEVICE_GROUP` ship empty on
  purpose: empty means "derive it", and the derivation lives in one place
  ([`scripts/lib/directory.sh`](../../scripts/lib/directory.sh)) so a value set once is
  validator.
- **`.env` is sourced with `set -a`**, so every key becomes an exported environment
  variable. That is what lets `envsubst` render the templates, and it is also why an
  injected `BIGIP_PASS` would otherwise be clobbered — the scripts that touch a BIG-IP save
  the injected value before sourcing `.env` and restore it afterwards.

## This host
| Variable | Default | Meaning |
|---|---|---|

`MFA_HOST_IP` is the single most load-bearing value in the file, because three different
consumers resolve to it and two of them fail closed on a mismatch. It becomes an `IP:` SAN
([`scripts/gen-certs.sh`](../../scripts/gen-certs.sh)); it is the address CoreDNS binds its
UDP and TCP listeners to rather than the wildcard, because most Linux hosts already run a
stub resolver on `127.0.0.53` and binding `0.0.0.0` collides with it; and it is the
nameserver address configured in the BIG-IP's TMOS DNS resolver. Set it to the lab address
the appliances can route to, never to `127.0.0.1`.

If you change it after a deployment, re-run `scripts/gen-certs.sh` with `MFA_REGEN_CA` unset
(the leaf certificates are reissued, the CA is kept) and then `./deploy.sh --bigip`, or the
opaque APM error rather than as a certificate warning
([troubleshooting.md](../operations/troubleshooting.md)).

## Directory
| Variable | Default | Meaning |
|---|---|---|
| `MFA_DIRECTORY_MODE` | `bundled` | `bundled` runs bigip-mgt-mfa's own OpenLDAP in Docker and seeds it; `external` points at your AD, FreeIPA or LDAP and creates nothing in it ([directory.md](../directory.md), [ADR 0005](../adr/0005-bundled-directory-default.md)) |
| `MFA_DOMAIN` | `bigip-mgt-mfa.lab` | LDAP domain. In bundled mode it sets the OpenLDAP container's suffix and hostname, the LDAPS certificate CN and SAN, and the zone CoreDNS is authoritative for |
| `BASE_DN` | `dc=bigip-mgt-mfa,dc=lab` | Directory base DN. Must correspond to `MFA_DOMAIN`; every derived DN below is built from it |
| `MFA_LDAP_ADMIN_PW` | _(required in bundled mode)_ | `cn=admin,${BASE_DN}` password for the bundled OpenLDAP. Used by the container and by the seeding `ldapadd` calls in `deploy.sh`. Ignored in external mode |

The two modes are a configuration change, not a different design. In both, the interaction
with the directory is: bind to search, bind as the user to verify a password, read
which is what makes it safe to aim `external` mode at a production AD.

`MFA_DIRECTORY_MODE` is validated where it is read — an unrecognised value aborts before any
container starts or any REST call is made.

### `MFA_BIND_PW`
Type: string. Default: none. Required: **yes**.

Password for the read-only search account named by `MFA_BIND_DN`. APM binds with it to find
the user before authenticating them, so a wrong value fails every login at the LDAP step with
`Failed to bind ... Invalid credentials` — naming the bind DN, not the user's, which is
easy to misread as the user's password being wrong.

In bundled mode this is the password the seeding scripts set on the account they create. With
an external directory it must match what your directory administrator issued.

Note that `apm aaa ldap` is created, not modified, on a re-run: changing this value takes
effect because the build deletes and recreates the AAA object. Earlier revisions did not, and
a stale bind DN survived a domain change with no indication anything was wrong.

## The BIG-IP admin group
| Variable | Default | Meaning |
|---|---|---|
| `MFA_ADMIN_GROUP_DN` | `cn=bigip-admins,ou=groups,${BASE_DN}` | The group whose members get Administrator on **both** BIG-IPs |
| `MFA_ADMIN_ROLE_ATTRIBUTE` | `memberOf=${MFA_ADMIN_GROUP_DN}` | The `<attribute>=<value>` pair the BIG-IP's remote-role rule matches to elevate a user |

This pair is the entire authorization story, and it is evaluated by the target BIG-IP, not
`bigip_mgt_mfa_admins`, with `attribute` set to `MFA_ADMIN_ROLE_ATTRIBUTE` and `role` set to
`administrator`. Everyone who authenticates and matches no rule falls through to
`remote-user defaultRole: guest` with remote console access disabled. Nothing about the
read-only user is configured anywhere — read-only is the default, and admin is the single
exception.

`MFA_ADMIN_ROLE_ATTRIBUTE` is deliberately expressed as real group membership rather than an
attribute stamp. bigip-mgt-mfa has no account-provisioning step, so there is nothing to stamp,
and `memberOf` is what a real directory already carries. Keeping the same expression in both
modes is what makes the AD path a change of values rather than a change of design. Override
it only if your directory expresses group membership under a different attribute; the value
is written verbatim into the remote-role object, and `scripts/validate.sh` asserts that what
came back from `/mgmt/tm/auth/remote-role/role-info/bigip_mgt_mfa_admins` equals this string.

One related setting is not exposed in `.env` and should not be: `checkRolesGroup` is forced
to `enabled` on the LDAP system-auth object. Disabled, TMOS never consults the remote-role
rules at all and every remote user — including the admin — lands on the default role.

## External directory
Ignored when `MFA_DIRECTORY_MODE=bundled`, where each falls back to the derived value in the
default column.

| Variable | Default | Meaning |
|---|---|---|
| `MFA_LDAP_HOST` | bundled: `${MFA_HOST_IP}` | Address of the AD domain controller or LDAP server. Required in external mode |
| `MFA_LDAPS_PORT` | `636` | LDAPS port. Used only by the BIG-IP's own system authentication, which is TLS-only |
| `MFA_LDAP_CA_FILE` | bundled: `certs/ca.crt` | PEM of the CA that issued your LDAPS certificate. Required in external mode; a relative path is resolved against the repo root |
| `MFA_BIND_DN` | `cn=bigip-bind,ou=svc,${BASE_DN}` | Read-only search bind. It never needs write access and never needs to read `userPassword`, because passwords are verified by BIND rather than by comparison |
| `MFA_USER_SEARCH_BASE` | `ou=people,${BASE_DN}` | Subtree identities are searched in |

`MFA_LDAP_PORT` and `MFA_LDAPS_PORT` are both live in bundled mode too, despite the block
heading in `.env.example`: APM queries the directory over `MFA_LDAP_PORT` and the BIG-IP's
system authentication uses `MFA_LDAPS_PORT`. The comment marks the block as the one you must
fill in for an external directory, not the only place the keys are read.

## DNS
| Variable | Default | Meaning |
|---|---|---|
| `MFA_DNS_PORT` | `53` | Host port CoreDNS binds on `MFA_HOST_IP`, UDP and TCP. Change it if something already owns `:53` |
| `MFA_DNS_UPSTREAM` | `1.1.1.1` | Where names outside the demo zone are forwarded |

TMM and does **not** read the BIG-IP's `/etc/hosts`. A hosts-file entry can cover the
browser; it can never cover the BIG-IP. Rather than make the demo depend on a DNS server you
may not be permitted to edit, bigip-mgt-mfa ships CoreDNS, authoritative for `MFA_DOMAIN` and
forwarding everything else to `MFA_DNS_UPSTREAM`, and `bigip/apm-build.sh` creates a
forward-zone resolver pointing at `${MFA_HOST_IP}:${MFA_DNS_PORT}`.

The zone is rendered from [`dns/Corefile.tmpl`](../../dns/Corefile.tmpl) and holds exactly
Pointing a workstation at this resolver as well is safe — non-demo names are forwarded — and
it removes the browser hosts-file step entirely.

## The BIG-IP HA pair
| Variable | Default | Meaning |
|---|---|---|
| `BIGIP_USER` | `admin` | Account used for every iControl REST call |
| `BIGIP_PASS` | _(required for the BIG-IP half)_ | That account's password |
| `BIGIP_A_MGMT` | _(required)_ | Unit A's management address. The APM access tier is built here |
| `BIGIP_A_TMUI` | _(required)_ | Unit A's **non-floating** internal self IP — the SSO target for its own TMUI |
| `BIGIP_B_MGMT` | _(optional)_ | Unit B's management address. Receives system authentication and the remote-role rule only |
| `BIGIP_B_TMUI` | _(optional)_ | Unit B's non-floating internal self IP. Required **only** when `BIGIP_B_MGMT` is set |

`BIGIP_PASS` is plaintext in `.env` for the demo. In production, inject it from a secret
manager instead: every script that touches a BIG-IP reads `BIGIP_PASS` from the environment
before sourcing `.env` and restores the injected value afterwards, so an exported value wins
over the file and the file can be left empty.

### One BIG-IP or two
A single unit is a complete deployment, not a degraded one. Most UDF blueprints and most home
labs hand you exactly one BIG-IP, and nothing about MFA at the management edge needs a pair —
the pair only makes the *failover* story demonstrable.

`BIGIP_B_MGMT` is the single switch, and [`scripts/lib/units.sh`](../../scripts/lib/units.sh)
is where every script asks about it. Leave it blank and the deployment has one webtop tile,
one `system-auth` pass and no peer-sync assertion; set it — together with `BIGIP_B_TMUI` — and
the second unit's façade virtual, `node` iRule, portal resource and tile are all built.

Two details are worth knowing:

- **A leftover sample value counts as blank.** A value still in the angle-bracket form used
  elsewhere in `.env.example` — `"<bigip-b-mgmt-ip>"` — is not an address, and treating it as
  one produces a webtop tile that hangs and a `system-auth` run against a name that does not
  resolve, both of which read as BIG-IP faults rather than as an unfinished `.env`. Quote it
  if you leave one there: `.env` is sourced by `bash`, so an **unquoted** `<…>` is parsed as a
  redirect and the whole file fails with `syntax error near unexpected token 'newline'` before
  any of this is consulted. That is why the second unit's keys ship empty rather than sampled.
- **Setting `BIGIP_B_MGMT` without `BIGIP_B_TMUI` is refused** before any call is made. The
  alternative is a published tile with nothing behind it, which fails silently at click time.

The switch converges both ways: clearing `BIGIP_B_MGMT` from an existing pair deployment and
re-running `./deploy.sh --bigip` deletes B's portal resource, façade virtual server and `node`
iRule as well as rebuilding the tile list without it.

### Two units, no HA
Declaring a second unit does **not** require the two to be in a sync-failover device group.
Nothing in the login chain depends on the HA relationship:

- The access tier is built on unit A only, so it is where it needs to be either way.
- B's webtop tile reaches B by routing to `BIGIP_B_TMUI` from A, which is ordinary IP
  reachability rather than anything HA provides.
- B's authorization is written **directly** by `bigip/system-auth.sh` — `auth ldap
  system-auth`, `auth source`, the `guest` default and every `remote-role` rule — on each
  configured unit. `auth remote-role` also happens to config-sync, but nothing here relies on
  that.

What you do not get is failover: the VIP lives on A, so A going away takes the demo with it.
`MFA_APM_TRAFFIC_GROUP` is still pinned and still succeeds — `traffic-group-1` exists on a
standalone unit — it simply has nothing to float to.

Both the deploy and the validator discover the device group rather than inferring it from
`.env`. With no sync-failover group, `deploy.sh` reports there is nothing to sync and
`scripts/validate.sh` reports the peer-sync assertion as a `SKIP` rather than failing for an
access profile that is correctly absent from B.

The two `_TMUI` addresses must be the units' *non-floating* self IPs. A floating address
follows the active unit, so publishing it would give both webtop tiles the same destination
after a failover and quietly break the "two distinct BIG-IPs" claim the demo makes. They are
consumed by the `node` iRules behind the shadow façades described below, never by a pool — a
BIG-IP pool member cannot be a self IP.

`BIGIP_MGMT` is not a `.env` key. It is the per-unit selector that `deploy.sh` exports
around each call to `bigip/system-auth.sh`, and it defaults to `BIGIP_A_MGMT` in
`bigip/apm-build.sh`. Set it yourself only when running those scripts directly — see
[cli.md](cli.md).

## APM data plane
| Variable | Default | Meaning |
|---|---|---|
| `MFA_APM_VIP` | _(required)_ | Address of the webtop virtual server. Browsers reach the demo at `https://<vip>/` |
| `MFA_APM_TRAFFIC_GROUP` | `traffic-group-1` | Intended traffic group for the floating VIP |
| `MFA_SHADOW_A` | `192.0.2.5` | RFC 5737 TEST-NET façade in front of unit A's TMUI |
| `MFA_SHADOW_B` | `192.0.2.6` | Façade in front of unit B's TMUI. Unused unless `BIGIP_B_MGMT` is set |

`MFA_WEBTOP_FQDN` appears in three places that must agree: the SAN on the VIP certificate,
browser that reaches the VIP by address still completes the redirect.

`MFA_SHADOW_A` and `MFA_SHADOW_B` exist because APM Portal Access refuses "reserved" targets —
self IPs, the management address, cluster addresses — rejecting them outright rather than
proxying them. Publishing TMUI on a routable external self IP would be a hole in any case.
So each unit's TMUI is fronted by a non-routable RFC 5737 documentation address: the portal
resource targets the façade, a plain LTM virtual server listens on it, and a one-line `node`
iRule makes the real last hop to `BIGIP_A_TMUI` or `BIGIP_B_TMUI`. The build also sets the
`tmm.tcl.rule.connect.allow_loopback_addresses` and `tmm.tcl.rule.node.allow_loopback_addresses`
sys `db` keys, without which the iRule's `node` verb refuses the internal target. Keep the
defaults unless `192.0.2.0/24` collides with something you route.

### The façade's source address
The façade virtual's server-side connection **must not have the same source and destination
address** — TMM will not complete such a connection, and the failure is silent. The build
guarantees that by pinning the source with a dedicated SNAT pool rather than leaving it to
`automap`:

| Object | Value |
|---|---|
| SNAT pool | `bigip-mgt-mfa-facade-snat` |
| Member | `MFA_FACADE_SNAT_ADDR`, default host `.240` on `BIGIP_A_TMUI`'s subnet |
| Applies to | every façade virtual, on **standalone and HA alike** |

This is one configuration for both shapes — no branching on unit count. `automap` only ever
worked on a pair by accident, because a floating self IP exists there and automap prefers it;
on a standalone unit, or the standby half of a pair, the only address on that VLAN *is* the
`node` target.

The address never leaves the appliance (the hop is TMM to its own self IP), so it needs no
route and nothing in the fabric sees it — which is what makes it safe in environments like UDF
that drop traffic from addresses they have not assigned. It must simply not collide with a
real host on that subnet.

`bigip/apm-build.sh` PATCHes both the pool member and each virtual's translation on every run
rather than relying on the creates, which tolerate `409` — so an existing deployment converges
instead of keeping a translation that cannot work.

Getting this wrong is not a visible error: the tile completes its TLS handshake with the façade
and then resets after ten seconds, while every object involved reads as correct. See
[A webtop tile resets instead of opening TMUI](../operations/troubleshooting.md#a-webtop-tile-resets-instead-of-opening-tmui),
and [ADR 0007](../adr/0007-facade-source-address.md) for the measurements behind the two
rejected alternatives (`none`, and adding a self IP).

`MFA_APM_TRAFFIC_GROUP` is declared in `.env.example` and exported with the rest of the file,
but no script in the repo currently reads it. `bigip/apm-build.sh` creates the webtop virtual
server without an explicit traffic group, so the VIP inherits the device default. Treat the
key as documentation of intent and set the traffic group on `bigip-mgt-mfa-vs` yourself if the
default is not what you want.

## Demo principals
| Variable | Default | Meaning |
|---|---|---|
| `MFA_TEST_USER_PW` | _(required in bundled mode)_ | Password for the two seeded demo users, `alice.admin` and `bob.user` |

The two users differ in exactly one respect: `alice.admin` is a member of the admin group
and `bob.user` is not. `scripts/validate.sh` asserts both halves — that alice carries
`memberOf` and that bob does not — because if either is wrong the role outcome on TMUI is
wrong too. In external mode nothing is seeded and this key is unused, except that
`scripts/demo-login.sh` and `scripts/validate.sh` still submit it as the password for
whichever principals they probe.

## HA
| Variable | Default | Meaning |
|---|---|---|
| `MFA_DEVICE_GROUP` | _(empty)_ | Device group used for config-sync. Empty means "discover it" |

Left empty, `deploy.sh` queries `/mgmt/tm/cm/device-group` on unit A and takes the first
group whose `type` is `sync-failover`. If none exists the unit is treated as standalone and
the sync step is skipped rather than failed. Set the key explicitly when a unit belongs to
several sync-failover groups and the first one returned is not the one you want.

The sync is what carries the APM access tier from A to B, along with `auth remote-role`.
It is not what carries system authentication: `auth ldap system-auth` and `auth source` live
in the device-local configuration and are never synced, which is why `deploy.sh` runs
`bigip/system-auth.sh` against every configured unit. Skipping unit B leaves a unit that still
authenticates locally, so the synced role rule has nothing to act on and the demo works only
until the first failover.

On a single-unit deployment there is nothing to sync, but the device group is still queried
rather than assumed: the group is the authority on whether the unit has a peer, `.env` is not.
A genuinely standalone unit answers with no group and the step reports that.

## Derived and undocumented overrides
These are read by the scripts but do not appear in `.env.example`. Most are derived and need
no attention; each can be overridden by exporting it or adding it to `.env`, because every
one is written with a `${VAR:-default}` fallback.

| Variable | Default | Meaning |
|---|---|---|
| `MFA_ORG` | `bigip-mgt-mfa` | `LDAP_ORGANISATION` for the bundled OpenLDAP container ([`docker-compose.yml`](../../docker-compose.yml)) |
| `MFA_REGEN_CA` | `0` | Set to `1` to mint a **new** demo CA instead of reusing the existing one. Invalidates every browser trust import and both BIG-IP anchors |
| `MFA_CA_CN` | `bigip-mgt-mfa Demo CA` | Subject CN of the generated CA |
| `MFA_LDAP_CA_NAME` | bundled `bigip-mgt-mfa-ca.crt`, external `bigip-mgt-mfa-dir-ca.crt` | Object name the directory CA is installed under on each BIG-IP |
| `MFA_FACADE_SNAT_ADDR` | host `.240` on `BIGIP_A_TMUI`'s subnet | Source address the façade's server-side connection is pinned to. Must not be the `node` target or a real host; never leaves the appliance, so it needs no route ([ADR 0007](../adr/0007-facade-source-address.md)) |

why they are derived from `MFA_LDAP_SCHEMA` rather than left to be set by hand.

## Where the values land
| Rendered artefact | Source template | Rendered by |
|---|---|---|
| `dns/Corefile` | [`dns/Corefile.tmpl`](../../dns/Corefile.tmpl) | `deploy.sh --stack`, via `envsubst` |
| Directory entries | [`ldap/seed.ldif`](../../ldap/seed.ldif), [`ldap/demo-users.ldif`](../../ldap/demo-users.ldif), [`ldap/acl-bigip-bind.ldif`](../../ldap/acl-bigip-bind.ldif) | `deploy.sh --stack` in bundled mode only |
| BIG-IP objects under `/Common`, prefix `bigip-mgt-mfa` | — | [`bigip/system-auth.sh`](../../bigip/system-auth.sh) and [`bigip/apm-build.sh`](../../bigip/apm-build.sh) |

All three rendered artefacts are gitignored and rewritten on every deploy; edit the
templates, never the output.

## Key BIG-IP object names
Partition `/Common`, prefix `bigip-mgt-mfa`. Useful when reading a `tmsh` transcript or the
output of [cli.md](cli.md)'s validator.

| Object | Name |
|---|---|
| Access profile and policy | `bigip-mgt-mfa` |
| Webtop virtual server | `bigip-mgt-mfa-vs` on `${MFA_APM_VIP}:443` |
| AAA LDAP server and its pool | `bigip-mgt-mfa-ldap-aaa`, `bigip-mgt-mfa-ldap-aaa-pool` |
| DNS resolver | `bigip-mgt-mfa-resolver` |
| Shadow façades | `bigip-mgt-mfa-shadow-a-vs` / `-b-vs`, with iRules `bigip-mgt-mfa-shadow-a-node` / `-b-node` |
| Portal Access resources | `bigip-mgt-mfa-bigip-a-tmui`, `bigip-mgt-mfa-bigip-b-tmui` |

The `-b-` objects exist only when `BIGIP_B_MGMT` is set. On a single-unit deployment they are
never created, and an earlier pair deployment's copies are deleted on the next build.
| Webtop and form SSO | `bigip-mgt-mfa-webtop`, `bigip-mgt-mfa-tmui-sso` |
| Remote-role rule | `bigip_mgt_mfa_admins` |

The mutable half of that list — the policy graph, its agents, the profile and the VIP — is
enumerated once in [`bigip/lib/objects.sh`](../../bigip/lib/objects.sh) and deleted from
that single list before every rebuild, so the build and any teardown cannot drift apart.

## One-time codes

### `MFA_TOTP_PERIOD`
Type: integer (seconds). Default: `60`. Required: no.

How long each one-time code is valid before it rolls. Rendered into the verification iRule at
upload time and into the enrolment QR, so the two can never disagree.

**Compatibility:** Google Authenticator ignores this value entirely and always produces
30-second codes. At any other setting it silently generates codes that never match. FreeOTP,
Aegis and 1Password honour it. Set `30` if Google Authenticator must be supported.

### `MFA_TOTP_SKEW`
Type: integer (steps). Default: `1`. Required: no.

How many steps either side of the current one are accepted, to absorb clock drift between the
phone and the appliance. It **multiplies** with the period: the window a code is accepted in
is

    period x (2 x skew + 1)

so the defaults accept a code for **three minutes**. `0` accepts only the current step and is
what a real deployment should run, provided NTP on the units is trustworthy. `deploy.sh`
prints the computed window on every build rather than leaving it to be worked out.

### `MFA_TOTP_MAX_FAILURES`
Type: integer. Default: `5`. Required: no.

How many consecutive wrong or replayed codes a user may submit before their second factor is
refused outright — however correct the next code is. RFC 6238 §5.2 requires a verifier to
throttle: a six-digit code is only an adequate secret while guessing is bounded. A successful
verification clears the counter; a malformed submission (not six digits) is denied but not
counted, so junk input cannot lock a user out. Each lockout and each counted failure is
logged to `local0` with the username and client IP.

### `MFA_TOTP_LOCKOUT_SECONDS`
Type: integer (seconds). Default: `300`. Required: no.

How long the refusal lasts once `MFA_TOTP_MAX_FAILURES` is reached, and also how long the
failure counter itself lives. Recovery is by waiting — the counter times out on the
appliance; there is nothing to reset by hand. (Restarting is not needed; if an operator must
clear one early, re-running `./deploy.sh --bigip` rebuilds the policy and starts the session
table fresh.)

### Codes are single-use

Independent of both keys above, a code that verifies successfully is remembered — keyed by
user and time step in the session table, for exactly the width of the acceptance window —
and a second presentation of it is denied and counted as a failure. This is the other
verifier obligation in RFC 6238 §5.2, and it is why re-running
`scripts/test-mfa-matrix.sh` twice within one code period shows the two GRANT cases denied
as replays on the second run: wait for the next period, or read it as the protection
demonstrating itself.

### Seed storage and the encryption key

Seeds are **AES-256-CBC encrypted before they are written into the BIG-IP data group**. Each
record in `bigip_mgt_mfa_totp_dg` has the form `v2:<iv-hex>:<ciphertext-base64>`, with a
fresh IV per record. A data group is ordinary configuration — it appears in `bigip.conf`, in
every UCS archive, in qkviews and on the config-sync wire — so a plaintext record would
publish every user's second factor to anyone able to read any of those. With encryption, all
of them see ciphertext, and a record that is not in the `v2` shape (including a legacy
plaintext one) is rejected as `bad-seed` rather than accepted.

The key is minted automatically into `certs/seed-key.hex` (gitignored, mode 600) on the
first `./deploy.sh --bigip` and rendered into the verification iRule at upload time; records
and iRule are rebuilt together on every run, so they cannot disagree. To rotate the key,
delete the file and re-deploy. Be honest about the boundary: a BIG-IP administrator who can
read both the data group and the iRule can still recover seeds — what the encryption changes
is the exposure surface (backups, qkviews, sync captures, config read access), not the trust
placed in the appliance itself. The plaintext enrolment record on this host,
`certs/totp-seeds.env`, remains the most sensitive file in the deployment and is the reason
`certs/` is gitignored.

## Demo principals and roles

The bundled directory seeds four principals whose *only* difference is group membership.
That single difference is what the demo makes visible: each lands in TMUI with a different
role, decided by the target BIG-IP rather than by the access policy.

| User | Group | TMOS role | Console |
|---|---|---|---|
| `alice.admin` | `bigip-admins` | Administrator | tmsh |
| `carol.netops` | `bigip-operators` | Operator | disabled |
| `dave.audit` | `bigip-auditors` | Auditor | disabled |
| `bob.user` | *(none)* | Guest — the default | disabled |

Only the administrator gets a shell. A console is a configuration channel whatever the GUI
role permits, so handing one to a read-only role would quietly undo the distinction.

### `MFA_PW_ALICE`, `MFA_PW_CAROL`, `MFA_PW_DAVE`, `MFA_PW_BOB`
Type: string. Default: falls back to `MFA_TEST_USER_PW`. Required: bundled mode only.

One password per demo principal. This matters more than it looks: with a shared password the
per-user attribution story rests on the honour system, because a directory cannot distinguish
two people who present the same credential. Distinct passwords are what make
`test-mfa-matrix.sh` able to assert that *alice's username with bob's password is denied* —
an assertion that cannot exist otherwise.

The fallback to `MFA_TEST_USER_PW` exists so an older `.env` keeps working; setting the
per-user values is strongly preferred.

Ignored entirely in external mode, where people already have their own directory passwords.

### `MFA_OPERATOR_GROUP_DN`, `MFA_AUDITOR_GROUP_DN`
Type: LDAP DN. Default: `cn=bigip-operators,ou=groups,${BASE_DN}` and
`cn=bigip-auditors,ou=groups,${BASE_DN}`. Required: no.

The groups whose members are granted the Operator and Auditor roles. Point them at existing
groups when using your own directory; the names need not match ours.

### `MFA_OPERATOR_ROLE_ATTRIBUTE`, `MFA_AUDITOR_ROLE_ATTRIBUTE`
Type: string. Default: `memberOf=<the corresponding group DN>`. Required: no.

The exact attribute comparison each `remote-role` rule performs. Override only if your
directory expresses membership differently — Active Directory nested groups, for instance,
may need a matching rule rather than a literal `memberOf`.

Rules are evaluated in `lineOrder`, most privileged first, so a user in two groups receives
the higher role rather than whichever rule happened to be evaluated last.
