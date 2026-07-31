#!/usr/bin/env bash
# Per-unit remote authentication + authorization. Run against EACH unit of the pair.
#
# This is the half of the demo that makes alice an administrator and bob read-only. APM
# does not decide it and Keycloak does not decide it — the target BIG-IP does, by binding
# the credential APM single-signed-on and evaluating remote-role against the directory.
# That is what keeps the story honest: the access tier can be bypassed and the answer is
# still the same. See docs/adr/0003-authorization-on-remote-role.md.
#
# RUN ON BOTH UNITS. `auth ldap system-auth` and `auth source` are device-local: a
# config-sync does NOT carry them to the peer. (`auth remote-role` DOES sync — verified by
# creating one on A alone and watching it appear on B — but a synced rule is useless on a
# unit that has no LDAP server configured and is still authenticating locally.) Configure
# only the active unit and the demo works until the first failover, then every login fails
# on the new active unit.
#
# SAFETY: admin/root remain LOCAL accounts on TMOS. Switching the auth source to ldap
# cannot lock you out of the box.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
_PASS_IN="${BIGIP_PASS:-}"; set -a; . "${HERE}/../.env"; set +a
# shellcheck disable=SC1091
. "${HERE}/../scripts/lib/directory.sh"
[ -n "$_PASS_IN" ] && BIGIP_PASS="$_PASS_IN"
: "${BIGIP_PASS:?export BIGIP_PASS}"
: "${BIGIP_MGMT:?set BIGIP_MGMT (deploy.sh sets it per unit)}"

B="https://${BIGIP_MGMT}"
AUTH=(-sk -u "${BIGIP_USER}:${BIGIP_PASS}")
case "${WL_LDAP_CA_FILE}" in /*) CA="${WL_LDAP_CA_FILE}";; *) CA="${HERE}/../${WL_LDAP_CA_FILE}";; esac
[ -f "$CA" ] || { echo "directory CA not found: $CA (set WL_LDAP_CA_FILE)" >&2; exit 1; }

jqok(){ jq -e "$1" >/dev/null 2>&1; }
req(){ # req METHOD URL [JSON]
  local m="$1" url="$2" body="${3:-}" out code
  if [ -n "$body" ]; then
    out="$(curl "${AUTH[@]}" -w '\n%{http_code}' -X "$m" -H 'Content-Type: application/json' -d "$body" "$url")" \
      || { echo "no HTTP response from ${url#$B} — is ${BIGIP_MGMT}:443 reachable?" >&2; exit 1; }
  else
    out="$(curl "${AUTH[@]}" -w '\n%{http_code}' -X "$m" "$url")" || exit 1
  fi
  code="$(tail -n1 <<<"$out")"; body="$(sed '$d' <<<"$out")"
  echo "    HTTP $code  ${url#$B}" >&2
  [ "$code" -lt 400 ] || { { echo "$body" | jq . 2>/dev/null || echo "$body"; } >&2; exit 1; }
  echo "$body"
}

# 1. trust anchor for LDAPS. Create-or-UPDATE: on re-deploy an existing object still holds
#    the OLD CA and stale trust fails closed.
sz=$(stat -c%s "$CA")
curl "${AUTH[@]}" -X POST -H "Content-Type: application/octet-stream" \
  -H "Content-Range: 0-$((sz-1))/${sz}" --data-binary @"$CA" \
  "$B/mgmt/shared/file-transfer/uploads/${WL_LDAP_CA_NAME}" -o /dev/null -w '    CA upload HTTP %{http_code}\n'
if curl "${AUTH[@]}" "$B/mgmt/tm/sys/file/ssl-cert/${WL_LDAP_CA_NAME}" | jqok '.name'; then
  req PATCH "$B/mgmt/tm/sys/file/ssl-cert/${WL_LDAP_CA_NAME}" \
    "{\"sourcePath\":\"file:/var/config/rest/downloads/${WL_LDAP_CA_NAME}\"}" >/dev/null
else
  req POST "$B/mgmt/tm/sys/file/ssl-cert" \
    "{\"name\":\"${WL_LDAP_CA_NAME}\",\"sourcePath\":\"file:/var/config/rest/downloads/${WL_LDAP_CA_NAME}\"}" >/dev/null
fi

# 2. auth ldap system-auth — how the unit resolves a remote user and reads its groups.
LDAP_BODY="$(jq -n \
  --arg srv "${WL_LDAP_HOST}" --argjson port "${WL_LDAPS_PORT}" \
  --arg ca "${WL_LDAP_CA_NAME}" --arg bdn "${WL_BIND_DN}" --arg bpw "${WL_BIND_PW}" \
  --arg sbd "${WL_USER_SEARCH_BASE}" --arg la "${WL_LOGIN_ATTR}" \
  '{name:"system-auth",servers:[$srv],port:$port,ssl:"enabled",
    sslCaCertFile:$ca,bindDn:$bdn,bindPw:$bpw,
    searchBaseDn:$sbd,loginAttribute:$la,
    checkRolesGroup:"enabled"}')"
# checkRolesGroup MUST stay enabled: it is what makes TMOS consult the remote-role rules at
# all. Disabled, the rules are ignored and EVERY remote user — alice included — lands on the
# default role, which silently deletes the authorization half of the demo. Users who match
# no rule still fall through to the default role below, so "everyone else is read-only"
# holds either way; only the elevation depends on this flag.
if curl "${AUTH[@]}" "$B/mgmt/tm/auth/ldap/system-auth" | jqok '.name'; then
  req PATCH "$B/mgmt/tm/auth/ldap/system-auth" "$LDAP_BODY" >/dev/null
else
  req POST  "$B/mgmt/tm/auth/ldap" "$LDAP_BODY" >/dev/null
fi

# 3. everyone who authenticates but matches no role gets guest (read-only), no console.
#    This is bob's outcome, and it is a default rather than a rule — nothing about bob is
#    configured anywhere.
req PATCH "$B/mgmt/tm/auth/remote-user" \
  '{"defaultRole":"guest","remoteConsoleAccess":"disabled"}' >/dev/null

# 4. the one rule: members of the admin group are elevated to administrator. This is alice.
RR_BODY="$(jq -n --arg a "${WL_ADMIN_ROLE_ATTRIBUTE}" \
  '{name:"warden_lite_admins",attribute:$a,role:"administrator",userPartition:"All",console:"tmsh",lineOrder:1}')"
if curl "${AUTH[@]}" "$B/mgmt/tm/auth/remote-role/role-info/warden_lite_admins" | jqok '.name'; then
  req PATCH "$B/mgmt/tm/auth/remote-role/role-info/warden_lite_admins" "$RR_BODY" >/dev/null
else
  req POST  "$B/mgmt/tm/auth/remote-role/role-info" "$RR_BODY" >/dev/null
fi

# 5. switch the auth source. admin/root stay local.
req PATCH "$B/mgmt/tm/auth/source" '{"type":"ldap"}' >/dev/null

# Retry the save. Everything above is already live in the running config; this only
# persists it. mcpd intermittently refuses the connection right after an auth-source change
# and returns 500 "Connection refused" -- letting that abort the whole deploy (as `set -e`
# would) throws away work that actually succeeded.
saved=0
for attempt in 1 2 3 4 5; do
  code=$(curl "${AUTH[@]}" -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
         -d '{"command":"save"}' "$B/mgmt/tm/sys/config" || echo 000)
  if [ "$code" = 200 ]; then saved=1; break; fi
  echo "    save attempt ${attempt} -> ${code}, retrying" >&2
  sleep 6
done
[ "$saved" = 1 ] || echo "    WARNING: config is live but was not saved to disk on ${BIGIP_MGMT}" >&2
echo "    ${BIGIP_MGMT}: remote auth -> ${WL_LDAP_HOST}, admins = ${WL_ADMIN_ROLE_ATTRIBUTE}"
