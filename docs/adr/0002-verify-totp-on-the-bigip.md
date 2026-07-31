# 0002 — Verify the one-time code on the BIG-IP

## Status
Accepted. Supersedes an earlier design that used Keycloak as the second factor.

## Context
[0001](0001-apm-collects-the-password.md) fixes the first factor: APM collects and proves the
password. Something still has to verify a second factor, and it has to bind that factor to
the *same* identity — otherwise it is not multi-factor authentication in any meaningful
sense.

The obvious move is to reach out to an MFA service. That turned out to be the wrong instinct
for an appliance, and the reasons are worth recording because they are not obvious until you
have spent a day on them.

## Decision
The BIG-IP verifies the code itself. `bigip/apm-totp-verify.irule` implements RFC 6238 —
base32-decode the seed, HMAC-SHA1 over the time step, dynamic truncation — against a seed
held in the `bigip_mgt_mfa_totp_dg` data group. The logon page collects username, password
and code together; the LDAP Auth item proves the password and the iRule proves the code, both
against the same submitted username.

Seeds live in a data group rather than a directory attribute. The directory owns identity;
the verifier owns token secrets. That is the split a real MFA product makes, and it keeps a
credential-equivalent secret off the user's directory entry where anything able to read the
entry could mint valid codes.

`MFA_TOTP_PERIOD` and `MFA_TOTP_SKEW` are rendered into the rule at upload time.

## Why not Keycloak

Keycloak was built, worked, and was removed. It is an identity provider for browser
applications, not an MFA service for appliances: it has no RADIUS interface and no API to
verify a one-time code on its own. Every integration path is therefore bespoke.

**The OIDC redirect design had a real bypass.** APM authenticated the password, redirected to
Keycloak for the code, and accepted the result — but nothing compared the returned token's
subject to the user APM had authenticated. Verified on a live pair: signing in as
`alice.admin` with her password, then completing the second factor as `bob.user` with *bob's*
authenticator, produced **alice's** webtop with Administrator rights. A valid password plus
anybody's enrolled phone was sufficient. It also asked for the username twice and required a
password-less realm that no customer would run.

**The direct-grant design worked but did not survive contact.** Posting username, password
and code to Keycloak's token endpoint in one call is correct and binds the factors properly —
Keycloak rejects alice's password with bob's code. But APM's HTTP AAA agent refuses an
`https://` backend outright, and the iRule sideband replacement hung mid-policy on a
`connect` that never returned, taking the whole access policy down with it.

Local computation has neither problem. There is no service to be unreachable, no sideband to
hang, and no second identity to compare.

## Consequences

**The factors are bound by construction.** The same username from the same form submission
selects the seed and was bound to the password a moment earlier. There is no way to pair one
user's password with another's token; the matrix test asserts exactly this.

**Enrolment is ours to provide.** There is no self-service portal — `scripts/enroll-totp.sh`
mints seeds and prints QR codes, and `./deploy.sh --bigip` is what actually pushes them to
the appliance. Those being two steps is a genuine usability wart: enrolling and forgetting to
deploy produces rejected codes that look exactly like a broken authenticator.

**Clock accuracy matters.** The window a code is accepted in is `period × (2 × skew + 1)`.
With the defaults that is three minutes, which is forgiving for a demo and wider than a real
deployment should run. Drift beyond the window rejects every code for everyone at once while
nothing else on the appliance misbehaves — an unusually confusing symptom, so NTP is the
first thing to check.

**No official precedent.** F5's own access-solution collections do not do this; their
reference material is single-factor. The iRule has nothing upstream to check it against,
which is an argument for keeping the matrix test honest.

**A longer period is not universally supported.** Google Authenticator ignores the `period`
in an enrolment URI and always produces 30-second codes. At any other period it silently
produces codes that never match. FreeOTP, Aegis and 1Password honour it.
