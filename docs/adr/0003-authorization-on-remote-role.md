# 0003 — The target BIG-IP decides the role, not APM

## Status
Accepted.

## Context
Something has to decide whether a user who reaches TMUI is an administrator or a read-only
observer. APM is the obvious candidate: it already knows the identity, it can query group
membership, and it could branch the access policy to publish different resources.

That would be a lie, though — a convincing one. Publishing a different webtop tile does not
change what the user can do once they are inside TMUI. If the access tier were bypassed, or
if someone reached a management address directly, the appliance would apply whatever
authorization it was configured with, which in that design is nothing in particular.

## Decision
APM performs no authorization. Its LDAP step asks only "is this password correct for this
user"; the policy allows every authenticated identity through to the same webtop, with the
same two resources.

The role is decided by each BIG-IP, in its own configuration:

- `auth ldap system-auth` points at the directory with `check-roles-group enabled`.
- `auth remote-user` sets the default role to `guest` with console access disabled.
- One `remote-role` rule maps `memberOf=<admin group DN>` to `administrator`.

Both units are configured identically and explicitly, because `auth ldap` and `remote-role`
are device-local and are **not** carried by config-sync.

## Consequences
The demo's central claim survives inspection: alice is an administrator and bob is read-only
because of what the directory says, and that answer does not depend on how they arrived. Log
in through the webtop or straight at the management address — same result. The access tier
adds MFA and convenience, not authorization.

Two implementation details cost real debugging time and are recorded here so they are not
rediscovered:

- **`check-roles-group` must be enabled.** It is what makes TMOS consult the `remote-role`
  rules at all. With it disabled, the rules are silently ignored and *every* remote user —
  including members of the admin group — lands on the default role. The demo still appears to
  work, because everyone can still log in; only the elevation vanishes.
- **A read-only user cannot use iControl REST.** The Guest role has no REST permission, so a
  correctly-configured read-only user returns HTTP 401 to `curl`. Testing roles by HTTP
  status code therefore reports a working configuration as broken. The authoritative source
  is the `level=` field in the BIG-IP's own `/var/log/secure` audit line, which is what
  `scripts/validate.sh` asserts against.
