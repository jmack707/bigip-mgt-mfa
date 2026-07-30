# Runbook — Reset a user's second factor

A user has lost their authenticator and cannot complete the Keycloak step-up. Delete their OTP
credential so they enrol again on their next login.

_Last validated: 2026-07-30_

## When to use this
- A user's phone or authenticator app is gone, replaced, or wiped, and their TOTP codes are
  rejected.
- Codes are rejected for one user while every other user logs in normally. If *everyone* is
  failing, this is not the runbook — check clock skew on the Keycloak host and the realm's OTP
  policy first, because the realm is `HmacSHA1`/6 digits/30 seconds with a look-ahead window of
  one period, which tolerates very little drift.
- You want a clean enrolment for a demo, with the QR code shown live.

This changes nothing on the BIG-IPs. The password is proven against the directory by APM before
Keycloak is ever reached, and the TMUI role comes from `remote-role`, so a missing second factor
stops the login at the step-up and nothing else. Resetting it does not touch the user's
directory password or their group membership.

## Prerequisites
- The Keycloak master-realm admin credentials from `.env` (`WL_KEYCLOAK_ADMIN`,
  `WL_KEYCLOAK_ADMIN_PW`) and reachability to
  `https://${WL_KEYCLOAK_FQDN}:${WL_KEYCLOAK_PORT}`. The console is at `/admin/`.
- The user's username exactly as the directory holds it — `uid` in bundled mode,
  `sAMAccountName` when `WL_LDAP_SCHEMA=ad`. Keycloak federates the directory read-only, so the
  username is the directory's, not one Keycloak invented.
- For the REST path: `curl` and `jq` on whatever host you run it from.
- Shell access on the Docker host if the user in question is being tested with
  `scripts/demo-login.sh`, so you can clear its cached secret.
- `CONFIGURE_TOTP` is a **default required action** in the realm, so no enable step is needed:
  a user with no OTP credential is prompted to enrol on their next login automatically.

## Procedure
### Admin console
1. Browse to `https://${WL_KEYCLOAK_FQDN}:${WL_KEYCLOAK_PORT}/admin/` and sign in as
   `WL_KEYCLOAK_ADMIN`.
2. Switch the realm selector from `master` to **`warden-lite`** (the value of
   `WL_KEYCLOAK_REALM`). Deleting a credential in `master` does nothing for demo users.
3. **Users** → search the username → open it → **Credentials**.
4. Delete the row of type **`otp`**. Leave everything else alone; the password lives in the
   directory and is not shown here.

The user is prompted to enrol a new authenticator the next time APM steps them up.

### Admin REST API
Equivalent, and scriptable. Run from the Docker host so `.env` and the `--resolve` mapping are
available:

```bash
set -a; . ./.env; set +a
TARGET_USER=alice.admin
KC="https://${WL_KEYCLOAK_FQDN}:${WL_KEYCLOAK_PORT}"
RES=(--resolve "${WL_KEYCLOAK_FQDN}:${WL_KEYCLOAK_PORT}:${WL_HOST_IP}")

TOKEN=$(curl -sk "${RES[@]}" -d client_id=admin-cli -d grant_type=password \
  -d "username=${WL_KEYCLOAK_ADMIN}" --data-urlencode "password=${WL_KEYCLOAK_ADMIN_PW}" \
  "${KC}/realms/master/protocol/openid-connect/token" | jq -r .access_token)

KC_UID=$(curl -sk "${RES[@]}" -H "Authorization: Bearer ${TOKEN}" \
  "${KC}/admin/realms/${WL_KEYCLOAK_REALM}/users?username=${TARGET_USER}&exact=true" | jq -r '.[0].id')

CRED=$(curl -sk "${RES[@]}" -H "Authorization: Bearer ${TOKEN}" \
  "${KC}/admin/realms/${WL_KEYCLOAK_REALM}/users/${KC_UID}/credentials" \
  | jq -r '.[] | select(.type=="otp") | .id')

curl -sk "${RES[@]}" -H "Authorization: Bearer ${TOKEN}" -o /dev/null -w 'delete -> %{http_code}\n' \
  -X DELETE "${KC}/admin/realms/${WL_KEYCLOAK_REALM}/users/${KC_UID}/credentials/${CRED}"
```

Expected: `delete -> 204`. An empty `CRED` means the user has no OTP credential — they will be
asked to enrol on their next login regardless, so there is nothing to do.

### Clear the headless cache
`scripts/demo-login.sh` caches the secret it enrolled under `certs/.totp-<user>` and reuses it
on later runs. After deleting the credential in Keycloak that file is stale, and the script will
post codes derived from a secret Keycloak no longer holds. Delete it so the next run performs a
fresh enrolment and prints the new secret:

```bash
rm -f "certs/.totp-${TARGET_USER}"
```

## Verification
```bash
scripts/demo-login.sh "${TARGET_USER}"
```

Expected: step 4 prints `first login: enrolling TOTP` and a new base32 secret, then completes
through to the webtop. That secret is what you type into a real authenticator app to repeat the
flow by hand in a browser.

Confirm the credential is genuinely gone rather than merely unused:

```bash
curl -sk "${RES[@]}" -H "Authorization: Bearer ${TOKEN}" \
  "${KC}/admin/realms/${WL_KEYCLOAK_REALM}/users/${KC_UID}/credentials" | jq -r '.[].type'
```

Expected: no `otp` line before the user re-enrols, and one afterwards.

## Rollback
Deleting a credential is not reversible — the secret is gone from Keycloak and cannot be
restored from a backup of anything this repo writes. The forward path is enrolment, and it is
self-service: the user logs in, Keycloak presents the QR code because `CONFIGURE_TOTP` is a
default required action, and the login continues.

```bash
# confirm the user can enrol and complete the chain again
rm -f "certs/.totp-${TARGET_USER}"
scripts/demo-login.sh "${TARGET_USER}"
```

If you deleted the wrong user's credential, the remedy is the same: tell them they will be asked
to re-enrol on the next login. Nothing else about their access changed.

## Escalation
- The user enrols successfully but the next login is rejected: this is clock skew, not
  enrolment. Compare the time on the Keycloak host and the user's device — the realm allows one
  30-second look-ahead period and no more.
- Every user is failing the second factor, including a freshly enrolled one: the realm's browser
  flow is `warden-lite second factor` (Username Form then OTP Form, with `auth-cookie`
  deliberately absent so every redirect re-runs OTP). A modified flow or a failed realm import
  presents as a universal failure — check `docker compose logs keycloak` and see
  [../troubleshooting.md](../troubleshooting.md).
- The user never reaches Keycloak at all: the failure is earlier in the chain, at the APM logon
  page or LDAP Auth. Start from [../../deploy.md](../../deploy.md#verification).
- A user who cannot be found in the `warden-lite` realm is a federation problem, not an MFA one:
  Keycloak imports identities read-only from the directory, so the user must exist under
  `WL_USER_SEARCH_BASE` first ([../../directory.md](../../directory.md)).
