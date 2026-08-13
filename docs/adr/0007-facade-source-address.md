# 0007 — Pin the façade's source address with a SNAT pool

## Status
Accepted. Extends the façade design recorded in
[configuration.md](../reference/configuration.md); records why the shadow virtual's source
address is chosen explicitly rather than left to SNAT `automap`.

## Context
Each unit's TMUI is published through a non-routable RFC 5737 façade — a plain LTM virtual on
`192.0.2.5`/`.6` whose one-line iRule makes the last hop with `node <self-ip> 443` — because
APM Portal Access refuses "reserved" targets outright. The façade was built with
`sourceAddressTranslation: automap` from the first revision, and that worked for a year of
demos on an HA pair.

It does not work on a single BIG-IP, and the way it fails is the problem.

SNAT automap picks a self IP on the egress VLAN. On a pair there are two — the unit's
non-floating self IP and a floating one — and automap prefers the floating address, which is
not the `node` target. On a single unit there is exactly one address on that VLAN and it *is*
the `node` target, so the server-side connection has its source equal to its destination. TMM
never completes it.

Nothing reports this. The tile completes its TLS handshake with the façade, the ClientHello is
delivered and acknowledged, and then there is silence until the client resets ten seconds
later — `PR_CONNECT_RESET_ERROR` in the browser. Every configured object is correct: the
portal resource, its form SSO, the `headers`, the façade virtual, the iRule, the `node` target,
the self IP's `allow-service`, and the `tmm.tcl.rule.node.allow_loopback_addresses` db key.
`scripts/validate.sh` passed such a deployment twice.

It was diagnosed by reproducing it deliberately on a working pair: pinning the façade's SNAT
source *to* the node target with a one-member SNAT pool turned a `200 in 0.07s` into `000 in
4.0s`, three runs in a row, and reverting restored it.

## Decision
**The façade's source address is pinned with a dedicated SNAT pool**
(`bigip-mgt-mfa-facade-snat`), holding one address that is never the `node` target. The
address defaults to host `.240` on the same subnet as `BIGIP_A_TMUI` and is overridable with
`MFA_FACADE_SNAT_ADDR`. `bigip/apm-build.sh` creates the pool and points every façade virtual
at it, PATCHing both the pool member and the virtual's translation on every run so an existing
deployment converges instead of keeping a translation that cannot work.

This is **one configuration for both deployment shapes**. An earlier revision of this change
branched on unit count — `automap` with a peer, `none` without — and that branching was wrong,
which is the substance of what follows.

Three alternatives were rejected, two of them only after being tried:

**`automap`** is what the original build used. It works on a pair by accident: a floating self
IP exists and automap happens to prefer it. Nothing in the configuration expresses the
requirement, so the same build silently fails the moment the deployment has one address on
that VLAN — a standalone unit, or the standby half of a pair, where floating addresses are
inactive.

**`source-address-translation none`** leaves the client's own address as the source. Tried
first, because the hop never leaves the appliance and needs no address of its own. It fails
everywhere it was measured — `000` after 8 s on both nora units, and on a standalone UDF unit
— because it makes the hop depend on whatever address the portal engine's connection happens
to carry, which is not a property the build controls.

**Adding an address so automap has a choice** — a floating self IP, or a second self IP — is
not portable. UDF filters source addresses it has not assigned to the interface, so an address
added inside the guest is not a usable source there at all; adding a floating self IP on a UDF
unit moved TMM's egress source for *all* self-originated traffic and broke APM's LDAP bind
outright, trading a broken tile for a broken login. On a standalone unit a self IP in
`traffic-group-1` does not even survive, because there is no device group to own it.

Measured on solo `bigip-a` (nora, TMOS 21.1), probing the façade from the appliance, and
cross-checked on a standalone unit in UDF (TMOS 17.5.1):

| Source translation | nora, standalone | UDF, standalone |
|---|---|---|
| `automap` | `000` in 8.0 s | fails (`PR_CONNECT_RESET_ERROR`) |
| `none` | `000` in 8.0 s | fails |
| **dedicated SNAT pool** | **`200` in 0.061 s** | **works** |

The two labs agree completely: only the pinned source works, in either of them. Nothing about
the deployment's shape or environment changes the answer, which is what makes this worth
encoding in the build rather than left as a per-site adjustment.

## Consequences

**One code path.** The build no longer branches on unit count for the façade, so a deployment
that changes shape — a pair losing its peer, a unit rebuilt standalone — needs no different
configuration and no manual step. The PATCH on every run is what makes that true for
deployments that already exist.

**It costs one address.** `MFA_FACADE_SNAT_ADDR` (default: `.240` on `BIGIP_A_TMUI`'s subnet)
must not collide with anything real. It never leaves the appliance — the hop is TMM to its own
self IP — so it needs no route, no ARP beyond the local VLAN, and nothing in the fabric sees
it. That is also why it is safe in environments like UDF that filter unassigned sources.

**The validator drives the hop.** `scripts/validate.sh` fetches TMUI's login page through each
façade from the appliance itself and fails when it cannot. Asserting that objects exist was
never sufficient here: every object was right and the tile was still dead. With the source
pinned, that probe is meaningful again — under `none` it could not work at all, since a
probe originating on the appliance cannot produce a valid client source.

**Verified on two standalone units, in two labs, on two TMOS versions.** On nora (21.1) the
full cycle — `teardown.sh --bigip` then `deploy.sh --bigip`, with no manual step — gave
`validate.sh` 22 PASS, the accept/deny matrix 9/9, and the webtop tile opening TMUI already
authenticated. The same SNAT pool was confirmed working on a standalone unit in UDF (17.5.1),
where both rejected alternatives had already failed. Two independent environments, on two
TMOS versions, agreeing on the same single answer is what promotes this from "fixed my box"
to a rule worth encoding in the build.

**Not yet verified on a pair.** The peer was powered off when this landed, so the HA path
still rests on `automap` having worked there historically. The pair has strictly more
addresses available and only the active unit uses the pool, so no failure is expected — but
expecting is not testing. Re-run `validate.sh`, the matrix and a tile fetch on a pair before
relying on it there.
