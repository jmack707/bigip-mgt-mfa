# 0005 — A bundled directory by default, AD and LDAP as configuration

## Status
Accepted.

## Context
The demo must support Active Directory or LDAP, because that is what customers have. It must
also stand up with nothing but a Docker host, because that is what makes it redeployable to
UDF, a personal lab, or a laptop. Those are different requirements and it is tempting to pick
one.

Pointing the default configuration at a real directory would mean every deployment starts
with a directory conversation — a bind account, a search base, a CA export, a firewall rule —
before anything can be demonstrated at all.

## Decision
warden-lite ships an OpenLDAP container and seeds it with two principals whose only
difference is membership of the admin group. That is the default (`WL_DIRECTORY_MODE=bundled`)
and it requires no external anything.

`WL_DIRECTORY_MODE=external` switches every consumer to a directory you supply. The OpenLDAP
container does not start, and warden-lite creates nothing and writes nothing: APM binds to
check a password, the BIG-IPs read `memberOf`, and Keycloak federates `READ_ONLY`. Those three
read-only interactions are the entire contact surface.

Crucially, the authorization expression is the same in both modes:
`memberOf=<admin group DN>`. The bundled directory is not a special case with its own
mechanism — it is the same design running against a directory that happens to be in the
compose file.

## Consequences
A newcomer gets a working demo in one command, and a customer engagement changes
configuration rather than architecture. Because the bundled path exercises the same
`memberOf` mapping the AD path uses, what is demonstrated locally is what will happen against
a real directory.

Two consequences worth knowing:

- **The `memberof` overlay must be applied before the group is created.** OpenLDAP computes
  `memberOf` only for changes made after the overlay is active, so seeding in the wrong order
  produces a directory where nobody is an administrator and nothing appears to be wrong.
  `deploy.sh` enforces the order and `scripts/validate.sh` asserts the result.
- **Schema differences are configuration, not code.** Active Directory logs in as
  `sAMAccountName` rather than `uid` and needs a different Keycloak federation vendor and UUID
  attribute. `scripts/lib/directory.sh` derives all of these from `WL_LDAP_SCHEMA`, so the
  difference stays in one place. See [../directory.md](../directory.md).
