# 0004 — Keycloak runs in development mode

## Status
Accepted, with the limitation stated openly.

## Context
Keycloak's production mode (`start`) requires an external database. Adding PostgreSQL to the
stack would mean another container, another credential, another volume, and another failure
mode between a user and a working demo — in exchange for durability guarantees that a demo
does not need.

The competing requirement is that this repository has to reproduce the same environment on
UDF, a home lab, and a laptop, from `docker compose up`. Every dependency added is a
dependency that can be missing or misconfigured in one of those places.

## Decision
Keycloak runs `start-dev --import-realm` against its embedded database, with the data
directory kept in the `kcdata` volume so enrolled TOTP secrets survive a restart. The realm
is imported declaratively at startup from a template rendered at deploy time.

`KC_HOSTNAME` is pinned to the full external URL rather than left to follow the request host,
because APM validates the token issuer against exactly that string. An issuer that floats
with the `Host` header produces a login that works in a browser and fails from the BIG-IP.

## Consequences
The identity side of the demo is one container with no external dependency, which is what
makes the "redeploy it anywhere" claim true.

The limitations, which the documentation states rather than hides:

- The embedded database is not supported for production use and is not intended to be
  durable under load. `docker compose down -v` destroys it, taking every enrolled
  authenticator with it — the reason
  [operations/runbooks/reset-user-mfa.md](../operations/runbooks/reset-user-mfa.md) exists.
- Development mode relaxes hostname strictness. Pinning `KC_HOSTNAME` removes the specific
  hazard that matters here, but the mode is still not a production posture.
- Anyone adapting this for real use should move to `start` with an external database, real
  certificates, and secrets from somewhere other than a `.env` file. That is a different
  system, and this ADR is the marker for where the line sits.
