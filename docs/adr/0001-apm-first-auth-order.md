# 0001 — APM proves the password before stepping up to Keycloak

## Status
Accepted.

## Context
The demo has to deliver two things at once: multi-factor authentication in front of BIG-IP
management, and single sign-on from the resulting webtop into two management UIs. Those two
requirements pull in opposite directions.

The obvious modern design makes APM a plain OIDC relying party: Keycloak owns the whole
login, federates the directory, prompts for password and OTP, and hands APM an identity
token. It is clean, it is what most people expect, and it has one consequence that breaks the
second requirement — APM never sees a password. Having no credential, it cannot sign the user
into TMUI. The gap then has to be filled with a shared administrator account stored in APM
(which destroys per-user attribution on the appliance) or with a vault that mints a credential
per session (which is a substantially larger system, and is what
[Warden](https://github.com/jmack707/warden) is).

## Decision
APM performs the first factor itself. The access policy is:

```text
Start -> Logon Page -> LDAP Auth -> OAuth Client (Keycloak) -> SSO Credential Mapping
      -> Resource Assign -> Allow
```

APM collects the username and password on its own logon page and binds them against the
directory. Only after that succeeds does it redirect to Keycloak, which supplies the second
factor and nothing else. The password is then in the session as
`session.logon.last.password`, and SSO Credential Mapping hands it to the portal resources.

Failure at either factor ends the policy at Deny. The OIDC branch in particular treats
anything other than a clean token exchange as a denial, so a failed second factor cannot
degrade into first-factor-only access.

## Consequences
The user's own credential is what reaches TMUI, so the target BIG-IP can authenticate and
authorize them individually. There is no shared account and no vault, which is what makes the
whole demo fit in one repository and deploy in minutes.

The costs are real and worth stating plainly:

- **Keycloak cannot be a general identity provider in this configuration.** Since APM already
  proved the password, prompting for it again would be a second password box for no added
  assurance — so the realm's browser flow asks for a username and an OTP only. That realm
  must therefore not be pointed at any other application. See
  [0002-second-factor-only-realm.md](0002-second-factor-only-realm.md).
- **The user types their username twice** — once on the APM logon page, once on Keycloak's
  form. Accepted as the cost of not prompting for the password twice.
- **APM handles the password.** In the OIDC-first design it never would. This is the honest
  trade: SSO into a legacy form-login UI requires a credential, and something has to hold it.
