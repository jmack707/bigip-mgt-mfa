# BIG-IP MGT MFA

Multi-factor authentication in front of BIG-IP management access, with single sign-on
through to the TMUI of every unit — and the user keeps their own identity the whole way.

One logon page takes a username, a password and a one-time code. The directory proves the
password, the BIG-IP verifies the code itself, and the webtop then signs the user into each
unit's Configuration Utility with **their own credential**. Whether they land as an
administrator or read-only is decided by the target BIG-IP from their directory group — not
by the access policy — so the answer is the same however they arrive.

No vault. No client certificates. No external MFA service.

```text
one page: username + password + one-time code
        |
        +-- LDAP Auth ......... the directory proves the password (and it stays in the session)
        +-- MFA (TOTP) ........ the BIG-IP computes the expected code and compares
        |
        v
      webtop  ->  form SSO  ->  BIG-IP A TMUI
                            ->  BIG-IP B TMUI
                                     |
                       remote-role: admin group -> Administrator, everyone else -> Guest
```

## What this is

A reusable, redeployable demo of MFA at the BIG-IP management edge: one logon page, a
second factor verified by the appliance itself, and single sign-on into the TMUI of every
unit with the user's own credential and their own role.

Everything is declared in this repository. `docker compose` brings up the directory side and
one idempotent script builds the access tier. There are no hardcoded addresses.

## Topology

```text
  user                    BIG-IP (APM)                 Docker host
  ----                    ------------                 -----------
  browser --------->  https://<webtop VIP>/
                             |
                             | one page: username + password + code
                             |-- bind ------------->  OpenLDAP / AD  :389
                             |-- TOTP verified locally (iRule + data group)
                             |
                             v
                          webtop
                             |-- form SSO --> BIG-IP A TMUI
                             +-- form SSO --> BIG-IP B TMUI
```

## Why it is shaped this way

The load-bearing decision is that **APM collects the password itself**. That is what leaves a
credential in the session to sign the user into TMUI, and it is why this needs no vault.

Federating to an identity provider — SAML, or OIDC — is the more fashionable answer and it
does not work here: the appliance receives an assertion, not a password, and an assertion
cannot be typed into TMUI's login form. That design needs a credential broker, which is a
different and larger project.

The second factor is verified **on the BIG-IP**, by an iRule implementing RFC 6238 against a
seed held in a data group. There is no MFA server to deploy and nothing to reach at login
time. An earlier revision used Keycloak and was removed: it asked for the username twice, it
needed a realm no customer would run, and — because nothing compared the token's subject to
the user APM had authenticated — it accepted *anybody's* second factor. The ADRs record that
in full, including the bypass.

## Components

| Component | Runs where | Responsibility |
|---|---|---|
| APM access policy | BIG-IP A, config-synced to B | Logon page, LDAP auth, TOTP verification, webtop, form SSO |
| TOTP verify iRule | BIG-IP | Computes the expected RFC 6238 code from the seed data group |
| OpenLDAP | Docker (`bundled` profile) | Demo directory. Absent in external mode |
| CoreDNS | Docker | Authoritative for the demo zone, forwards everything else |
| `auth ldap system-auth` + `auth source` | Each BIG-IP, device-local | Authenticates the SSO'd credential |
| `auth remote-role` | Built on A, config-synced | Decides Administrator vs Guest from group membership |

## What you need

- A BIG-IP with **LTM + APM** licensed. Two makes the failover story real; one is fine
  (`BIGIP_B_MGMT` is optional). Built and tested on **TMOS 21.1**.
- A Linux host with Docker and the `docker compose` v2 plugin, reachable from the BIG-IP.
- A directory. One ships in the stack for demos; point it at your own AD or LDAP instead by
  setting `MFA_DIRECTORY_MODE=external`.
- An authenticator app. **FreeOTP, Aegis or 1Password** — see the warning under
  [Enrolment](#enrolment).

## Quickstart

```bash
cp .env.example .env      # then edit: addresses, passwords, your directory
./deploy.sh --stack       # directory + DNS, in Docker. Touches no BIG-IP.
./scripts/enroll-totp.sh alice.admin bob.user
./deploy.sh --bigip       # trust anchors, system auth, the access policy, config-sync
./scripts/validate.sh     # asserts the result rather than assuming it
```

The two halves are deliberately separable: prove the Docker half works before pointing
anything at your appliances. Full detail in [docs/install.md](docs/install.md) and
[docs/deploy.md](docs/deploy.md).

## Enrolment

`scripts/enroll-totp.sh` mints a seed per user, prints a QR code and a typeable key, and
records the seed locally. **The seed does not reach the BIG-IP until you run
`./deploy.sh --bigip`** — enrolling and forgetting that step produces codes that are
rejected, which looks exactly like a broken authenticator.

> **Google Authenticator will not work unless the period is 30 seconds.** It ignores the
> `period` in the QR and always generates 30-second codes. The default here is 60
> (`MFA_TOTP_PERIOD`), so use FreeOTP, Aegis or 1Password — or set the period to 30.

Day-two operations — adding a user, replacing a lost phone, revoking a token — are in
[docs/operations/runbooks/set-up-mfa.md](docs/operations/runbooks/set-up-mfa.md).

## Verification

```bash
./scripts/validate.sh          # the deployment, end to end
./scripts/test-mfa-matrix.sh   # the accept/deny matrix
```

The matrix is the one that matters. It asserts the cases that must **fail**, including a
correct password paired with **another user's** code. That case is the reason the previous
design was thrown away, and it is not something a hand test thinks to try.

## Configuration

Everything environment-specific lives in `.env`; there are no hardcoded addresses anywhere in
the scripts. The keys worth knowing:

| Key | Default | Meaning |
|---|---|---|
| `MFA_DIRECTORY_MODE` | `bundled` | `bundled` ships a directory; `external` uses your AD/LDAP |
| `MFA_TOTP_PERIOD` | `60` | Seconds per code. 30 for Google Authenticator compatibility |
| `MFA_TOTP_SKEW` | `1` | Steps of tolerance either side. Multiplies with the period |
| `BIGIP_B_MGMT` | *(unset)* | Optional. Leave blank for a single BIG-IP |
| `MFA_ADMIN_ROLE_ATTRIBUTE` | — | The `memberOf` value that grants Administrator |

`MFA_TOTP_PERIOD` and `MFA_TOTP_SKEW` multiply: a code is accepted for
`period × (2 × skew + 1)` seconds, so the defaults give **three minutes**. Forgiving for a
demo, wider than a real deployment should run. The full reference is
[docs/reference/configuration.md](docs/reference/configuration.md).

## Documentation

- [docs/architecture.md](docs/architecture.md) — components, data flow, trust boundaries, non-goals
- [docs/adr/](docs/adr/) — the decisions that shaped this, and what each one cost
- [docs/operations/troubleshooting.md](docs/operations/troubleshooting.md) — every failure that actually happened here, indexed by symptom
- [docs/operations/runbooks/](docs/operations/runbooks/) — MFA enrolment, CA rotation, failover checks
- [docs/reference/](docs/reference/) — configuration keys and CLI

## Honest limitations

- **Run against one lab only.** Everything here is verified on a single Proxmox lab on TMOS
  21.1. It has never been deployed to UDF or to another TMOS version, and several things it
  depends on are version-sensitive.
- **The external AD path is untested.** Bundled mode is well exercised; pointing it at a real
  domain controller has not been.
- **The demo directory shares one password** across its users. Fine for a smoke test, not
  representative of anything.
- **Not a privileged-access design.** The user's own credential reaches TMUI. If the
  requirement is that operators never hold a credential that works on the appliance, that is
  a vault problem — see [Warden](https://github.com/jmack707/warden).
- **Seeds are credential-equivalent.** They live in a BIG-IP data group and in
  `certs/totp-seeds.env` (gitignored, mode 600). Anyone who can read either can mint codes.

## License

Apache-2.0. See [LICENSE](LICENSE).
