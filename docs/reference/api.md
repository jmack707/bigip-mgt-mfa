# API reference

## Overview

This repository publishes no API of its own. It is a deployer: shell scripts that drive
interfaces owned by other systems. This page documents the ones the scripts depend on, so
that a failure can be attributed to the right component.

Two interfaces matter:

- **iControl REST** on each BIG-IP, which `deploy.sh --bigip` uses to build the access tier.
- **The APM data plane** on the webtop virtual server, which the validation scripts drive the
  way a browser would.

There is no longer any identity-provider API in this design. An earlier revision drove
Keycloak's OpenID Connect endpoints; the appliance now verifies one-time codes itself, so
nothing is called at login time. See
[../adr/0002-verify-totp-on-the-bigip.md](../adr/0002-verify-totp-on-the-bigip.md).

## Endpoints

### iControl REST

Base: `https://<BIGIP_MGMT>/mgmt/`, HTTP Basic with `BIGIP_USER` / `BIGIP_PASS`.

| Path | Used for |
|---|---|
| `tm/sys/version` | Reachability probe. `validate.sh` gates every other check on this |
| `shared/file-transfer/uploads/<name>` | Uploading the CA and the webtop certificate |
| `tm/sys/file/ssl-cert`, `tm/sys/file/ssl-key` | Creating or updating the certificate objects |
| `tm/ltm/rule` | The TOTP verification iRule and the façade steering rules |
| `tm/ltm/data-group/internal` | The `bigip_mgt_mfa_totp_dg` seed store |
| `tm/apm/resource/portal-access` | One portal resource per unit |
| `tm/apm/resource/portal-access/<name>/items` | **Reading back** nested item fields — see the warning below |
| `tm/apm/sso/form-based` | The form-SSO profile injected into TMUI |
| `tm/apm/policy/agent/*`, `tm/apm/policy/policy-item` | The policy graph |
| `tm/auth/ldap`, `tm/auth/remote-role`, `tm/auth/source` | Per-unit system authentication |
| `tm/util/bash` | The few `tmsh` commands REST cannot express |

**Reading nested fields.** The parent `portal-access` object reports `items[].sso` and
`items[].headers` as `null` even when they are correctly set. Only the `/items`
sub-collection is truthful. Reading the parent produces a convincing false alarm — it has
caused two incorrect diagnoses in this repository, and `validate.sh` now reads the
sub-collection for exactly that reason.

**`items` is an array.** Objects are created with `items` as an array of entries each
carrying a `name`, which is the shape F5's own tooling uses. In that form a nested `sso` is
accepted by a plain REST create. Passed as an object keyed by item name it is silently
dropped, with a `200` returned.

**Not everything is settable over REST.** `headers` on a portal item is rejected in every
shape tried and is set with `tmsh`. `caption` is not settable at all — refused on PATCH,
ignored on create, absent from the tmsh property list.

**`tmsh create` is not idempotent.** It keeps an existing object and reports success, so
configuration changes are ignored silently. Objects that must converge — `apm aaa ldap`, the
policy graph — are deleted and recreated.

### APM data plane

Base: `https://<MFA_WEBTOP_FQDN>/`, resolving to `MFA_APM_VIP`.

| Path | Method | Purpose |
|---|---|---|
| `/` | GET | Starts a session; redirects to the policy |
| `/my.policy` | GET | Serves the logon page |
| `/my.policy` | POST | Submits `username`, `password`, `otp`, `vhost=standard` |
| `/vdesk/webtop.eui` | GET | The webtop, once the policy reaches Allow |
| `/f5-w-<encoded>$$/` | GET | A rewritten portal resource — opening one triggers form SSO |

`scripts/test-mfa-matrix.sh` drives exactly this sequence, which is why it can catch failures
that configuration checks cannot.

## Status codes

**iControl REST**

| Code | Meaning here |
|---|---|
| `200` / `201` | Success |
| `400` | Malformed body, or a property that is not settable on this object |
| `401` | Bad credentials — or `restjavad` restarting. Treated as transient and retried |
| `404` | Object absent. Expected during teardown, which tolerates it |
| `409` | Already exists. Tolerated for additive creates |
| `500` / `502` | Management plane under load or restarting. Retried with a backoff |

A `502` arrives as an HTML proxy-error page rather than JSON, so a naive `jq` parse yields
nothing rather than failing loudly.

**APM data plane**

| Code | Meaning here |
|---|---|
| `302` | Normal — the front door redirecting into the policy |
| `200` | The logon page, the webtop, or a Deny page. The body distinguishes them |
| `000` | Nothing answered: the VIP is unreachable from where the check ran, or the policy is not applied |

Note that a denied login also returns `200`. Status codes cannot tell you whether
authentication succeeded; the response body has to be inspected.

## Content types

- iControl REST: `application/json` throughout, except certificate uploads, which use
  `application/octet-stream` with a `Content-Range` header.
- `tm/util/bash`: JSON in, with the command in `utilCmdArgs`; the result arrives as a string
  in `commandResult`. **`tmsh` errors are returned inside that string with HTTP 200**, so a
  caller that only checks the status code sees success. `bash_cmd` inspects the text.
- APM data plane: `application/x-www-form-urlencoded` for the logon POST; HTML back.

## Related

- [configuration.md](configuration.md) — the environment that parameterises all of this
- [cli.md](cli.md) — the scripts that make these calls
- [../operations/troubleshooting.md](../operations/troubleshooting.md) — what the failures look like
