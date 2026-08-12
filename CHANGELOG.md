# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- `scripts/validate.sh` and `scripts/test-mfa-matrix.sh` can run back to back again. The SSO
  probe performs a real login, and with codes now single-use that spent `alice.admin`'s code
  for the whole time step — the matrix, run next, reported its own GRANT case as
  `DENY (expected GRANT)`. The probe now picks a principal the matrix does not grant
  (`carol.netops`, else `dave.audit`, falling back to `alice.admin` only if neither is
  enrolled); `MFA_SSO_TEST_USER` still overrides.
- **The webtop tile works on a single BIG-IP.** The façade virtual was built with SNAT
  `automap`, which picks a self IP on the egress VLAN — on a standalone unit (and on the
  standby half of a pair) the only address there is the `node` target itself, and TMM will not
  complete a connection whose source equals its destination. The tile completed its TLS
  handshake with the façade and then reset after ten seconds (`PR_CONNECT_RESET_ERROR`) while
  every configured object, and `validate.sh`, read as correct. `bigip/apm-build.sh` now pins
  the source with a dedicated SNAT pool (`MFA_FACADE_SNAT_ADDR`, default `.240` on
  `BIGIP_A_TMUI`'s subnet) — **one configuration for standalone and HA alike** — and PATCHes
  the pool member and each virtual on every run so existing deployments converge. See
  [ADR 0007](docs/adr/0007-facade-source-address.md).
- `scripts/validate.sh` **drives** each façade — one `/util/bash` call fetches TMUI's login
  page through `192.0.2.5`/`.6` from the appliance — instead of only asserting that the portal
  resource, its SSO and the façade virtual exist. All of those passed on a deployment whose
  tile could not open at all.

### Security
- **TOTP seeds are encrypted at rest on the BIG-IP.** Data-group records are now
  `v2:<iv>:<ciphertext>` — AES-256-CBC under a key minted into `certs/seed-key.hex` and
  rendered into the verification iRule — so `bigip.conf`, UCS archives, qkviews and the
  config-sync wire carry ciphertext instead of every user's second factor. The verifier
  fails closed on any record not in that shape, legacy plaintext included. See
  [ADR 0006](docs/adr/0006-encrypt-seeds-and-enforce-verifier-behaviour.md).
- **The verifier now meets RFC 6238 §5.2.** A code is single-use — a replay within the
  acceptance window is denied — and guessing is throttled: `MFA_TOTP_MAX_FAILURES`
  consecutive failures (default 5) lock the user's second factor for
  `MFA_TOTP_LOCKOUT_SECONDS` (default 300), cleared by a successful verification.
- **The verifier validates its inputs and logs its denials.** Codes must be exactly six
  digits before any crypto runs (malformed input is denied but not counted toward lockout);
  base32 decoding is strict, requires ≥ 16 decoded bytes, and reports a corrupted record as
  `bad-seed` rather than as a code mismatch; every denial and verification is logged to
  `local0` with username and client IP — never the code or the seed.
- `scripts/test-mfa-matrix.sh` asserts the replay denial: alice's just-accepted code,
  submitted again, must be denied.

### Changed
- **The second BIG-IP is optional everywhere.** `BIGIP_B_MGMT` was already skipped by
  `deploy.sh`, `teardown.sh` and `scripts/validate.sh`, but `bigip/apm-build.sh` still built
  unit B's façade virtual, `node` iRule, portal resource and webtop tile unconditionally, and
  the validator still demanded two portal resources. All of that now follows `.env`: one
  configured unit means one tile and one of everything behind it.
- `scripts/lib/units.sh` is the single source of truth for how many units a deployment has
  (`mfa_have_peer`, `mfa_units`, `mfa_unit_count`), sourced by all four entry points. An
  leftover quoted sample value such as `"<bigip-b-mgmt-ip>"` counts as unset.
- `.env.example` ships `BIGIP_B_MGMT` and `BIGIP_B_TMUI` blank, so a copied file is a
  single-unit deployment until you say otherwise.

### Fixed
- **`scripts/validate.sh` re-probes each unit before its own checks**
  ([issue #4](https://github.com/jmack707/bigip-mgt-mfa/issues/4)), instead of
  probing once at the top. A unit whose `restjavad` wedges mid-run is now reported as `SKIP`
  with the reason rather than as a wall of configuration failures, and one wedged unit no
  longer suppresses a healthy peer's results.
- Far fewer `/mgmt/tm/util/bash` calls, the expensive shape — it forks a shell and loads
  `tmsh` on the appliance. The role checks fire all four logins, wait once, and read the audit
  log **once per unit** (a pair: 8 calls → 2, and three of four waits gone);
  `bigip/apm-build.sh` batches the per-portal `headers` commands into one call and folds the
  traffic-group modify together with `save sys config` (a pair: 7 → 5).
- `scripts/validate.sh` no longer fails two BIG-IPs that are not in a sync-failover device
  group with `access profile NOT on B — run a config-sync`. That configuration works and has
  nothing to sync to, so the peer-sync assertion is now gated on the device group — the same
  discovery `deploy.sh` uses — rather than on `BIGIP_B_MGMT` being set.

### Added
- `bigip/apm-build.sh` refuses `BIGIP_B_MGMT` set without `BIGIP_B_TMUI` rather than
  publishing a webtop tile with nothing behind it.
- Removing a peer converges: with `BIGIP_B_MGMT` cleared, the next `./deploy.sh --bigip`
  deletes unit B's portal resource, façade virtual server and `node` iRule.

## [0.1.0] — 2026-07-30

First working release. Validated end to end against a BIG-IP 21.1.0 HA pair.

### Added
- APM access policy: logon page, LDAP authentication, OIDC step-up to Keycloak for TOTP,
  webtop, and form SSO into the TMUI of both units of an HA pair.
- Keycloak realm with a second-factor-only browser flow (username form then OTP form) and
  read-only federation of the same directory APM authenticates against.
- `remote-role` configuration on both units so directory group membership decides
  Administrator versus read-only Guest.
- Bundled OpenLDAP with two demo principals differing only in admin-group membership, plus
  an `external` mode for Active Directory, FreeIPA, or any LDAP.
- CoreDNS in the stack, because a TMOS `dns-resolver` cannot read a hosts file and the demo
  must not depend on DNS you may not be permitted to edit.
- `deploy.sh` with separable `--stack` and `--bigip` halves.
- `scripts/validate.sh` — 26 assertions covering containers, DNS, directory, Keycloak, the
  APM objects on both units, the role each demo user actually receives, and the VIP.
- `scripts/demo-login.sh` — walks the entire login chain headlessly including TOTP
  enrolment and verification.
