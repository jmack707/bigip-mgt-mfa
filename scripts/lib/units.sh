# units.sh — source this AFTER .env. Single source of truth for "how many BIG-IPs is this
# deployment made of", so no script has to answer that question for itself.
#
# ONE unit is a first-class deployment. An HA pair makes the failover story real, but most
# UDF blueprints and most home labs hand you a single BIG-IP, and nothing about MFA at the
# management edge needs two. So every per-unit loop, the webtop tile list, the validator's
# expected counts and the teardown iterate what is CONFIGURED rather than assuming a pair.
#
# `BIGIP_B_MGMT` is the one switch. Set it (with `BIGIP_B_TMUI`) for a pair; leave it blank
# for a single unit.

# mfa_is_placeholder <value> — true for empty, or for an unedited `<angle-bracket>` sample
# from .env.example. A placeholder is not an address: treated as configured it produces a
# webtop tile that hangs and a system-auth run against a name that does not resolve, both of
# which look like BIG-IP faults rather than an unfinished .env.
mfa_is_placeholder() { case "${1:-}" in ''|'<'*'>') return 0 ;; *) return 1 ;; esac; }

# mfa_have_peer — is a second BIG-IP configured?
mfa_have_peer() { ! mfa_is_placeholder "${BIGIP_B_MGMT:-}"; }

# mfa_units — the configured management addresses, one per line: A, then B if there is one.
mfa_units() {
  printf '%s\n' "${BIGIP_A_MGMT}"
  mfa_have_peer && printf '%s\n' "${BIGIP_B_MGMT}"
  return 0
}

# mfa_unit_count — 1 or 2.
mfa_unit_count() { mfa_have_peer && echo 2 || echo 1; }

# mfa_require_peer_tmui — refuse a half-declared peer. B's TMUI tile needs B's non-floating
# self IP, and a missing one would otherwise surface much later as a tile that opens onto
# nothing, with no error anywhere in the build.
mfa_require_peer_tmui() {
  mfa_have_peer || return 0
  if mfa_is_placeholder "${BIGIP_B_TMUI:-}"; then
    echo "error: BIGIP_B_MGMT is set but BIGIP_B_TMUI is not. Set B's non-floating internal" >&2
    echo "       self IP, or clear BIGIP_B_MGMT for a single-unit deployment." >&2
    return 1
  fi
  return 0
}

# mfa_units_summary — one line, for the deploy/teardown banner.
mfa_units_summary() {
  if mfa_have_peer; then
    echo "BIG-IPs: A ${BIGIP_A_MGMT}, B ${BIGIP_B_MGMT} (pair)"
  else
    echo "BIG-IPs: A ${BIGIP_A_MGMT} (single unit — BIGIP_B_MGMT not set)"
  fi
}
