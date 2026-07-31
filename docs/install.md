# Install

_Last validated: 2026-07_

Stand up the Docker half: the demo CA, CoreDNS, and — in bundled mode — the demo directory.
This touches no BIG-IP. Prove it works before pointing anything at your appliances; the
access tier is [deploy.md](deploy.md).

## Prerequisites

- A Linux host with Docker and the **`docker compose` v2 plugin** (`docker compose version`
  must work; the standalone `docker-compose` v1 binary is not enough).
- `openssl`, `jq`, `envsubst` (in `gettext-base`), `curl`. For enrolment and testing also
  `qrencode` and `oathtool`; for the validation script, `dig` and `ldap-utils`.
- Free host ports: **53/udp and 53/tcp** for CoreDNS, and **389/636** for the bundled
  directory. Most Linux hosts already run a stub resolver on `127.0.0.53`, which is why
  CoreDNS binds `MFA_HOST_IP` rather than the wildcard.
- The host must be reachable from the BIG-IP on those ports — the appliance authenticates
  against this directory.

## Procedure

**1. Configure.**

```bash
cp .env.example .env
```

Edit it. The values that must be right for anything to work:

| Key | What it is |
|---|---|
| `MFA_HOST_IP` | This host's address on the network the BIG-IP can reach. Every certificate SAN and the CoreDNS bind address come from it |
| `MFA_DOMAIN` | The demo DNS zone CoreDNS will be authoritative for |
| `MFA_WEBTOP_FQDN` / `MFA_APM_VIP` | The name and address of the APM virtual server |
| `MFA_LDAP_ADMIN_PW`, `MFA_BIND_PW`, `MFA_TEST_USER_PW` | Directory passwords. Change them |
| `MFA_DIRECTORY_MODE` | `bundled` ships a directory; `external` uses your own AD or LDAP |

If you are using your own directory, read [directory.md](directory.md) first and validate it
with `scripts/preflight-directory.sh` before going further.

**2. Bring up the stack.**

```bash
./deploy.sh --stack
```

In order, this: reuses or mints the demo CA; issues the webtop certificate (and the LDAPS
certificate in bundled mode); renders the CoreDNS zone; starts the containers; and — in
bundled mode — applies the `memberof` overlay, the bind-account ACL, and seeds the demo
principals.

The overlay must land **before** the group is created, because `memberOf` is only computed
for changes made after it is active. The script does this in the right order; doing it by
hand in the other order silently produces a directory in which nobody is an administrator.

**3. Enrol at least one user.**

```bash
./scripts/enroll-totp.sh alice.admin bob.user
```

This mints a seed per user and prints a QR code and a setup key. It writes
`certs/totp-seeds.env` (mode 600, gitignored) and **does not touch the BIG-IP** — the seeds
reach the appliance in [deploy.md](deploy.md).

> Google Authenticator ignores the period in the QR and always produces 30-second codes. The
> default `MFA_TOTP_PERIOD` is 60, so use FreeOTP, Aegis or 1Password — or set 30.

**4. Trust the CA** in whatever browser will open the webtop: import `certs/ca.crt`. Until
you do, the webtop shows a certificate warning.

**5. Resolve the demo names.** Either point the workstation's DNS at this host, or add a
hosts entry:

```text
<MFA_APM_VIP>   <MFA_WEBTOP_FQDN>
```

A hosts entry covers the browser only. It cannot cover the BIG-IP, which resolves names in
TMM and never reads its own hosts file — that is why CoreDNS ships here.

## Verification

```bash
docker compose ps                       # containers up
dig +short @<MFA_HOST_IP> <MFA_WEBTOP_FQDN>
```

In bundled mode, confirm the directory answers and that group membership actually computed —
this is the assertion worth making, because an empty `memberOf` is silent:

```bash
ldapsearch -x -H ldap://<MFA_HOST_IP>:389 \
  -D "<MFA_BIND_DN>" -w "<MFA_BIND_PW>" \
  -b "<MFA_USER_SEARCH_BASE>" "(uid=alice.admin)" memberOf
```

You want a `memberOf` naming the admin group. If it is absent, the overlay was applied after
the group; drop the volumes and re-run rather than patching by hand.

## Uninstall

```bash
./teardown.sh --stack            # stop and remove the containers
./teardown.sh --stack --volumes  # also drop the directory data and cached seeds
```

`--volumes` destroys the directory contents and the enrolled TOTP seeds. Without it, a
subsequent `--stack` deploy reuses both.
