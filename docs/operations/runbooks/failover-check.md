# Runbook — Prove the webtop survives a failover

Force a failover and confirm three things still hold on the newly-active unit: the VIP answers,
the login chain completes, and alice is still elevated to Administrator while bob is still
read-only.

_Last validated: 2026-07-30_

## When to use this
- After any `./deploy.sh --bigip`, and after any change to system authentication on **either**
  unit. `auth ldap`, `remote-role` and `auth source` are device-local and are not carried by
  config-sync, so a change applied to one unit leaves the pair asymmetric with no error
  anywhere.
- Before demoing to anyone, because this is the check that catches the classic mistake: the
  build was run against A only, everything passes, and at the first failover every remote user
  silently lands on the default read-only role.
- After a TMOS upgrade, a licence change, or any unplanned failover, to confirm the pair came
  back symmetric.

`scripts/validate.sh` already asserts `remote-role`, `auth source` and the default role on both
units, and probes both users' roles against both units. That is the cheap version and it should
be green first. This runbook is the expensive version: it proves the *data plane* moves too.

## Prerequisites
- Both units reachable on `443` from the Docker host, `BIGIP_PASS` available, and the stack up.
- The pair genuinely in HA: a sync-failover device group, `In Sync`, both units `Active` or
  `Standby` rather than `Offline` or `Forced Offline`.
- A window in which traffic can move. Forcing standby drops connections through the floating
  addresses on that unit — including any live APM session on the webtop.
- Someone who can reach the box out-of-band (console or management SSH) if the failover does not
  come back, since `admin` and `root` stay local and are unaffected by any of this.
- A green `./scripts/validate.sh` before you start, so a failure afterwards is attributable to
  the failover.

## Procedure
1. Record which unit is active and confirm the pair is in sync:

   ```bash
   set -a; . ./.env; set +a
   for u in "${BIGIP_A_MGMT}" "${BIGIP_B_MGMT}"; do
     printf '%s  ' "$u"
     curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" "https://${u}/mgmt/tm/cm/failover-status" \
       | jq -r '.entries[].nestedStats.entries.status.description'
   done
   curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" "https://${BIGIP_A_MGMT}/mgmt/tm/cm/sync-status" \
     | jq -r '.entries[].nestedStats.entries.status.description'
   ```

2. Confirm the VIP is in a floating traffic group, or the failover will not move it and the rest
   of this runbook proves nothing:

   ```bash
   tmsh list ltm virtual-address "${WL_APM_VIP}" traffic-group
   ```

   Expected: a floating group such as `traffic-group-1`, matching `WL_APM_TRAFFIC_GROUP`. If it
   reports `traffic-group-local-only`, move it (`tmsh modify ltm virtual-address <vip>
   traffic-group traffic-group-1`) and sync before continuing.

3. Establish a working baseline through the current active unit:

   ```bash
   scripts/demo-login.sh alice.admin
   ```

4. On the **active** unit, force it to standby:

   ```bash
   tmsh run sys failover standby
   tmsh show sys failover
   ```

   Expected: that unit reports `Standby`, and its peer becomes `Active` within a few seconds.

5. Confirm the VIP answers from the new active unit:

   ```bash
   curl -sk -o /dev/null -w '%{http_code}\n' --resolve "${WL_WEBTOP_FQDN}:443:${WL_APM_VIP}" \
     "https://${WL_WEBTOP_FQDN}/"
   ```

   Expected: `200` or `302`. `000` means the VIP did not move — go back to step 2.

## Verification
Walk the full chain again. The previous APM session did not survive the failover, so this is a
fresh login and it exercises every step:

```bash
scripts/demo-login.sh alice.admin
scripts/demo-login.sh bob.user
./scripts/validate.sh; echo "failed checks: $?"
```

Expected: both users complete password → LDAP → Keycloak TOTP → webtop with both TMUI resources
on the session, and `validate.sh` exits `0`.

Then assert the authorization outcome **on the newly-active unit specifically** — this is the
assertion the whole runbook exists for. The role is read from the unit's own audit log, because
the Guest role cannot use iControl REST and an HTTP status code would misreport bob's correct
`401` as a fault:

```bash
NEW_ACTIVE="${BIGIP_B_MGMT}"   # whichever unit step 4 promoted
for user in alice.admin bob.user; do
  curl -sk -o /dev/null -m10 -u "${user}:${WL_TEST_USER_PW}" "https://${NEW_ACTIVE}/mgmt/tm/sys/version"
  sleep 3
  printf '%s -> ' "$user"
  curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" -X POST -H 'Content-Type: application/json' \
    "https://${NEW_ACTIVE}/mgmt/tm/util/bash" \
    -d "{\"command\":\"run\",\"utilCmdArgs\":\"-c \\\"grep pam_audit /var/log/secure | grep ${user} | tail -1\\\"\"}" \
    | jq -r '.commandResult // ""' | grep -oE 'level=[A-Za-z]+' | tail -1
done
```

Expected: `alice.admin -> level=Administrator` and `bob.user -> level=Guest`. If alice comes back
`Guest` on this unit while she was `Administrator` on the other, the unit was never configured —
`auth ldap`/`remote-role` did not sync and never will. Fix it by running the per-unit script and
nothing else:

```bash
BIGIP_MGMT="${NEW_ACTIVE}" bigip/system-auth.sh
```

Finish with the browser click-through if you are preparing a demo: open the webtop, click both
TMUI tiles as alice (full menus, Create/Update present) and as bob (menus visible, controls
absent or greyed).

## Rollback
Forcing standby is a persistent state, not a momentary one. Clear it on the unit you forced,
then, if you want traffic back where it started, force the other unit to standby in turn:

```bash
tmsh run sys failover online     # on the unit forced to standby in step 4
tmsh show sys failover           # expect: Standby (no longer forced)
```

```bash
tmsh run sys failover standby    # on the peer, to hand traffic back to the original unit
```

Nothing in this runbook writes configuration unless you ran `bigip/system-auth.sh`, and that
script is idempotent and per-unit. Confirm the pair is back where you want it:

```bash
./scripts/validate.sh; echo "failed checks: $?"
```

## Escalation
- The VIP does not answer from the new active unit while `failover-status` says `Active`: the
  virtual address is in a local-only traffic group (step 2), or the peer never received the
  access profile. `validate.sh` asserts the access profile on B explicitly — if that check fails,
  run a config-sync from A ([../../deploy.md](../../deploy.md#procedure)).
- alice is `Administrator` on one unit and `Guest` on the other: expected symptom of a one-sided
  system-auth run, and the fix is the per-unit script above. If it persists after that, check
  `checkRolesGroup` on the failing unit — disabled, TMOS ignores every remote-role rule and every
  remote user gets the default role.
- The pair will not leave `Forced Offline`, or sync-status stays `Changes Pending` after a sync:
  that is HA, not warden-lite. Take it to the lab operator with the output of
  `tmsh show cm sync-status` and `tmsh show sys failover` from both units.
- Anything in the login chain that fails identically on both units is not a failover problem —
  start from [../troubleshooting.md](../troubleshooting.md).
