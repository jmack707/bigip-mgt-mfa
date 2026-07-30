# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
