# Architecture

## Context
BIG-IP MGT MFA exists to make one story reproducible: an operator signs in once with a
password and a one-time code, and reaches the management UI of every BIG-IP as themselves,
with a role the appliances derive from their directory group.

Assembled by hand that is a day of clicking across APM, a directory and two units — and it is
never quite the same twice. Here it is a repository: `docker compose` for the directory side,
one idempotent script for the access tier, and a validation script that asserts the result
rather than assuming it.

The demo is deliberately smaller than [Warden](https://github.com/jmack707/warden). Warden
answers "how do I grant privileged access without handing out a standing credential", and
pays for that answer with a vault, a PKI and credential rotation. This answers the much more
common "how do I put MFA in front of BIG-IP management and keep per-user attribution", and
pays almost nothing.

## Components
| Component | Runs where | Responsibility |
|---|---|---|
| APM access policy `bigip-mgt-mfa` | BIG-IP A, config-synced to B | Logon page, LDAP authentication, TOTP verification, webtop, form SSO into each TMUI |
| `bigip-mgt-mfa-totp-verify` iRule | BIG-IP, on the webtop virtual | Computes the expected RFC 6238 code and compares it to what was typed |
| `bigip_mgt_mfa_totp_dg` data group | BIG-IP, config-synced | One base32 seed per enrolled user |
| OpenLDAP | Docker, `bundled` profile | Demo directory and its principals. Absent in external mode |
| CoreDNS | Docker | Authoritative for the demo zone; forwards everything else |
| `auth ldap system-auth` + `auth source` | Each BIG-IP, device-local (not synced) | Authenticates the SSO'd credential against the directory |
| `auth remote-role` | Built on A, config-synced to B | Decides Administrator vs Guest from group membership |
| Shadow façade virtuals | BIG-IP | Non-routable stand-ins that let portal access reach each unit's TMUI |

## Data flow
1. The browser reaches the webtop VIP. APM starts a session and serves a single logon page
   with three fields: username, password, one-time code.
2. APM binds the submitted credential to the directory (`aaa-ldap`, type `auth`). A failure
   ends the policy at Deny. The password is now in the session.
3. The TOTP iRule fires. It looks up that username's seed in the data group, computes the
   expected code for the current time step (and the configured tolerance either side), and
   compares. No network call leaves the appliance.
4. Anything other than a match ends the policy at Deny — a failed second factor must never
   degrade to first-factor-only access.
5. SSO Credential Mapping copies `session.logon.last.username` and `.password` into the SSO
   token. Resource Assign publishes the webtop and one portal resource per unit.
6. Selecting a resource makes APM open that unit's TMUI through its façade and submit the
   login form with the user's own credential.
7. The target unit binds that credential to the directory and applies `remote-role`:
   membership of the admin group yields Administrator, everything else falls through to the
   Guest default.

Both factors are bound to one identity by construction: the same username from the same form
submission selects the seed and was bound to the password a moment earlier. There is no way
to pair one user's password with another user's token.

## Trust boundaries
- **The browser trusts the demo CA.** The stack issues its own CA and the certificate for the
  webtop VIP. Until that CA is imported, browsers warn.
- **The BIG-IP trusts the same CA** for LDAPS to the bundled directory.
- **The directory is authoritative for authorization, and the BIG-IP evaluates it.** APM does
  not decide the role and cannot: a user logging directly into TMUI gets the same answer. See
  [adr/0003-authorization-on-remote-role.md](adr/0003-authorization-on-remote-role.md).
- **Seeds are credential-equivalent.** They live in a BIG-IP data group and in
  `certs/totp-seeds.env` (mode 600, gitignored). Anyone who can read either can mint valid
  codes for that user. They are deliberately *not* stored on the directory entry, where
  anything able to read the entry could do the same.
- **`admin` and `root` stay local on TMOS.** Switching the auth source to LDAP cannot lock
  anyone out of the box.

## Constraints and non-goals
- **Not a production access-management design.** Secrets live in a `.env` file and the CA is
  self-signed. It is a demo, and it says so.
- **No privileged-access story.** The user's own credential reaches TMUI. If the requirement
  is that operators never hold a credential that works on the appliance at all, that is
  Warden's problem, not this one. See
  [adr/0001-apm-collects-the-password.md](adr/0001-apm-collects-the-password.md).
- **TOTP only.** No push, no WebAuthn, no device management. There is no MFA server here to
  provide them.
- **Enrolment is a script, not a portal.** `scripts/enroll-totp.sh` issues seeds and prints
  QR codes; `./deploy.sh --bigip` pushes them to the appliance. Those being two steps is a
  real usability wart — enrolling and forgetting to deploy produces codes that are rejected,
  which looks exactly like a broken authenticator.
- **Clock accuracy is load-bearing.** The acceptance window is `period × (2 × skew + 1)`.
  Drift beyond it rejects every code for everyone at once while nothing else on the appliance
  misbehaves.
- **The BIG-IP needs real DNS.** A TMOS `dns-resolver` performs its own lookups in TMM and
  does not read the appliance's hosts file, so a hosts-file workaround can cover the browser
  but never the BIG-IP. CoreDNS therefore ships in the stack.
- **APM refuses "reserved" portal targets.** Self-IPs, the management address and cluster
  addresses are rejected outright, and publishing TMUI on a routable self-IP would be a hole
  regardless. Each unit's TMUI is fronted by an RFC 5737 façade address instead, steered to
  the real last hop by an iRule.
- **Some BIG-IP configuration is device-local.** `auth ldap system-auth` and `auth source`
  are not carried by config-sync, so every configured unit is set up explicitly.
  `auth remote-role` *is* synced, but a role rule is inert on a unit that has no directory
  configured and is still authenticating locally.
- **The second BIG-IP is optional.** One unit is a complete deployment; the pair exists to
  make the failover story demonstrable, not to make the design work. Everything per-unit —
  the `system-auth` pass, the façade virtual, the portal resource and its webtop tile, and
  the validator's expected counts — iterates what `.env` declares, so the single-unit path is
  the same code path with one address fewer.

## Decisions
- [adr/0001-apm-collects-the-password.md](adr/0001-apm-collects-the-password.md) — APM collects the password itself, which is why no vault is needed
- [adr/0002-verify-totp-on-the-bigip.md](adr/0002-verify-totp-on-the-bigip.md) — the appliance verifies the one-time code, and why Keycloak was removed
- [adr/0003-authorization-on-remote-role.md](adr/0003-authorization-on-remote-role.md) — the target BIG-IP decides the role, not APM
- [adr/0005-bundled-directory-default.md](adr/0005-bundled-directory-default.md) — a bundled directory by default, AD and LDAP as configuration
