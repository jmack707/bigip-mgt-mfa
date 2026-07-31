# 0001 — APM collects the password itself

## Status
Accepted.

## Context
The requirement is multi-factor authentication in front of BIG-IP management, and single
sign-on from a webtop into the TMUI of each unit, with each user keeping their own identity
so the appliance's audit log names a person.

TMUI authenticates with a form: a username and a password. Nothing else. It speaks no SAML,
consumes no OIDC token, and has no way to trust an upstream assertion. Whatever fronts it
must therefore be able to produce **a password for that user** at the moment the session
opens a resource.

That single fact drives everything else.

## Decision
APM presents its own logon page and authenticates the password against the directory itself.
The password lands in `session.logon.last.password`, is copied to the SSO token by the SSO
Credential Mapping item, and is injected into TMUI's login form by a form-based SSO profile.

The second factor is collected on the same page and verified separately —
see [0002-verify-totp-on-the-bigip.md](0002-verify-totp-on-the-bigip.md).

## Alternatives considered

**Federate to an identity provider (SAML or OIDC).** The conventional answer, and the one a
customer's architecture team would expect. APM becomes a relying party, the IdP performs the
whole login including MFA, and the factors are bound by construction because there is only
one authentication event.

It was tried, and it fails on the requirement above: APM ends up holding an assertion that
proves *who* the user is, and an assertion cannot be typed into a login form. Every way out
of that reintroduces something this project exists to avoid:

- a vault brokering a per-session credential — a different, larger project;
  [Warden](https://github.com/jmack707/warden) already does exactly this
- a shared service account injected for everyone — which destroys the per-user attribution
  that is the whole point
- no SSO at all, publishing TMUI as a link the user logs into themselves — defensible, and
  genuinely how some customers run it, but not single sign-on

**Have the IdP do MFA and APM do the password.** This was built and then removed. It required
a password-less realm, asked the user for their username twice, and — because nothing
compared the token's subject to the user APM had authenticated — accepted anybody's second
factor. See [0002-verify-totp-on-the-bigip.md](0002-verify-totp-on-the-bigip.md).

## Consequences
The order is load-bearing and cannot be casually reversed. Anyone modernising this by putting
an identity provider in front will find SSO into TMUI stops working, and the fix is a vault.

What it buys: no vault, no PKI, no rotation, no credential broker. What it costs: this is not
a privileged-access design. The user's own password reaches the appliance, so it suits only
situations where those users are legitimately entitled to hold a credential that works there.
If the requirement is that operators never hold such a credential, this is the wrong tool.

A smaller consequence worth recording, because it cost real time: since the password must
survive into the SSO token, the logon page's password field is a **secure** session variable.
A plain `ACCESS::session data get` on one returns an empty string — the SSO Credential Mapping
uses `mcget -secure`. Anything else reading a password-type field from an iRule needs the
same, which is why the one-time-code field is deliberately a *text* field instead.
