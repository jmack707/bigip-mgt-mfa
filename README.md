# warden-lite — MFA webtop SSO into a BIG-IP HA pair

A redeployable demo: a customer logs into a BIG-IP APM webtop with a password and a one-time
code, and lands in the management UI of both BIG-IPs in an HA pair — signed in as themselves,
with their own role.

## What this is
warden-lite is the short path to a story that usually takes a week of clicking to assemble:

- **APM** is the front door — logon page, directory authentication, webtop, and SSO.
- **Keycloak** is the second factor, and only the second factor.
- **AD or LDAP** is the single source of truth for who someone is and what they may do.
- **The BIG-IPs** decide the role themselves, from group membership.

Everything is declared in this repo. `docker compose` brings the identity side; one script
builds the access tier on the pair. It runs the same way on UDF, a Proxmox lab, or a laptop.

It is the smaller sibling of [Warden](https://github.com/jmack707/warden), which solves the
harder problem of privileged access with a vault and client certificates. warden-lite drops
both: no vault, no PKI enrolment, no rotating credentials. Users sign in as themselves.

## Topology
```text
  customer                    BIG-IP HA pair (APM)              Docker host
  ────────                    ────────────────────              ───────────
  browser ───────────────▶  https://<webtop VIP>/
                                   │
                                   │ 1. logon page: username + password
                                   ├── authenticate (bind) ──▶  OpenLDAP / AD  :389
                                   │
                                   │ 2. step up for the second factor
                                   ├── OIDC authorization code ─▶ Keycloak :8443
                                   │      (TOTP; federates the SAME directory, read-only)
                                   ▼
                              webtop (floats with traffic-group-1)
                               │            │
                    form SSO ──┘            └── form SSO
                         ▼                          ▼
                  BIG-IP A TMUI              BIG-IP B TMUI
                         └──────────┬───────────────┘
                                    ▼
                    each unit binds the injected credential to the
                    directory, then remote-role decides the role:
                      in cn=bigip-admins  ->  Administrator
                      everyone else       ->  Guest (read-only)
```

In one line: password proven against the directory, second factor proven by Keycloak, then
the user's *own* credential single-signed-on into both management UIs — where the BIG-IP,
not the access tier, decides what they can do.

## Why the order matters
APM checks the password **before** it redirects to Keycloak. That is the whole design.

Because APM performs the first factor itself, the password is in the session and can be
single-signed-on to TMUI. A conventional OIDC front door — where Keycloak owns the entire
login and APM is a plain relying party — never sees a password, so it has nothing to sign in
with and needs a vault or a shared admin account to bridge the gap. That is precisely the
problem [Warden](https://github.com/jmack707/warden) exists to solve. warden-lite avoids it
by reordering the factors.

The cost is that Keycloak is configured as a second-factor oracle rather than a general
identity provider. See [docs/adr/0002-second-factor-only-realm.md](docs/adr/0002-second-factor-only-realm.md).

## Components
| Component | Runs where | Job |
|---|---|---|
| APM access policy | BIG-IP unit A, synced to B | Logon page, LDAP auth, OIDC step-up, webtop, form SSO |
| Keycloak | Docker | The second factor (TOTP), federating the directory read-only |
| OpenLDAP | Docker (bundled mode) | Demo directory; replaced by your AD or LDAP in external mode |
| CoreDNS | Docker | Resolves the demo names for the BIG-IP, which cannot use a hosts file |
| remote-role | Both BIG-IPs | Turns group membership into Administrator or Guest |

## Quickstart
You bring a licensed BIG-IP HA pair with LTM and APM provisioned, and a Linux host with
Docker that the BIG-IPs can reach.

```bash
cp .env.example .env      # fill in WL_HOST_IP, the BIG-IP addresses, WL_APM_VIP, passwords
./deploy.sh --stack       # Keycloak + directory + DNS. Touches no BIG-IP — prove it first.
./deploy.sh --bigip       # trust anchors, remote-role on both units, APM policy on the pair
./scripts/validate.sh     # 26 assertions, end to end
```

Then browse to `https://<WL_WEBTOP_FQDN>/` and sign in as `alice.admin`. On first login
Keycloak walks you through enrolling an authenticator app. Sign in again as `bob.user` to see
the same webtop resolve to a read-only TMUI.

Full detail in [docs/install.md](docs/install.md) and [docs/deploy.md](docs/deploy.md).

## Verification
`scripts/validate.sh` asserts the containers, the demo DNS zone, the directory (including
that alice is in the admin group and bob is not), Keycloak's issuer, the APM objects on both
units, the role each demo user actually receives, and that the VIP answers. It exits with the
number of failed checks.

```bash
./scripts/validate.sh
./scripts/demo-login.sh alice.admin    # walks the ENTIRE login chain headlessly, TOTP included
```

`demo-login.sh` is the honest check: it drives the logon page, the LDAP bind, the Keycloak
one-time code, and the return to the webtop, then confirms both BIG-IP resources are on the
session. It needs `oathtool`.

## Bring your own directory
Set `WL_DIRECTORY_MODE=external` and point warden-lite at your AD, FreeIPA, or LDAP. It
creates nothing and writes nothing: APM binds to check a password, the BIG-IPs read
`memberOf`, and Keycloak federates read-only. See [docs/directory.md](docs/directory.md).

## Documentation
- [docs/architecture.md](docs/architecture.md) — the design, the trust boundaries, and what this is not
- [docs/install.md](docs/install.md) · [docs/deploy.md](docs/deploy.md) · [docs/upgrade.md](docs/upgrade.md)
- [docs/directory.md](docs/directory.md) — bundled vs AD/LDAP
- [docs/operations/troubleshooting.md](docs/operations/troubleshooting.md) — symptom index
- [docs/reference/configuration.md](docs/reference/configuration.md) · [docs/reference/cli.md](docs/reference/cli.md) · [docs/reference/api.md](docs/reference/api.md)
- [docs/adr/](docs/adr/) — why the factors are in this order, and the rest of the decisions

## License
Apache-2.0. See [LICENSE](LICENSE).
