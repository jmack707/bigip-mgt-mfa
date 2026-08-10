# 0006 — Encrypt seeds at rest and enforce RFC 6238 verifier behaviour

## Status
Accepted. Extends [0002](0002-verify-totp-on-the-bigip.md), which put TOTP verification on
the BIG-IP; this records how the seed store and the verifier were hardened once the design
was pointed at anything less disposable than a demo.

## Context
Two findings from reviewing the original implementation, both of the class that works
perfectly and is wrong.

**The seed store was plaintext configuration.** A data group is ordinary config: it lands in
`bigip.conf`, in every UCS archive, in every qkview, and on the config-sync wire. A TOTP seed
is credential-equivalent — whoever reads it can mint valid codes forever — so the original
plaintext records handed every user's second factor to anyone who could read a backup, a
tech-support upload, or the config with a read-only role. Hashing is not an option: unlike a
password, the verifier needs the raw secret to compute the HMAC.

**The verifier compared codes and did nothing else.** RFC 6238 §5.2 obliges a verifier to
refuse a code's second use and to throttle guessing; the rule did neither. A shoulder-surfed
or phished code stayed usable for the full three-minute acceptance window, and nothing
bounded brute force against a space of only 10⁶ codes — six digits are only an adequate
secret while attempts are bounded. The rule also decoded base32 permissively (an invalid
character was skipped, so a corrupted record failed as "wrong code", pointing investigation
at the user's phone instead of the record) and logged nothing, so a guessing campaign was
invisible.

## Decision
**Seeds are AES-256-CBC encrypted before they reach the appliance.** `bigip/apm-build.sh`
mints a key once into `certs/seed-key.hex` (gitignored, mode 600), encrypts each seed with a
fresh IV, and writes records as `v2:<iv-hex>:<ciphertext-base64>`. The key is rendered into
the verification iRule the same way the period and skew already were, and records and rule
are rebuilt together on every run so they cannot disagree. The iRule fails closed on any
record not in the `v2` shape — including a legacy plaintext one, which would otherwise
quietly reopen the hole.

**The verifier enforces the RFC's obligations.** A successful step is remembered in the
session table, keyed by user and counter for exactly the acceptance window's width, and a
second presentation is denied as a replay. Consecutive failures (wrong codes and replays
both) are counted; at `MFA_TOTP_MAX_FAILURES` (default 5) the user's second factor is
refused for `MFA_TOTP_LOCKOUT_SECONDS` (default 300), and a success clears the counter.
Input must be exactly six digits before any crypto runs — but a malformed submission is not
counted, so junk cannot lock a user out. Base32 decoding is strict, requires the RFC 4226
minimum of 16 decoded bytes, and a bad seed is reported as `bad-seed`, not as a mismatch.
Every denial and every verification is logged to `local0` with username and client IP —
never with the code or the seed.

## Consequences

**Backups stop being a seed database.** UCS archives, qkviews, config-sync captures and
config read access now see ciphertext. The boundary is stated honestly: an administrator who
can read both the data group and the iRule holds the key and the records and can recover
seeds. What moved is the exposure surface — the many places configuration travels — not the
trust placed in the appliance itself. `certs/totp-seeds.env` on the deploy host remains
plaintext and remains the most sensitive file in the deployment.

**A replayed code is now a denial, and the matrix asserts it.** `test-mfa-matrix.sh` submits
alice's just-accepted code a second time and expects DENY. The corollary: running the matrix
twice within one code period shows the two GRANT cases denied as replays — the protection
demonstrating itself, and the reason the script generates each user's code once per run.

**Lockout is recover-by-waiting.** The failure counter lives in the session table with the
lockout window as its lifetime; there is no reset procedure to document because there is
nothing to reset. The cost is that a demo audience mashing wrong codes five times waits five
minutes, which is the correct trade everywhere except a stage — lower
`MFA_TOTP_LOCKOUT_SECONDS` for a live talk.

**Key loss is recoverable, key rotation is cheap.** The key file and the data group are
rebuilt from `certs/totp-seeds.env` on every `./deploy.sh --bigip`, so deleting
`certs/seed-key.hex` rotates the key on the next run with no re-enrolment. Losing the whole
deploy host loses the seeds file too, and that was already a re-enrolment event.

**The session table is per-unit state.** Replay markers and failure counters live on the
unit that verified, and do not config-sync. A failover therefore forgets in-flight counters
and used-step markers — acceptable for a demo, worth knowing before calling this design
production-grade on a pair.
