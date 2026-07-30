# Architecture

## Context
warden-lite exists to make one story reproducible: a customer signs into a BIG-IP APM webtop
with a password and a one-time code, and reaches the management UI of two BIG-IPs as
themselves, with a role the BIG-IPs derive from their directory group.

Assembled by hand that is a day of clicking across APM, a directory, an MFA provider, and
two units — and it is never quite the same twice. Here it is a repository: `docker compose`
for the identity side, one idempotent script for the access tier, and a validation script
that asserts the result rather than assuming it.

The demo is deliberately smaller than [Warden](https://github.com/jmack707/warden). Warden
answers "how do I grant privileged access without handing out a standing credential", and
pays for that answer with a vault, a PKI, and credential rotation. warden-lite answers the
much more common "how do I put MFA in front of BIG-IP management and keep per-user
attribution", and pays almost nothing.

## Components
| Component | Runs where | Responsibility |
|---|---|---|
| APM access policy `warden-lite` | BIG-IP A, config-synced to B | Logon page, LDAP authentication, OIDC step-up, webtop, form SSO into both TMUIs |
| Keycloak 26 | Docker | The second factor only. Federates the directory read-only; never a password store |
| OpenLDAP | Docker, `bundled` profile | Demo directory and the two demo principals. Absent in external mode |
| CoreDNS | Docker | Authoritative for the demo zone; forwards everything else |
| `auth ldap system-auth` + `remote-role` | Each BIG-IP, device-local | Authenticates the SSO'd credential and decides Administrator vs Guest |
| Shadow façade virtuals | BIG-IP | Non-routable stand-ins that let portal access reach each unit's TMUI |

## Data flow
1. The browser reaches the webtop VIP. APM starts a session and serves the logon page.
2. APM binds the submitted credential to the directory (`aaa-ldap`, type `auth`). A failure
   ends the policy at Deny; the browser is never redirected onward. The password is now in
   the session.
3. APM redirects to Keycloak as an OIDC client (authorization code with PKCE). Keycloak
   establishes which identity is being stepped up and demands a TOTP code.
4. Keycloak redirects back with a code; APM exchanges it over the back channel, validating
   Keycloak's certificate against the demo CA. Any error ends the policy at Deny — a failed
   second factor must not degrade to first-factor-only access.
5. SSO Credential Mapping copies `session.logon.last.username` and `.password` into the SSO
   token. Resource Assign publishes the webtop and one portal resource per unit.
6. Selecting a resource makes APM open that unit's TMUI through its façade and submit the
   login form with the user's own credential.
7. The target unit binds that credential to the directory and applies `remote-role`:
   membership of the admin group yields Administrator, everything else falls through to the
   Guest default.

The credential that reaches TMUI is the user's own. There is no shared account, no vault,
and nothing to rotate.

## Trust boundaries
- **The browser trusts the demo CA.** warden-lite issues its own CA and the certificates for
  the webtop VIP and Keycloak. Until that CA is imported, browsers warn. The VIP certificate
  matters more than it looks: its name is the OIDC `redirect_uri` origin.
- **The BIG-IP trusts the same CA** for the OAuth back channel and for LDAPS.
- **Keycloak never writes to the directory.** Federation is `READ_ONLY`, which is what makes
  it safe to point at a customer's real AD.
- **The directory is authoritative for authorization, and the BIG-IP evaluates it.** APM does
  not decide the role, and cannot: even if the access tier were bypassed entirely, a user
  logging directly into TMUI gets the same role. See
  [adr/0003-authorization-on-remote-role.md](adr/0003-authorization-on-remote-role.md).
- **Keycloak is a second-factor oracle, not a general IdP.** Its browser flow asks for a
  username and a one-time code, deliberately not a password, because APM has already proven
  the password. Anything else pointed at this realm would be authenticated by OTP alone. See
  [adr/0002-second-factor-only-realm.md](adr/0002-second-factor-only-realm.md).
- **`admin` and `root` stay local on TMOS.** Switching the auth source to LDAP cannot lock
  anyone out of the box.

## Constraints and non-goals
- **Not a production access-management design.** Keycloak runs in development mode against an
  embedded database ([adr/0004-keycloak-dev-mode.md](adr/0004-keycloak-dev-mode.md)), secrets
  live in a `.env` file, and the CA is self-signed. It is a demo, and it says so.
- **No privileged-access story.** The user's own credential is what reaches TMUI. If the
  requirement is that operators never hold a credential that works on the appliance at all,
  that is Warden's problem, not this one.
- **TOTP only.** WebAuthn needs a real hostname and publicly trusted TLS, which is friction
  in exactly the environments this demo has to run in.
- **The BIG-IP needs real DNS.** A TMOS `dns-resolver` performs its own lookups in TMM and
  does not read the appliance's hosts file, so a hosts-file workaround can cover the browser
  but never the BIG-IP. warden-lite therefore ships CoreDNS rather than depending on a DNS
  server you may not be permitted to edit.
- **APM refuses "reserved" portal targets.** Self-IPs, the management address, and cluster
  addresses are rejected outright, and publishing TMUI on a routable self-IP would be a hole
  regardless. Each unit's TMUI is fronted by an RFC 5737 façade address instead, steered to
  the real last hop by an iRule.
- **Some BIG-IP configuration is device-local.** `auth ldap` and `remote-role` are not
  carried by config-sync, so both units are configured explicitly. Skipping the peer produces
  a demo that works until the first failover and then quietly makes everyone read-only.

## Decisions
- [adr/0001-apm-first-auth-order.md](adr/0001-apm-first-auth-order.md) — APM proves the password before stepping up to Keycloak
- [adr/0002-second-factor-only-realm.md](adr/0002-second-factor-only-realm.md) — the Keycloak realm asks for a username and OTP, not a password
- [adr/0003-authorization-on-remote-role.md](adr/0003-authorization-on-remote-role.md) — the target BIG-IP decides the role, not APM
- [adr/0004-keycloak-dev-mode.md](adr/0004-keycloak-dev-mode.md) — Keycloak runs in development mode so the demo stays self-contained
- [adr/0005-bundled-directory-default.md](adr/0005-bundled-directory-default.md) — a bundled directory by default, AD and LDAP as configuration
