#!/usr/bin/env bash
# Enrol a user's soft token (Google Authenticator, FreeOTP, 1Password, ...).
#
# Generates a random base32 seed, records it in certs/totp-seeds.env, and prints both a
# scannable QR code and the seed for manual entry. `./deploy.sh --bigip` then loads the
# seeds into the BIG-IP data group the verification iRule reads.
#
# This is the piece a commercial MFA product would give you as a self-service portal. It is
# a script here because bigip-mgt-mfa deliberately has no MFA server -- see
# docs/adr/0002-verify-totp-on-the-bigip.md for what that buys and what it costs.
#
# Usage:  scripts/enroll-totp.sh <username> [<username> ...]
#         scripts/enroll-totp.sh --list
#         scripts/enroll-totp.sh --revoke <username>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "${HERE}/../.env"; set +a
SEEDS="${HERE}/../certs/totp-seeds.env"
ISSUER="${MFA_TOTP_ISSUER:-bigip-mgt-mfa}"
PERIOD="${MFA_TOTP_PERIOD:-60}"
mkdir -p "${HERE}/../certs"; touch "$SEEDS"; chmod 600 "$SEEDS"

die(){ printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

case "${1:-}" in
  --list)
    printf '%-24s %s\n' "USER" "ENROLLED"
    while IFS='=' read -r u s; do
      [ -z "$u" ] && continue
      case "$u" in \#*) continue;; esac
      printf '%-24s %s\n' "$u" "yes (${#s} chars)"
    done < "$SEEDS"
    exit 0;;
  --revoke)
    [ -n "${2:-}" ] || die "usage: $0 --revoke <username>"
    grep -v "^${2}=" "$SEEDS" > "${SEEDS}.new" || true
    mv "${SEEDS}.new" "$SEEDS"; chmod 600 "$SEEDS"
    echo "revoked ${2} — re-run ./deploy.sh --bigip to push the change to the pair"
    exit 0;;
  ""|-h|--help) die "usage: $0 <username> [<username> ...] | --list | --revoke <user>";;
esac

command -v openssl >/dev/null || die "needs openssl"
have_qr=1; command -v qrencode >/dev/null 2>&1 || have_qr=0

for user in "$@"; do
  # 20 random bytes, base32 with the padding stripped — what every authenticator expects.
  seed=$(openssl rand 20 | base32 | tr -d '=\n')
  grep -v "^${user}=" "$SEEDS" > "${SEEDS}.new" 2>/dev/null || true
  mv "${SEEDS}.new" "$SEEDS" 2>/dev/null || true
  printf '%s=%s\n' "$user" "$seed" >> "$SEEDS"
  chmod 600 "$SEEDS"

  uri="otpauth://totp/${ISSUER}:${user}?secret=${seed}&issuer=${ISSUER}&algorithm=SHA1&digits=6&period=${PERIOD}"
  printf '\n\033[36m== %s ==\033[0m\n' "$user"
  if [ "$have_qr" = 1 ]; then
    qrencode -t ANSIUTF8 "$uri"
  else
    echo "  (install qrencode to print a scannable code)"
  fi
  echo "  setup key : $seed"
  echo "  type      : time-based, 6 digits, ${PERIOD}s, SHA1"
  # An `if`, not `[ ] && echo`: under `set -e` a false test makes the compound command return
  # non-zero and kills the script -- and it would do so only when the period IS 30, i.e. on
  # the default path.
  if [ "$PERIOD" != 30 ]; then
    echo "  NOTE      : Google Authenticator IGNORES a non-30s period and will keep showing"
    echo "              30-second codes, which will never match. Use FreeOTP, Aegis or"
    echo "              1Password -- all of which honour the period in the QR."
  fi
done

printf '\n%s\n' "Seeds written to certs/totp-seeds.env (gitignored, mode 600)."
echo "Now run:  ./deploy.sh --bigip     # loads them into the BIG-IP and syncs to the peer"
