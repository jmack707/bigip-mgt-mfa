# 0002 — The Keycloak realm asks for a username and an OTP, not a password

## Status
Accepted.

## Context
By the time APM redirects to Keycloak it has already bound the user's password against the
directory ([0001-apm-first-auth-order.md](0001-apm-first-auth-order.md)). Keycloak's stock
browser flow begins with a username-and-password form, so leaving it alone would ask the user
for the same password a second time, verified against the same directory, adding no
assurance and a great deal of irritation.

## Decision
The realm ships a custom top-level browser flow, `bigip-mgt-mfa second factor`, with exactly
two executions, both REQUIRED:

1. `auth-username-form` — establishes which identity is being stepped up.
2. `auth-otp-form` — the actual second factor.

`CONFIGURE_TOTP` is a default required action, so a user with no authenticator enrols on
first login. The cookie authenticator is deliberately absent from the flow, so every redirect
re-runs the one-time code rather than silently reusing a Keycloak SSO session — which keeps
the demo deterministic and makes the MFA step visible every time.

Federation of the directory is `READ_ONLY`, so Keycloak resolves the same identities APM
authenticates but can never write to them. That is what makes it safe to point at a
customer's real Active Directory.

## Consequences
The login is a genuine step-up: one password prompt, one code prompt, no redundancy.

The security consequence must be stated clearly, because it is not obvious from the Keycloak
console: **this realm authenticates with a username and an OTP alone.** That is sound as the
second half of a two-factor sequence whose first half APM has already enforced. It is not
sound in isolation. Anyone who registered another OIDC client against this realm would obtain
a login that never checks a password.

Therefore:

- Do not point other applications at this realm.
- Treat the realm as an appliance-scoped component of the access tier, not as shared
  identity infrastructure.
- If this pattern is ever taken beyond a demo, restrict the client and consider enforcing at
  the Keycloak end that the request originated from the APM client.
