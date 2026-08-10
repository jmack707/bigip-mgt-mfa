#!/usr/bin/env bash
# Exercise the single-logon-page flow, including the cross-user binding case that the
# previous redirect-based design silently allowed.
set -uo pipefail
cd ~/bigip-mgt-mfa
set -a; . ./.env; set +a

# The verifier's step is MFA_TOTP_PERIOD, so the test must generate codes on the same step
# or every "correct OTP" case fails for a reason that has nothing to do with the policy.
OATH=(oathtool --totp -b --time-step-size="${MFA_TOTP_PERIOD:-60}s")

WEBTOP="https://${MFA_WEBTOP_FQDN}"
A_SEC=$(grep "^alice.admin=" certs/totp-seeds.env | cut -d= -f2)
B_SEC=$(grep "^bob.user=" certs/totp-seeds.env | cut -d= -f2)

# One code per user for the whole run. The replay case must present the SAME code that was
# just accepted, and the verifier remembers a used step for the width of the acceptance
# window — which also means re-running this script within one code period shows the two
# GRANT cases denied as replays. That is the protection working; wait for the next period.
A_OTP=$("${OATH[@]}" "$A_SEC")
B_OTP=$("${OATH[@]}" "$B_SEC")

try() { # try <label> <user> <password> <otp> <expect: GRANT|DENY>
  local label="$1" user="$2" pw="$3" otp="$4" expect="$5"
  local jar; jar=$(mktemp)
  local C=(-sk -c "$jar" -b "$jar" --resolve "${MFA_WEBTOP_FQDN}:443:${MFA_APM_VIP}")
  curl "${C[@]}" -o /dev/null -m10 "${WEBTOP}/" 2>/dev/null
  curl "${C[@]}" -L -o /dev/null -m10 "${WEBTOP}/my.policy" 2>/dev/null
  local out
  out=$(curl "${C[@]}" -L -m20 -d "username=${user}" --data-urlencode "password=${pw}" \
        -d "otp=${otp}" -d "vhost=standard" "${WEBTOP}/my.policy" 2>/dev/null)
  local got=DENY
  grep -q '"pageType": *"webtop"' <<<"$out" && got=GRANT
  rm -f "$jar"
  if [ "$got" = "$expect" ]; then
    printf '  \033[32mPASS\033[0m  %-46s -> %s\n' "$label" "$got"
  else
    printf '  \033[31mFAIL\033[0m  %-46s -> %s (expected %s)\n' "$label" "$got" "$expect"
  fi
}

echo
echo "=== single logon page: username + password + one-time code ==="
try "alice: correct pw + her own OTP"      alice.admin "$MFA_PW_ALICE" "$A_OTP" GRANT
try "bob:   correct pw + his own OTP"      bob.user    "$MFA_PW_BOB"   "$B_OTP" GRANT
echo
echo "=== the cases that must fail ==="
try "alice: her JUST-USED OTP replayed"    alice.admin "$MFA_PW_ALICE" "$A_OTP" DENY
try "alice: correct pw + BOB's OTP"        alice.admin "$MFA_PW_ALICE" "$B_OTP" DENY
try "alice: correct pw + wrong OTP"        alice.admin "$MFA_PW_ALICE" "000000"                          DENY
try "alice: WRONG pw + her own OTP"        alice.admin "not-her-password" "$A_OTP"  DENY
try "alice: correct pw + NO OTP"           alice.admin "$MFA_PW_ALICE" ""                                DENY
try "alice: BOB'S password + her own OTP"  alice.admin "$MFA_PW_BOB"   "$A_OTP" DENY
try "unknown user"                         mallory     "whatever"         "123456"                          DENY
