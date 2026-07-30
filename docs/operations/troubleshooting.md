# Troubleshooting

Every entry below is a failure that actually occurred while building this demo on TMOS
21.1.0. They are listed by what you see, not by what is wrong, because the symptom is rarely
where the cause is.

Start with `scripts/validate.sh`. It exits with the number of failed checks and localises
most problems to a component in one run.

## Symptom index

| Symptom | Likely cause | Section |
|---|---|---|
| Every login is denied, even with a correct password | Tcl syntax error in a policy branch | [Deny after a successful OIDC exchange](#deny-after-a-successful-oidc-exchange) |
| Read-only user gets HTTP 401 from `curl` | Correct behaviour — Guest has no REST access | [A read-only user returns 401](#a-read-only-user-returns-401) |
| Everyone lands read-only, including the admin | `check-roles-group` disabled | [Nobody gets elevated](#nobody-gets-elevated) |
| Admin works, read-only user is rejected outright | Roles evaluated but stale auth cache | [Rapid user switching returns 401](#rapid-user-switching-returns-401) |
| Works until failover, then everyone is read-only | Auth configured on one unit only | [Failover loses authorization](#failover-loses-authorization) |
| Keycloak container exits at startup | Unknown field in the realm import | [Keycloak refuses the realm](#keycloak-refuses-the-realm) |
| OAuth step fails or the BIG-IP cannot reach Keycloak | Name resolution on the appliance | [The BIG-IP cannot resolve Keycloak](#the-big-ip-cannot-resolve-keycloak) |
| CoreDNS will not start, port in use | systemd-resolved holds :53 | [CoreDNS cannot bind port 53](#coredns-cannot-bind-port-53) |
| Nobody is in the admin group | Overlay applied after the group | [memberOf is empty](#memberof-is-empty) |
| Webtop appears empty in a scripted check | Resources load asynchronously | [The webtop shows no resources](#the-webtop-shows-no-resources) |
| `scope=openid openid` on the authorization request | Scope set in two places | [Duplicated OAuth scope](#duplicated-oauth-scope) |
| Portal resource fails with errorcode 17 | Reserved target address | [Portal access refuses the target](#portal-access-refuses-the-target) |

## Deny after a successful OIDC exchange
`/var/log/apm` shows `OAuth Client: succeeded ... using 'authorization_code' grant type` and
then, immediately after, `Access policy result: Logon_Deny`. Nearby:

```text
Rule evaluation failed with error: syntax error in expression
"[mcget {session.oauth.client.last.errMsg}] == ": premature end of expression
```

The authentication worked; the branch that evaluates it did not. An empty double-quoted
string literal (`== ""`) does not survive being written through iControl REST into the stored
rule — what lands on the appliance is `== ` followed by nothing, which is invalid Tcl. The
branch throws, the policy takes `fallback`, and every correct login is denied.

Use braces, which carry an empty string through intact:

```text
expr {[mcget {session.oauth.client.last.errMsg}] eq {}}
```

`bigip/apm-build.sh` already does this. If you hand-edit a branch in the Visual Policy Editor,
the same trap applies.

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
tmsh list auth remote-role role-info warden_lite_admins
tmsh list auth source
```

`docs/operations/runbooks/failover-check.md` exists to catch this before a customer does.

## Keycloak refuses the realm
The container exits immediately after import with:

```text
ERROR: Failed to run import
ERROR: Unrecognized field "_comment" (class org.keycloak.representations.idm.RealmRepresentation)
```

Keycloak's importer rejects unknown fields outright rather than ignoring them. The realm
template carries its rationale in `_comment` keys, so `deploy.sh` strips them with `jq` while
rendering. If you import the template by hand, strip them too:

```bash
jq 'walk(if type == "object" then with_entries(select(.key | startswith("_comment") | not)) else . end)' \
  keycloak/warden-lite-realm.json.tmpl
```

## The BIG-IP cannot resolve Keycloak
The OAuth step fails, or the token exchange never happens, while the same URL resolves
perfectly from your workstation.

A TMOS `dns-resolver` performs its own lookups in TMM. It does **not** read the appliance's
`/etc/hosts`, so a hosts-file entry cannot fix this — that workaround covers the browser only.
warden-lite ships CoreDNS for exactly this reason. Check the resolver and that it can reach
the stack host:

```bash
tmsh list net dns-resolver warden-lite-resolver
dig +short @<WL_HOST_IP> <WL_KEYCLOAK_FQDN>
```

Also confirm the issuer matches. `KC_HOSTNAME` pins Keycloak's issuer, and APM validates it
against the configured provider URIs; a mismatch produces an opaque failure that names
neither value.

## CoreDNS cannot bind port 53
`docker compose up` fails with:

```text
failed to bind host port 0.0.0.0:53/tcp: address already in use
```

Most Linux hosts already run a stub resolver — systemd-resolved on `127.0.0.53`. warden-lite
binds CoreDNS to the host's lab address rather than the wildcard, which avoids the collision
and is also the exact address the BIG-IP resolver points at. Confirm what holds the port:

```bash
sudo ss -lntup | grep ':53'
```

If something is genuinely bound to `WL_HOST_IP:53`, set `WL_DNS_PORT` to a free port and
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
docker exec -i openldap ldapmodify -x -D "cn=admin,${BASE_DN}" -w "${WL_LDAP_ADMIN_PW}" <<'LDIF'
dn: cn=bigip-admins,ou=groups,dc=warden-lite,dc=lab
changetype: modify
delete: member
member: uid=alice.admin,ou=people,dc=warden-lite,dc=lab
-
add: member
member: uid=alice.admin,ou=people,dc=warden-lite,dc=lab
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

## Duplicated OAuth scope
The authorization request goes out as `scope=openid openid`. Harmless with Keycloak, but it
means the scope is configured twice: once as a value on the `scope` parameter of the
auth-redirect `oauth-request` object, and once on the `aaa-oauth` agent. Leave the request
object's `scope` parameter with no value — APM substitutes the agent's scope.

Note also that `tmsh create` is not idempotent for these objects, so `bigip/apm-build.sh`
deletes and recreates them; a re-run that only issues `create` leaves the old values in place
and appears to change nothing.

## Portal access refuses the target
Creating or using a portal resource fails with `01490585` / `errorcode=17`.

APM refuses "reserved" addresses as portal targets — self-IPs, the management address, and
device-trust or cluster addresses. Publishing TMUI on a routable self-IP would be a security
problem in any case. warden-lite points each portal resource at a non-routable RFC 5737
façade (`WL_SHADOW_A`, `WL_SHADOW_B`) and steers the last hop with an iRule `node` statement,
since an LTM pool cannot hold a self-IP. That path needs two database keys, which
`bigip/apm-build.sh` sets:

```bash
tmsh modify sys db tmm.tcl.rule.node.allow_loopback_addresses value true
tmsh modify sys db tmm.tcl.rule.connect.allow_loopback_addresses value true
```
