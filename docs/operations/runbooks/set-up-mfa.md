# Runbook: set up MFA (TOTP)

_Last validated: 2026-07-31_

## When to use this
- Standing up bigip-mgt-mfa for the first time and you need users able to log in.
- Adding a new user to an existing deployment.
- Replacing a user's token because they lost their phone, or revoking one when they leave.

The BIG-IP verifies the one-time code itself. There is no MFA server to install and nothing
external to reach at login time — see [../../adr/0002-verify-totp-on-the-bigip.md](../../adr/0002-verify-totp-on-the-bigip.md)
for why, and for what that trades away.

## Prerequisites
- The stack is up (`./deploy.sh --stack`) and the user exists in the directory. Enrolment
  does not create directory accounts; it only issues a token to a name that already exists.
- `openssl` on the machine you run this from, and `qrencode` if you want a scannable code.
- Access to `./deploy.sh --bigip`, since the seed only takes effect once it reaches the pair.
- The BIG-IPs have working NTP. Verification allows one 30-second step either side; drift
  beyond that rejects every code and looks exactly like a wrong password.

## Procedure

**1. Issue the token.**

```bash
./scripts/enroll-totp.sh alice.admin bob.user
```

This generates a 20-byte base32 seed per user, records it in `certs/totp-seeds.env` (mode
600, gitignored), and prints both a QR code and the setup key. Re-running for a user replaces
their existing token.

**2. Enrol the authenticator.** Scan the QR with Google Authenticator, FreeOTP, 1Password or
any TOTP app. If the QR will not scan — it often will not over a screenshare or a chat client
— use *Enter a setup key* instead and type the key. The parameters are the defaults: 6
digits, 30 seconds, SHA1.

**3. Push the seeds to the pair.**

```bash
./deploy.sh --bigip
```

Nothing works until this runs. It loads the seeds into the `bigip_mgt_mfa_totp_dg` data group,
installs the verification iRule, rebuilds the access policy, and config-syncs to the peer.

**4. Log in.** Browse to the webtop VIP and fill in all three fields on the single logon page:
username, password, and the current code.

## Verification

```bash
./scripts/enroll-totp.sh --list          # who holds a token
./scripts/test-mfa-matrix.sh             # the full accept/deny matrix
```

The matrix is the real check. It asserts that a correct password with the user's own code is
granted, and — importantly — that a correct password paired with *another user's* code is
denied. That second case is the one a hand test never thinks to try, and it is the exact flaw
an earlier design shipped with.

To confirm a seed actually reached the appliance:

```bash
tmsh list ltm data-group internal bigip_mgt_mfa_totp_dg
```

## Rollback

Revoke a single token and push the change:

```bash
./scripts/enroll-totp.sh --revoke bob.user
./deploy.sh --bigip
```

The user can no longer log in at all: no seed means no token, and the policy treats an absent
token as a denial rather than a skipped factor. Re-enrol them with step 1 to restore access.

To take MFA out of the path entirely — only as an emergency measure, and it leaves the webtop
protected by a password alone — disable the front door instead of weakening the policy:

```bash
tmsh modify ltm virtual bigip-mgt-mfa-vs disabled
```

## Escalation
Codes rejected for everyone, immediately after a working period: check clock drift on the
BIG-IPs first (`tmsh show sys ntp status`). It is the most common cause and the least obvious,
because nothing else on the appliance misbehaves.

Codes rejected for one user only: their app and the stored seed disagree. Re-enrol them.

No user can log in and the logs show the policy ending at Deny from the MFA step: confirm the
data group is populated on the *active* unit, then see
[../troubleshooting.md](../troubleshooting.md).
