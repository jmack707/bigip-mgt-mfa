# Troubleshooting

Every entry below is a failure that actually occurred while building this demo on TMOS
21.1.0. They are listed by what you see, not by what is wrong, because the symptom is rarely
where the cause is.

Start with `scripts/validate.sh`. It exits with the number of failed checks and localises
most problems to a component in one run.

## Symptom index

| Symptom | Likely cause | Section |
|---|---|---|
| Read-only user gets HTTP 401 from `curl` | Correct behaviour — Guest has no REST access | [A read-only user returns 401](#a-read-only-user-returns-401) |
| Everyone lands read-only, including the admin | `check-roles-group` disabled | [Nobody gets elevated](#nobody-gets-elevated) |
| Admin works, read-only user is rejected outright | Roles evaluated but stale auth cache | [Rapid user switching returns 401](#rapid-user-switching-returns-401) |
| Works until failover, then everyone is read-only | Auth configured on one unit only | [Failover loses authorization](#failover-loses-authorization) |
| CoreDNS will not start, port in use | systemd-resolved holds :53 | [CoreDNS cannot bind port 53](#coredns-cannot-bind-port-53) |
| Nobody is in the admin group | Overlay applied after the group | [memberOf is empty](#memberof-is-empty) |
| Webtop appears empty in a scripted check | Resources load asynchronously | [The webtop shows no resources](#the-webtop-shows-no-resources) |
| Every code rejected, everyone, at once | Clock drift on the appliance | [Every code is rejected, for everyone, all at once](#every-code-is-rejected-for-everyone-all-at-once) |
| One user's codes rejected | Enrolled but not deployed, or period mismatch | [One user's codes are rejected](#one-users-codes-are-rejected) |
| A code that just worked is rejected on reuse | Codes are single-use — replay protection | [A just-used code is rejected](#a-just-used-code-is-rejected) |
| One user rejected even with correct codes, after failures | Lockout after too many wrong codes | [A user is locked out](#a-user-is-locked-out) |
| New user cannot log in at all | No seed — denial, not a skipped factor | [A brand-new user cannot log in at all](#a-brand-new-user-cannot-log-in-at-all) |
| Login denied, log names the bind account | Stale AAA object | [Every login is denied and the log blames the bind account](#every-login-is-denied-and-the-log-blames-the-bind-account) |
| Webtop opens TMUI's login form | SSO not injecting the credential | [The webtop opens TMUI's login form](#the-webtop-opens-tmuis-login-form) |
| REST 401/502, demo still serving | restjavad wedged — data plane unaffected | [iControl REST stops answering](#icontrol-rest-stops-answering) |
| Portal resource fails with errorcode 17 | Reserved target address | [Portal access refuses the target](#portal-access-refuses-the-target) |
| Tile resets, `PR_CONNECT_RESET_ERROR`, everything else green | Façade SNAT source equals the `node` target | [A webtop tile resets instead of opening TMUI](#a-webtop-tile-resets-instead-of-opening-tmui) |
| LDAP bind fails right after adding a self IP | The new address became TMM's egress source | [Adding a self IP breaks the LDAP bind](#adding-a-self-ip-breaks-the-ldap-bind) |

## A read-only user returns 401
Testing roles with `curl` against iControl REST reports the read-only user as broken:

```bash
curl -sk -u bob.user:<pw> https://<unit>/mgmt/tm/sys/version    # 401
```

This is correct behaviour, not a fault. The TMOS Guest role has no iControl REST permission,
so a properly configured read-only user is refused by REST while still being able to log into
TMUI read-only. Status codes are the wrong instrument here.

Ask the appliance what role it assigned instead:

```bash
tmsh run util bash -c "grep pam_audit /var/log/secure | grep bob.user | tail -1"
```

The `level=` field is authoritative — `level=Guest` for read-only, `level=Administrator` for
an admin. `scripts/validate.sh` asserts against exactly this.

## Nobody gets elevated
Every remote user, including members of the admin group, shows `level=Guest`. The
`remote-role` rule exists and looks correct.

`check-roles-group` is what makes TMOS consult the `remote-role` rules at all. Disabled, they
are silently ignored and everyone takes the default role. Confirm and fix:

```bash
tmsh list auth ldap system-auth check-roles-group
tmsh modify auth ldap system-auth check-roles-group enabled
```

`bigip/system-auth.sh` sets this; the failure appears if it was changed by hand.

## Rapid user switching returns 401
Alternating users against the management interface produces 401s for everyone, with
`/var/log/secure` showing:

```text
AUTHCACHE Error processing cookie ... - Cookie user mismatch
AUTHCACHE Error processing cookie ... - Cookie impersonation detected
```

This is the appliance's authentication cache, not your configuration — the audit lines in the
same log will show the users authenticating perfectly well. Space the requests out and send
`Connection: close`, or read the audit line rather than the status code.

## Failover loses authorization
The demo works, the active unit fails over, and now every user is read-only on the new active
unit.

`auth ldap system-auth` and `auth source` are device-local: config-sync does **not** carry
them to the peer. (`auth remote-role` *is* synced — but a role rule cannot authenticate
anyone on a unit that has no LDAP server configured, so the symptom is the same.) Every unit
must be configured explicitly, which is why `deploy.sh --bigip` loops over `BIGIP_A_MGMT` and,
when it is set, `BIGIP_B_MGMT`. On a deployment you believe is a pair, check that first: an
unset `BIGIP_B_MGMT` — or one still holding a quoted `"<bigip-b-mgmt-ip>"` sample, which
counts as unset — means unit B was never touched by the deploy, and that produces exactly this
symptom. Verify on each unit:

```bash
tmsh list auth remote-role role-info bigip_mgt_mfa_admins
tmsh list auth source
```

`docs/operations/runbooks/failover-check.md` exists to catch this before a customer does.

## CoreDNS cannot bind port 53
`docker compose up` fails with:

```text
failed to bind host port 0.0.0.0:53/tcp: address already in use
```

Most Linux hosts already run a stub resolver — systemd-resolved on `127.0.0.53`. bigip-mgt-mfa
binds CoreDNS to the host's lab address rather than the wildcard, which avoids the collision
and is also the exact address the BIG-IP resolver points at. Confirm what holds the port:

```bash
sudo ss -lntup | grep ':53'
```

If something is genuinely bound to `MFA_HOST_IP:53`, set `MFA_DNS_PORT` to a free port and
re-run `./deploy.sh` so the BIG-IP resolver is rebuilt with the new port.

## memberOf is empty
`validate.sh` reports that alice is not in the admin group, and an LDAP search returns no
`memberOf` attribute even though the group plainly lists her as a member.

OpenLDAP's `memberof` overlay computes the reverse attribute only for changes made *after*
the overlay is active. Seeding the group before applying the overlay produces a directory
where the membership exists but `memberOf` does not — and since `remote-role` maps on
`memberOf`, nobody is ever elevated.

`deploy.sh` applies the overlay first. To repair an already-seeded directory, recreate the
group membership:

```bash
docker exec -i openldap ldapmodify -x -D "cn=admin,${BASE_DN}" -w "${MFA_LDAP_ADMIN_PW}" <<'LDIF'
dn: cn=bigip-admins,ou=groups,dc=bigip-mgt-mfa,dc=lab
changetype: modify
delete: member
member: uid=alice.admin,ou=people,dc=bigip-mgt-mfa,dc=lab
-
add: member
member: uid=alice.admin,ou=people,dc=bigip-mgt-mfa,dc=lab
LDIF
```

Or start clean with `docker compose --profile bundled down -v` followed by `./deploy.sh --stack`.

## The webtop shows no resources
A scripted check fetches the webtop and finds the string `No resources found`, or no resource
names at all, even though the login succeeded.

The modern webtop loads its resource list asynchronously, and `No resources found` is a
template string present in the page whether or not it applies. Scraping the first response
tells you nothing. Ask the session table, which is authoritative:

```bash
tmsh run util bash -c "sessiondump --allkeys | grep assigned.resources.pa | tail -1"
```

A healthy session lists both portal resources. `scripts/demo-login.sh` asserts against this.

## A webtop tile resets instead of opening TMUI

The login succeeds, the webtop lists its tiles, and clicking one lands on the browser's own
error page — Firefox says `Secure Connection Failed` with `PR_CONNECT_RESET_ERROR`. Everything
else is green, including `scripts/validate.sh`.

On the wire the façade looks healthy right up to the point where it isn't:

```text
IP 10.1.1.13.59178 > 192.0.2.5.443: [S]    in  lis=/Common/bigip-mgt-mfa-shadow-a-vs
IP 192.0.2.5.443 > 10.1.1.13.59178: [S.]   out lis=/Common/bigip-mgt-mfa-shadow-a-vs
IP 10.1.1.13.59178 > 192.0.2.5.443: [P.] seq 1:177    length 176      ← TLS ClientHello
IP 192.0.2.5.443 > 10.1.1.13.59178: [.] ack 177                       ← acknowledged
      ← ten seconds of nothing →
IP 10.1.1.13.59178 > 192.0.2.5.443: [R.]                              ← client gives up
```

The façade accepted the connection, so routing to it is fine. With a plain TCP profile TMM
opens the **server-side** connection only after that first data, so ten seconds of silence
then a reset means the last hop — `node <self-ip> 443` — went unanswered.

The usual cause on a **single BIG-IP** is the façade's source address. SNAT `automap` picks a
self IP on the egress VLAN; where that VLAN has only one address, it is the `node` target
itself, and TMM will not complete a connection whose source equals its destination. The same
is true on the **standby** unit of a pair, where the floating addresses are inactive.

Reproduce or exonerate it in one command on the appliance, with no browser, session or webtop
involved:

```bash
curl -sk -o /dev/null --max-time 8 -w '%{http_code} %{time_total}s\n' https://192.0.2.5/tmui/login.jsp
```

`200` in hundredths of a second is healthy. `000` after ~4s is this fault. Then confirm the
source and the target are the same address:

```bash
tmsh list ltm virtual bigip-mgt-mfa-shadow-a-vs source-address-translation
tmsh list ltm rule bigip-mgt-mfa-shadow-a-node
tmsh list net self
```

The fix is to stop leaving the source to `automap` and pin it to an address that is never the
`node` target:

```bash
tmsh create ltm snatpool bigip-mgt-mfa-facade-snat { members add { 10.1.20.240 } }
tmsh modify ltm virtual bigip-mgt-mfa-shadow-a-vs \
  source-address-translation { type snat pool bigip-mgt-mfa-facade-snat }
tmsh save sys config
```

`bigip/apm-build.sh` does this automatically now — same configuration on a standalone unit and
on a pair — so **a redeploy is the durable fix**; the commands above are for a unit already
built. The address never leaves the appliance, so it needs no route.

Two fixes that look obvious and do **not** work, both tried:

- **`source-address-translation none`** fails — `000` after 8 s on nora, and likewise on a
  standalone UDF unit. It makes the hop depend on whatever address the portal engine's
  connection happens to carry, which the build does not control.
- **Adding a self IP** so `automap` has another address to pick is not portable — see
  [Adding a self IP breaks the LDAP bind](#adding-a-self-ip-breaks-the-ldap-bind).

[ADR 0007](../adr/0007-facade-source-address.md) records the measurements behind all three.

## Adding a self IP breaks the LDAP bind

Every login starts failing at the LDAP step immediately after adding a self IP — typically
while trying to give SNAT automap a second address to choose from.

TMM prefers a **floating** self IP as the source for its own outbound connections, so a new
floating address silently becomes the source for APM's LDAP queries. Whether that works
depends on the fabric, not on the BIG-IP: UDF and most cloud networks drop traffic from an
address they have not assigned to the interface, so the bind leaves and nothing comes back.

Compare the source address before and after:

```bash
tcpdump -nni 0.0 host <directory-ip> and port 389
```

A healthy bind shows the SYN sourced from the unit's original self IP and answered:

```text
IP 10.1.20.4.20070 > 10.1.20.14.389: [S]     out
IP 10.1.20.14.389 > 10.1.20.4.20070: [S.]    in
```

If the SYN now carries the newly added address and no `[S.]` returns, remove the address. In
environments that filter unassigned sources, no added address — floating self IP or SNAT pool
member — is usable, which is why the façade fix uses no translation at all.

## Portal access refuses the target
Creating or using a portal resource fails with `01490585` / `errorcode=17`.

APM refuses "reserved" addresses as portal targets — self-IPs, the management address, and
device-trust or cluster addresses. Publishing TMUI on a routable self-IP would be a security
problem in any case. bigip-mgt-mfa points each portal resource at a non-routable RFC 5737
façade (`MFA_SHADOW_A`, `MFA_SHADOW_B`) and steers the last hop with an iRule `node` statement,
since an LTM pool cannot hold a self-IP. That path needs two database keys, which
`bigip/apm-build.sh` sets:

```bash
tmsh modify sys db tmm.tcl.rule.node.allow_loopback_addresses value true
tmsh modify sys db tmm.tcl.rule.connect.allow_loopback_addresses value true
```

## Every code is rejected, for everyone, all at once

Logins that worked yesterday all fail at the MFA step. Nothing else on the appliance
misbehaves, which is what makes this one hard to guess.

Check the clock before anything else. TOTP is computed from the current time step, so drift
beyond the acceptance window rejects every code from every user simultaneously:

```bash
tmsh show sys ntp status
```

The window is `MFA_TOTP_PERIOD × (2 × MFA_TOTP_SKEW + 1)` — with the defaults, three minutes.
`deploy.sh --bigip` prints the computed value on every run.

## One user's codes are rejected

Their authenticator and the stored seed disagree. The usual cause is enrolling without
deploying: `scripts/enroll-totp.sh` writes the seed locally, and **`./deploy.sh --bigip` is
what loads it into the appliance**. Until that runs, the BIG-IP is still checking against the
previous seed, which is indistinguishable from a broken phone.

Confirm what the appliance actually holds:

```bash
tmsh list ltm data-group internal bigip_mgt_mfa_totp_dg
```

The other cause is a period mismatch. Google Authenticator ignores the period in the QR and
always generates 30-second codes, so at the default 60 it produces codes that never match.
Re-enrol in FreeOTP, Aegis or 1Password, or set `MFA_TOTP_PERIOD=30`.

Record values in that listing are `v2:<iv>:<ciphertext>`, not seeds — the username being
present is what you are checking. A record **not** in that shape is itself the fault: the
verifier rejects it as `bad-seed` (the APM log says so), and a re-run of
`./deploy.sh --bigip` rewrites the store correctly.

## A just-used code is rejected

Intended. Codes are single-use within their acceptance window (RFC 6238 §5.2): once a code
verifies, presenting it again is denied as a replay and logged with `REPLAYED`. This is most
often seen re-running `scripts/test-mfa-matrix.sh` twice within one code period — the two
GRANT cases fail on the second run. Wait for the next period, or read it as the replay
protection demonstrating itself. The matrix also asserts the denial deliberately, with
alice's just-accepted code.

Running `validate.sh` immediately before the matrix used to trip the same wire: its SSO check
performs a real login, which spent alice's code for that step, and the matrix then reported
`alice: correct pw + her own OTP -> DENY (expected GRANT)` — the protection working, reading
as a broken demo. `validate.sh` now drives that probe as a principal the matrix does not
grant (`carol.netops`, else `dave.audit`), so the two scripts can run back to back. Setting
`MFA_SSO_TEST_USER` to `alice.admin` or `bob.user` reintroduces the collision by hand.

## A user is locked out

One user is rejected even with codes that are visibly correct, immediately after a run of
failures. That is the verifier's throttle: `MFA_TOTP_MAX_FAILURES` consecutive wrong or
replayed codes (default 5) refuse the second factor for `MFA_TOTP_LOCKOUT_SECONDS`
(default 300). The BIG-IP log line says `LOCKED` with the username and client address —
which is also what a brute-force attempt against that user looks like, so look at the
addresses before dismissing it as a fumbled phone.

There is nothing to reset: the counter expires on its own, and a successful login clears it.
Malformed submissions (anything not six digits) are denied without counting, so junk input
cannot lock anyone out.

## A brand-new user cannot log in at all

Intended. No seed means no token, and the policy treats an absent token as a denial rather
than a skipped factor — otherwise a new account would pass on a password alone. Enrol them
and redeploy.

## Every login is denied and the log blames the bind account

`/var/log/apm` shows:

```text
LDAP Module: Failed to bind with 'cn=...,ou=svc,dc=...'. Invalid credentials.
```

Note whose DN that is: the **bind account's**, not the user's. It reads like the user's
password is wrong, and it is not.

The usual cause is a stale AAA object. `tmsh create apm aaa ldap` is not idempotent — it
keeps the existing object and reports success — so after a change to the directory address,
bind DN or search base, the appliance can be using values that appear in no config file. The
build now deletes and recreates it; if you are on an older revision, remove the object and
re-run.

## The webtop opens TMUI's login form

Single sign-on is not injecting the credential. The configuration can look perfect while this
happens, which is why `validate.sh` now drives a real login rather than only inspecting
objects.

Check the portal item — and read it from the **`/items` sub-collection**, because the parent
object reports these fields as `null` even when they are set correctly:

```bash
curl -sku admin: "https://<unit>/mgmt/tm/apm/resource/portal-access/~Common~<name>/items" \
  | jq '.items[0] | {sso, headers}'
```

You want an `sso` naming the form-SSO profile and **two** headers. `referer` is what satisfies
TMUI's `login.jsp` CSRF check; without it the form refuses the submission.

## iControl REST stops answering

Symptoms range from `401` and `502 Proxy Error` to `/mgmt/tm/util/bash` reporting
`Public URI path not registered`, or the address simply not answering at all. `restjavad`
wedges after a heavy run of REST calls and usually recovers on its own;
`bigstart restart restjavad` clears it immediately.

**The volume of calls is the trigger; the cause is memory.** Measured on an 8 GB VE running
LTM + APM on TMOS 21.1, mid-demo:

```bash
free -m        # 7984 total, ~70 MB available
free -m | tail -1   # Swap: 999 used of 999 — fully consumed
grep -c OutOfMemory /var/log/restjavad*.log   # 0, on every file
```

No Java heap exhaustion anywhere — so raising the restjavad heap is not the fix, and
`restjavad.useextramb` does not exist on 21.1 (`01020036:3 ... not found`). The box has no
free memory and no swap left, so any burst of management-plane work pushes it into thrashing
and restjavad stops answering. In order of effect:

1. `bigstart restart restjavad restnoded` — reclaims the two `java` processes (~580 MB
   resident between them) and clears the wedge now.
2. **Give the guest more RAM.** 8 GB is the floor for LTM + APM, not a working figure.
3. Only then consider `provision.extramb` (it defaults to `0`). Raising it while the box is
   already at ~70 MB available takes memory it does not have and makes matters worse.

Both scripts keep their `/mgmt/tm/util/bash` use to a minimum for the same reason: that
endpoint forks a shell and loads `tmsh` on the appliance, so it is far more expensive than a
plain `GET`. `validate.sh` reads the audit log **once per unit** rather than once per user,
and `apm-build.sh` batches its `tmsh` commands.

**This does not mean the demo is down.** The data plane is independent — TMM keeps serving
the webtop perfectly while the management plane is unavailable. Check the VIP before
concluding otherwise:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://<MFA_APM_VIP>/
```

`validate.sh` gates its configuration checks on a reachability probe for this reason, and
re-probes **before every per-unit block** rather than only once at the top
([issue #4](https://github.com/jmack707/bigip-mgt-mfa/issues/4)). A unit that wedges
part-way through a run is therefore reported as `SKIP` with the reason, not as a wall of
configuration failures — and on a pair, one wedged unit no longer suppresses its healthy
peer's results. Expect output like:

```text
  SKIP  10.1.1.5 role checks — REST stopped answering mid-run (not necessarily misconfigured)
  PASS  10.1.1.6: alice.admin -> Administrator
```

Because `remote-role` and the access tier are config-synced, the peer's `PASS` lines are good
evidence about what the wedged unit holds. They are not proof: `auth ldap system-auth` and
`auth source` are device-local, so re-run once the unit answers again.

If a run reports failures that make no sense, confirm with `f5.sh status` and with
`scripts/test-mfa-matrix.sh`, which drives the data plane and is unaffected by the management
plane being down. Seven passes there means authentication is working regardless of what the
configuration checks claim.
