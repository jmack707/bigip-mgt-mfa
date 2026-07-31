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
| New user cannot log in at all | No seed — denial, not a skipped factor | [A brand-new user cannot log in at all](#a-brand-new-user-cannot-log-in-at-all) |
| Login denied, log names the bind account | Stale AAA object | [Every login is denied and the log blames the bind account](#every-login-is-denied-and-the-log-blames-the-bind-account) |
| Webtop opens TMUI's login form | SSO not injecting the credential | [The webtop opens TMUI's login form](#the-webtop-opens-tmuis-login-form) |
| REST 401/502, demo still serving | restjavad wedged — data plane unaffected | [iControl REST stops answering](#icontrol-rest-stops-answering) |
| Portal resource fails with errorcode 17 | Reserved target address | [Portal access refuses the target](#portal-access-refuses-the-target) |

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
anyone on a unit that has no LDAP server configured, so the symptom is the same.) Both units
must be configured explicitly, which is why `deploy.sh --bigip` loops over `BIGIP_A_MGMT` and
`BIGIP_B_MGMT`. Verify on each unit:

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
`Public URI path not registered`. `restjavad` wedges under a heavy run of REST calls and
usually recovers on its own; `bigstart restart restjavad` clears it.

**This does not mean the demo is down.** The data plane is independent — TMM keeps serving
the webtop perfectly while the management plane is unavailable. Check the VIP before
concluding otherwise:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://<MFA_APM_VIP>/
```

`validate.sh` gates its configuration checks on a reachability probe for this reason — but
that probe runs **once**, before the BIG-IP section. If `restjavad` is answering at that
moment and wedges part-way through, the later checks still report as configuration failures.
Known limitation, tracked as
[issue #4](https://github.com/jmack707/bigip-mgt-mfa/issues/4).

If a run reports failures that make no sense, confirm with `f5.sh status` and with
`scripts/test-mfa-matrix.sh`, which drives the data plane and is unaffected by the management
plane being down. Seven passes there means authentication is working regardless of what the
configuration checks claim.
