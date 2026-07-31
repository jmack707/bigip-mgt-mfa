# API / endpoint reference

The three interfaces bigip-mgt-mfa talks to, what it calls on each, and what the answers mean.

_Last validated: 2026-07._

## Overview
**bigip-mgt-mfa publishes no API of its own.** There is no service in this repo that listens
for callers, no REST surface it defines, and no client library to import. It is an
integration of three pre-existing interfaces, and this document is the contract it depends
on:

- the **BIG-IP iControl REST API**, which is how the build scripts create every object on
  the two appliances;
- **Keycloak's OpenID Connect endpoints**, which the APM OAuth client drives during the
  step-up, and which the deployer and validator read directly; and
- the **APM data plane** — the handful of user-facing URLs a browser walks between the logon
  page and the webtop.

Knowing which of the three a failure came from is most of triage, because each answers in a
different vocabulary. iControl REST returns `409` and `404` that the scripts deliberately
tolerate; Keycloak returns JSON and HTML form redirects; the data plane sometimes returns no
HTTP status at all, because the failure happened during the handshake.

Two properties are worth holding in mind before reading the tables:

- **There is no privileged standing credential in the login path.** The credential
  single-signed-on to TMUI is the user's own, collected by the APM logon page and proven
  against the directory before Keycloak is ever contacted. No endpoint below issues,
  brokers or stores a password on the user's behalf.
- **Site-specific values are placeholders here.** `<BIGIP_A_MGMT>`, `<BIGIP_B_MGMT>`,
  `<MFA_KEYCLOAK_FQDN>`, `<MFA_KEYCLOAK_PORT>`, `<MFA_KEYCLOAK_REALM>`, `<MFA_WEBTOP_FQDN>`,
  `<MFA_APM_VIP>`, `<MFA_SHADOW_A>` and `<MFA_SHADOW_B>` all come from `.env` — see
  [configuration.md](configuration.md). The scripts that make these calls are documented in
  [cli.md](cli.md).

## Endpoints

### BIG-IP iControl REST — `https://<BIGIP_A_MGMT>/mgmt` and `https://<BIGIP_B_MGMT>/mgmt`
Basic authentication as `<BIGIP_USER>`. Every call uses `curl -sk`, because the management
certificate is the device's own self-signed one and bigip-mgt-mfa installs no trust for it.

| Path | Method | Called by | What it does |
|---|---|---|---|
| `/shared/file-transfer/uploads/<name>` | POST | `bigip/system-auth.sh`, `bigip/apm-build.sh` | Chunked binary upload into `/var/config/rest/downloads/`. Carries the directory CA, the demo CA, and the webtop certificate and key |
| `/tm/sys/file/ssl-cert`, `/tm/sys/file/ssl-cert/<name>` | GET, POST, PATCH | both build scripts | Create-or-update a certificate object from an uploaded file. The GET comes first on purpose: an object that already exists still holds the **old** material, and stale trust fails closed |
| `/tm/sys/file/ssl-key`, `/tm/sys/file/ssl-key/<name>` | GET, POST, PATCH | `bigip/apm-build.sh` | The same create-or-update for the webtop private key. The collection is `ssl-key` while the uploaded file is `.key`, which is why the loop pairs endpoint and extension explicitly |
| `/tm/auth/ldap`, `/tm/auth/ldap/system-auth` | GET, POST, PATCH | `bigip/system-auth.sh` | The device's own LDAPS system authentication: servers, port, `sslCaCertFile`, bind DN, search base, login attribute, and `checkRolesGroup: enabled` |
| `/tm/auth/remote-user` | GET, PATCH | `bigip/system-auth.sh`, `scripts/validate.sh` | `defaultRole: guest`, `remoteConsoleAccess: disabled`. This is the read-only outcome, and it is a default rather than a rule — nothing about the non-admin user is configured anywhere |
| `/tm/auth/remote-role/role-info`, `/tm/auth/remote-role/role-info/bigip_mgt_mfa_admins` | GET, POST, PATCH, DELETE | `bigip/system-auth.sh`, `scripts/validate.sh`, `teardown.sh` | The one rule that grants `administrator`, matching `MFA_ADMIN_ROLE_ATTRIBUTE`. The validator reads `.attribute` back and compares it to the configured string |
| `/tm/auth/source` | GET, PATCH | `bigip/system-auth.sh` (`ldap`), `scripts/validate.sh`, `teardown.sh` (`local`, first) | Flips the device auth source. `admin` and `root` stay local, so neither direction can lock you out |
| `/tm/sys/config` | POST | `bigip/system-auth.sh`, `teardown.sh` | `{"command":"save"}`. Authentication changes are not persistent until saved |
| `/tm/ltm/profile/client-ssl`, `/tm/ltm/profile/server-ssl` | POST | `bigip/apm-build.sh` | The VIP's client-side profile, and the server-side profile that validates Keycloak against the demo CA on the OAuth back channel (`peerCertMode: require`) |
| `/tm/ltm/rule` | POST | `bigip/apm-build.sh` | Three iRules: the two `node` steers behind the shadow façades, and the referer strip in front of TMUI's login form |
| `/tm/ltm/virtual`, `/tm/ltm/virtual/~Common~bigip-mgt-mfa-vs` | GET, POST, DELETE | `bigip/apm-build.sh`, `scripts/validate.sh` | The webtop virtual server on `<MFA_APM_VIP>:443` and the two shadow façade virtual servers |
| `/tm/apm/policy/customization-group` | POST | `bigip/apm-build.sh` | The presentation groups an access profile requires: logon, logout, webtop, eps, errormap, framework-installation, general-ui |
| `/tm/apm/policy/agent/logon-page`, `/aaa-ldap`, `/aaa-oauth`, `/variable-assign`, `/resource-assign`, `/ending-allow`, `/ending-deny` | POST, DELETE | `bigip/apm-build.sh` | The per-item agents. `variable-assign` with `type: sso-cred-mapping` is the entire single sign-on: it copies the username and the already-proven password into the SSO session variables |
| `/tm/apm/policy/policy-item/` | POST | `bigip/apm-build.sh`, inside a transaction | Each node of the graph, with its branch rules |
| `/tm/apm/policy/access-policy/`, `/tm/apm/profile/access/`, `/tm/apm/profile/access/~Common~bigip-mgt-mfa` | GET, POST, DELETE | `bigip/apm-build.sh`, `scripts/validate.sh` | The policy that binds the items and the profile that binds the policy. The validator queries this path on **both** units — present on A but absent on B means the config-sync did not run, and a failover would lose the webtop |
| `/tm/apm/sso/form-based` | POST | `bigip/apm-build.sh` | TMUI form SSO: `startUri /tmui/login.jsp*`, `formAction /tmui/logmein.html`, fields `username` and `passwd` |
| `/tm/apm/resource/webtop` | POST, DELETE | `bigip/apm-build.sh` | The full webtop the session lands on |
| `/tm/apm/resource/portal-access` | GET, POST | `bigip/apm-build.sh`, `scripts/validate.sh` | One Portal Access resource per unit, targeting the shadow façade rather than the real self IP. The validator asserts exactly two resources whose names start with `bigip-mgt-mfa-bigip` |
| `/tm/apm/profile/connectivity` | POST | `bigip/apm-build.sh` | The connectivity profile the webtop VIP carries |
| `/tm/transaction`, `/tm/transaction/<id>` | POST, PATCH | `bigip/apm-build.sh` | Opens a transaction for the policy graph, then commits it with `{"state":"VALIDATING"}` so a half-applied graph cannot persist |
| `/tm/apm/aaa/ldap/<name>`, `/tm/apm/aaa/oauth-provider/<name>`, `/tm/apm/aaa/oauth-request/<name>`, `/tm/apm/aaa/oauth-server/<name>` | DELETE | `teardown.sh` | The AAA objects the build creates through `tmsh`. They are removable over REST even though they are not creatable there in the shape TMOS 21.x wants |
| `/tm/ltm/pool/<name>`, `/tm/net/dns-resolver/<name>` | DELETE | `teardown.sh` | The AAA server pool and the demo-zone resolver |
| `/tm/cm/device-group` | GET | `deploy.sh`, `teardown.sh` | Discovers the first `sync-failover` group when `MFA_DEVICE_GROUP` is empty. No group means standalone, and the sync step is skipped rather than failed |
| `/tm/sys/version` | GET | `scripts/validate.sh` | Used only as an authentication probe with a demo user's credential, to generate the audit line the role check then reads |
| `/tm/util/bash` | POST | `deploy.sh`, `teardown.sh`, `bigip/apm-build.sh`, `scripts/validate.sh`, `scripts/demo-login.sh` | The escape hatch where REST has no route, described below |
| every path listed by `bigip/lib/objects.sh` | DELETE | `bigip/apm-build.sh` before each rebuild, and `teardown.sh` | One shared object list, in an order TMOS accepts: policy and profile first, then the items they reference. Sharing the list is what keeps build and teardown from drifting |

`/tm/util/bash` carries the calls REST genuinely cannot express, and each use is a specific
gap rather than a shortcut. The APM AAA LDAP object, because TMOS 21.x requires a server
**pool** and rejects a bare address. The `net dns-resolver`, the `apm aaa oauth-provider`,
`oauth-request` and `oauth-server` objects. The two `tmm.tcl.rule.*.allow_loopback_addresses`
sys `db` keys, without which the shadow iRules' `node` verb refuses an internal target. The
Portal Access item headers `destipaddr` and `referer`, which are `header_data_t` values a
REST body cannot express, and the resource caption alongside them. The config-sync itself.
`sessiondump --allkeys` in `scripts/demo-login.sh`, to read the resources actually attached
to a session. And `grep pam_audit /var/log/secure` in `scripts/validate.sh`, which is where
the role a user really received is recorded.

### Keycloak OIDC — `https://<MFA_KEYCLOAK_FQDN>:<MFA_KEYCLOAK_PORT>`
Everything the demo uses lives under `/realms/<MFA_KEYCLOAK_REALM>/`. Two different clients
call these: the BIG-IP's APM OAuth server, over the back channel, validating the certificate
against the demo CA; and the browser, over the front channel.

| Path | Method | Reached by | What it does |
|---|---|---|---|
| `/realms/<realm>/.well-known/openid-configuration` | GET | `deploy.sh` (readiness), `scripts/validate.sh` (issuer assertion), and APM as `openid-cfg-uri` | The discovery document. APM is built with `use-auto-jwt-config true`, so this is also where it learns the signing keys. `deploy.sh` polls it for up to five minutes and refuses to finish the stack half until `.issuer` comes back |
| `/realms/<realm>/protocol/openid-connect/auth` | GET (redirect) | the browser, sent there by the APM OAuth agent | The authorization endpoint. APM's `auth-redirect-request` object sends `client_id`, `redirect_uri`, `response_type` and `scope`, and nothing else |
| `/realms/<realm>/protocol/openid-connect/token` | POST | the BIG-IP, back channel | The authorization-code exchange. APM's `token-by-code` request object sends `client_id`, `client_secret`, `grant_type` and `redirect_uri`; APM appends `code` itself. A separate `token-refresh` object sends `grant_type=refresh_token` |
| `/realms/<realm>/protocol/openid-connect/userinfo` | GET | the BIG-IP, back channel | Configured on the provider as `userinfo-request-uri` |
| `/realms/<realm>/login-actions/authenticate` and the other `login-actions/` form targets | POST | the browser | The username form and then the OTP form — the realm's browser flow is second-factor only, with no password step, because APM has already proven the password. `scripts/demo-login.sh` scrapes the form `action` rather than hardcoding these paths, because they carry per-session parameters |
| `/admin/` | GET | an operator | The Keycloak administration console, as `<MFA_KEYCLOAK_ADMIN>`. `deploy.sh` prints the URL when the stack half completes |

The issuer is the thing to watch. `KC_HOSTNAME` pins it to
`https://<MFA_KEYCLOAK_FQDN>:<MFA_KEYCLOAK_PORT>` so it cannot float with the request `Host`
header, and APM validates the `iss` claim in the returned token against exactly the provider
URIs it was built with. The FQDN must therefore resolve to the same place for the browser
and for the BIG-IP, which is the reason the stack ships its own resolver.

### APM data plane — `https://<MFA_WEBTOP_FQDN>/` (the VIP `<MFA_APM_VIP>`)
| Endpoint | Purpose |
|---|---|
| `https://<MFA_WEBTOP_FQDN>/` | The front door. An unauthenticated request establishes an APM session and is redirected to the logon page; an authenticated one is served the webtop |
| `https://<MFA_WEBTOP_FQDN>/my.policy` | The access policy endpoint. GET serves the logon page; POST submits `username`, `password` and `vhost=standard`, which drives the LDAP Auth item. On success the response redirects to Keycloak's authorization endpoint |
| `https://<MFA_WEBTOP_FQDN>/oauth/client/redirect` | The OIDC `redirect_uri`, configured identically on the APM OAuth agent and in the Keycloak client's `redirectUris`. Keycloak returns the browser here with the authorization code, and APM does the back-channel token exchange from this point |
| the webtop page | What a session that reached the Allow ending is served. `scripts/demo-login.sh` recognises it by the `"pageType": "webtop"` marker in the response |
| `https://<MFA_SHADOW_A>/tmui/login.jsp`, `https://<MFA_SHADOW_B>/tmui/login.jsp` | The `applicationUri` of the two Portal Access resources. These RFC 5737 addresses are not routable and are never browsed directly: a plain LTM virtual server listens on each, and a `node` iRule makes the real hop to `BIGIP_A_TMUI` or `BIGIP_B_TMUI`. They exist because APM Portal Access refuses reserved targets such as self IPs |

The webtop tile is where form SSO takes over: the portal engine fetches TMUI's login form and
`bigip-mgt-mfa-tmui-sso` posts the username and password already held in the session. The user
never types a second password, and the BIG-IP on the far end still decides the role for
itself.

## Status codes

### iControl REST
| Code | Where | Operational meaning |
|---|---|---|
| `200`, `201` | any create or modify | Applied. Both build scripts print the status for every call, so a transcript is a usable audit trail |
| `409 Conflict` | the additive `POST`s in `bigip/apm-build.sh` | The object already exists. The `add` helper accepts `200`, `201` and `409` and fails on anything else, which is what lets the build re-run without tearing down the immutable objects first |
| `404 Not Found` | the pre-rebuild `DELETE`s, and every `DELETE` in `teardown.sh` | Already absent, which is the desired end state. These deletes are not checked at all — a transcript full of `404` is a clean first run or a clean teardown, not a broken one |
| `>= 400` from `bigip/system-auth.sh` | any call | Fatal. Unlike the APM build, this script tolerates nothing: it prints the response body and exits, because a half-configured auth source is worse than none |
| `401 Unauthorized` | a remote user calling any `/mgmt/tm/...` path | Ambiguous by design, and the trap worth knowing. The Guest role is denied iControl REST outright, so a correctly read-only user gets `401` even though the credential was accepted and TMUI would have worked. A genuinely wrong password produces the same `401`. Because the code cannot separate the two, `scripts/validate.sh` reads the role from the target's `/var/log/secure` `pam_audit` `level=` line instead of probing a status code |
| a commit response without `"state":"COMPLETED"` | `PATCH /tm/transaction/<id>` | The policy graph was rejected as a unit and nothing was applied. The printed body names the failing item |
| an empty `.commandResult` | `POST /tm/util/bash` | The command ran and said nothing, which for `tmsh create` is success. `tmsh` errors come back inside `commandResult` with a `200` status, so the status code alone never tells you a `tmsh` step worked — read the text |

### Keycloak
| Result | Where | Operational meaning |
|---|---|---|
| `200` with a JSON body carrying `.issuer` | the discovery document | The realm imported and is being served. This is `deploy.sh`'s readiness gate and the validator's first Keycloak check |
| a body with an `.issuer` that differs from `https://<fqdn>:<port>/realms/<realm>` | the discovery document | `KC_HOSTNAME` does not match what APM was built with. Token validation will fail later with an error that names neither the issuer nor the mismatch, so the validator asserts the equality up front |
| the OTP form redisplayed with no error | `POST` to a `login-actions/` target | The code was not accepted, or the wrong field name was submitted. The enrolment form calls the field `totp`; the plain OTP challenge calls it `otp`, and posting the wrong one is silently ignored |
| a redirect back to `<MFA_WEBTOP_FQDN>` | after the OTP form | The second factor succeeded and the authorization code is on its way to APM |

### APM data plane
| Result | Operational meaning |
|---|---|
| `200` or `302` at `https://<MFA_WEBTOP_FQDN>/` | The VIP is listening and the access profile is attached. `scripts/validate.sh` accepts either |
| HTTP status `000` | No response at all. The VIP is unreachable from where you are running, which is usually routing rather than configuration — run the check from a host on that network |
| no redirect from `POST /my.policy` | The password was rejected, or the LDAP Auth item itself failed. The distinction is in `/var/log/apm` on the unit, keyed by session id |
| a redirect that does not point at `<MFA_KEYCLOAK_FQDN>` | The OAuth agent did not run, which usually means the policy graph is not the one you think it is |
| the webtop served, but a session carrying fewer than two portal resources | The resource-assign item ran with a stale resource list. `session.assigned.resources.pa` in the session table is the authoritative answer; the returned HTML is not, because the modern webtop loads its resource list asynchronously |

## Content types
| Header or type | Where | Why it matters |
|---|---|---|
| `application/json` | every iControl REST write, set explicitly on every `POST` and `PATCH` | The management API is JSON-only for the paths bigip-mgt-mfa uses. Omitting the header gets the body rejected, so every helper in both build scripts sets it |
| `application/octet-stream` with `Content-Range: 0-<size-1>/<size>` | `POST /mgmt/shared/file-transfer/uploads/<name>` | Certificate and key installs are raw binary uploads, not JSON. The endpoint is a chunked-transfer API: `Content-Range` is mandatory and must describe the whole file (`stat -c%s`) for a single-chunk upload. Get it wrong and the upload appears to succeed while the file on the device is truncated, which surfaces much later as a trust failure |
| `X-F5-REST-Coordination-Id: <transId>` | every policy-item and profile `POST` inside the transaction in `bigip/apm-build.sh` | The header is what enrols a call in the open transaction instead of applying it immediately. A policy-graph `POST` that loses this header applies on its own, which is how a device ends up holding half a graph |
| basic auth (`-u <BIGIP_USER>:<BIGIP_PASS>`) | every iControl REST call | There is no token exchange on the management plane. `BIGIP_PASS` may be injected from the environment rather than stored in `.env` — see [configuration.md](configuration.md) |
| `application/x-www-form-urlencoded` | `POST /my.policy`, the Keycloak `login-actions/` forms, and the OIDC token request | The whole browser leg of the login is form posts. `scripts/demo-login.sh` uses `--data-urlencode` for the password and the raw TOTP secret specifically, because those are the two values that routinely contain characters a bare `-d` would mangle |
| a signed JWT in the token response | `POST /realms/<realm>/protocol/openid-connect/token` | What APM validates. It checks the `iss` claim against the provider it was built with and the signature against the keys discovered from the OpenID configuration, which is why the trusted CA bundle on the provider and the server-side SSL profile both have to be right |
| session cookies | the whole data-plane flow | APM tracks the session by cookie from the first request onward, which is why `scripts/demo-login.sh` runs every call through one shared cookie jar. Losing the jar between steps starts a new session and the logon page reappears |

## Related
- [configuration.md](configuration.md) — the variables every address and name above is built from.
- [cli.md](cli.md) — the scripts that make these calls.
- [../architecture.md](../architecture.md) — how the three interfaces fit together.
- [../operations/troubleshooting.md](../operations/troubleshooting.md) — symptom-first
  triage for the failures tabulated above.
