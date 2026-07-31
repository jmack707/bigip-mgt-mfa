# Configuration reference

Every setting that governs bigip-mgt-mfa: the `.env` keys you edit, the values
`scripts/lib/directory.sh` derives from them, and the handful of environment overrides the
scripts honour but `.env.example` does not list. Site-specific values use the angle-bracket
form, e.g. `<bigip-a-mgmt-ip>`.

_Last validated: 2026-07._

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
| `BIGIP_B_MGMT` | _(required)_ | Unit B's management address. Receives system authentication and the remote-role rule only |
| `BIGIP_A_TMUI` | _(required)_ | Unit A's **non-floating** internal self IP — the SSO target for its own TMUI |
| `BIGIP_B_TMUI` | _(required)_ | Unit B's non-floating internal self IP |

`BIGIP_PASS` is plaintext in `.env` for the demo. In production, inject it from a secret
manager instead: every script that touches a BIG-IP reads `BIGIP_PASS` from the environment
before sourcing `.env` and restores the injected value afterwards, so an exported value wins
over the file and the file can be left empty.

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
| `MFA_SHADOW_B` | `192.0.2.6` | Façade in front of unit B's TMUI |

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
`bigip/system-auth.sh` against both units. Skipping unit B leaves a unit that still
authenticates locally, so the synced role rule has nothing to act on and the demo works only
until the first failover.

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
