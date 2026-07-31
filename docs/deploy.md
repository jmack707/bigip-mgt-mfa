# Deploy

_Last validated: 2026-07_

The BIG-IP half: trust anchors, per-unit system authentication, the access policy, the TOTP
seeds, and a config-sync to the peer. The Docker half is [install.md](install.md) and should
be working first.

```bash
./deploy.sh --bigip
```

## Scope

Three things happen, and they are not equivalent:

- **`bigip/system-auth.sh`, on every configured unit.** `auth ldap system-auth` and
  `auth source` are device-local: a config-sync does **not** carry them to the peer.
  (`auth remote-role` *is* synced, but a role rule is inert on a unit that has no directory
  configured and is still authenticating locally, so running this once is not enough.) This
  is the half that decides alice is an Administrator and bob is read-only — and the target
  BIG-IP decides it, not APM
  ([adr/0003-authorization-on-remote-role.md](adr/0003-authorization-on-remote-role.md)).
- **`bigip/apm-build.sh`, on unit A only.** The access tier: the VIP certificate, the AAA
  LDAP server, the TOTP seed data group and verification iRule, the logon page, the policy
  graph, the webtop, the façade virtuals and one portal resource per unit.
- **A config-sync**, which carries the access tier to the peer.

`BIGIP_B_MGMT` is optional. Leave it unset for a single BIG-IP and everything runs once; the
sync step reports that there is nothing to sync.

## Prerequisites

- `BIGIP_A_MGMT`, `BIGIP_USER`, `BIGIP_PASS` set. `BIGIP_PASS` may be exported instead of
  stored in `.env`; an exported value wins.
- LTM and APM provisioned and licensed on each unit.
- The BIG-IP can reach `MFA_HOST_IP` on the directory ports.
- At least one user enrolled (`scripts/enroll-totp.sh`), or nobody can log in — an absent
  seed is treated as a denial, never as a skipped factor.

## Procedure

Run `./deploy.sh --bigip`. To drive a single step by hand:

```bash
BIGIP_MGMT=<unit> bigip/system-auth.sh    # one unit's system authentication
BIGIP_MGMT=<unit-A> bigip/apm-build.sh    # the access tier
```

The build prints the acceptance window it computed — for example
`TOTP step 60s, skew +/-1 => a code is accepted for 180s` — so the effect of
`MFA_TOTP_PERIOD` and `MFA_TOTP_SKEW` is visible rather than implied.

## Idempotency

Re-running is safe, but "safe" is doing real work here:

- The CA is reused unless `MFA_REGEN_CA=1`. Leaf certificates are re-issued only when missing
  or no longer valid under the current CA.
- **Objects that will not update are deleted and recreated.** `tmsh create` is not
  idempotent: it keeps the existing object and reports success. That applies to `apm aaa ldap`
  — where a stale bind DN once survived a domain change and failed every login while naming a
  DN that appeared in no config file — and to the mutable policy graph.
- Additive creates tolerate `409`.
- Transient REST failures (`401`, `5xx`, empty responses) are retried with a backoff rather
  than treated as fatal. This matters because the build tears the policy down before
  rebuilding it, so an unretried hiccup used to leave the demo deleted rather than unchanged.
- `caption` on a portal resource is **not** settable and the create stays `409`-tolerant, so
  a caption set by hand in the GUI survives redeploys.

## Verification

```bash
./scripts/validate.sh          # the deployment end to end
./scripts/test-mfa-matrix.sh   # the accept/deny matrix
```

`validate.sh` probes each unit's management plane first. If iControl REST is not answering it
**skips** the configuration checks rather than reporting them as failures — an unreachable
restjavad and a missing object are indistinguishable over REST, and conflating them sends you
hunting through configuration that was never broken. The data plane is independent: TMM keeps
serving the webtop while restjavad is down, so check the VIP before concluding the demo is
down.

## Rollback

```bash
./teardown.sh --bigip
```

Restores `auth source` to `local` on every configured unit and removes the access tier. The
inert `auth ldap system-auth` object is left in place deliberately.

To disable the front door without removing anything:

```bash
tmsh modify ltm virtual bigip-mgt-mfa-vs disabled
```
