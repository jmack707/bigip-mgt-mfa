# Runbook — Roll the demo CA

Mint a new bigip-mgt-mfa CA, reissue the three server certificates it signs, and replace the trust
anchors that depend on it — on both BIG-IPs and in every browser that trusts the old one.

_Last validated: 2026-07-30_

## When to use this
- The CA is approaching its 365-day expiry, or a leaf certificate has already expired.
- The CA key may have been exposed — `certs/ca.key` is world-readable to anything on the Docker
  host and this is a lab CA, not a managed one.
- A demo environment is being handed to someone else and should not keep trusting material the
  previous holder still has.
- You changed `MFA_HOST_IP`, `MFA_WEBTOP_FQDN` or `MFA_APM_VIP`. This case does
  **not** need a CA roll: the leaf certificates are reissued on every ordinary
  `./deploy.sh --stack` and only the SANs change. Use
  [../../upgrade.md](../../upgrade.md#procedure) instead.

Rolling the CA is disruptive on purpose. Every browser trust import, both BIG-IP trust anchors
and the bundled OpenLDAP's LDAPS certificate are invalidated at the same moment, so the demo is
down until both halves of `deploy.sh` have run and the anchors are back.

## Prerequisites
- Shell access on the Docker host, in the repo root, with a complete `.env` and the stack
  currently running.
- `BIGIP_PASS` readable from `.env` or injected in the environment, and REST reachability to
  both management addresses on `443` — the new anchor has to reach both units, not just A.
- Administrative access to whatever trusts the CA today: the browsers and OS trust stores used
  to demo the webtop.
- Ownership of `certs/`. The `osixia/openldap` container chowns the bind-mounted directory at
  every startup, so signing after the stack has been up finds it root-owned;
  `scripts/lib/certs.sh` reclaims it with `sudo` or fails early telling you how.
- A window in which the demo can be down. There is no way to stage the new CA alongside the old
  one — `gen-certs.sh` writes one `ca.crt`/`ca.key` pair.

## Procedure
1. Back up the current material, so the roll is reversible:

   ```bash
   sudo chown -R "$(id -u):$(id -g)" certs
   cp -a certs "certs.bak.$(date +%Y%m%d-%H%M%S)"
   openssl x509 -in certs/ca.crt -noout -fingerprint -sha256 -enddate
   ```

2. Mint the new CA and reissue every leaf certificate. `MFA_REGEN_CA=1` is the only thing that
   makes `gen-certs.sh` replace an existing CA; without it the run reuses what is there:

   ```bash
   MFA_REGEN_CA=1 ./deploy.sh --stack
   ```

   Expect `MFA_REGEN_CA=1: minting a NEW CA (existing trust imports become invalid)` followed by
   three (bundled) or two (external) `issue` lines.

3. Restart the containers that read certificate files at process start. `docker compose up -d`
   does not recreate a service whose definition has not changed, so OpenLDAP go on
   presenting the old certificates until they are restarted:

   ```bash
   docker compose --profile bundled restart openldap
   ```

4. Push the new anchor and the new VIP certificate to the appliances. This updates the LDAPS
   trust anchor on **both** units and re-uploads `webtop.crt`/`ca.crt` on unit A:

   ```bash
   ./deploy.sh --bigip
   ```

   The anchor objects are PATCHed, not skipped, precisely for this case: an existing `ssl-cert`
   object that still holds the old CA fails closed against the new LDAPS certificate.

5. Re-import `certs/ca.crt` into every browser and OS trust store that held the old one, and
   remove the old import. The webtop VIP is what the browser connects to, so a browser that
   distrusts it fails at the redirect rather than showing a certificate warning.

In external directory mode step 2 does not reissue an LDAPS certificate — the BIG-IP validates
your directory against `MFA_LDAP_CA_FILE`, which this runbook does not touch. Only the demo
and webtop certificates change.

## Verification
```bash
openssl x509 -in certs/ca.crt -noout -fingerprint -sha256 -enddate
openssl s_client -connect "${MFA_APM_VIP}:443" -servername "${MFA_WEBTOP_FQDN}" \
  </dev/null 2>/dev/null | openssl x509 -noout -issuer -dates
./scripts/validate.sh; echo "failed checks: $?"
scripts/demo-login.sh alice.admin
```

Expected: the fingerprint differs from the one recorded in step 1; the certificate the webtop VIP
presents is issued by the new CA with fresh dates; `validate.sh` exits `0`; and `demo-login.sh`
completes the whole chain, which is what proves the BIG-IP re-anchored rather than merely
accepting a cached session.

Confirm the anchor landed on **both** units — this is the step people skip, and its absence only
shows up at the next failover:

```bash
for u in "${BIGIP_A_MGMT}" "${BIGIP_B_MGMT}"; do
  printf '%s ' "$u"
  curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" \
    "https://${u}/mgmt/tm/sys/file/ssl-cert/${MFA_LDAP_CA_NAME:-bigip-mgt-mfa-ca.crt}" \
    | jq -r '.checksum // "missing"'
done
```

Expected: the same non-empty checksum from both units.

## Rollback
Restore the backup taken in step 1 and re-run both halves without `MFA_REGEN_CA`, which reuses
the CA it finds:

```bash
sudo chown -R "$(id -u):$(id -g)" certs
rm -rf certs && cp -a certs.bak.<timestamp> certs
./deploy.sh --stack
docker compose --profile bundled restart openldap
./deploy.sh --bigip
```

Browsers that already re-imported the new CA keep working — they now trust both — but any store
from which you removed the old CA needs it back. Without a backup there is no rollback: the old
key is gone and the only way forward is to finish the roll and re-import everywhere.

## Escalation
- `validate.sh` reports the BIG-IP LDAPS checks failing while the containers are healthy: the
  anchor did not update on that unit. Re-run `BIGIP_MGMT=<unit> bigip/system-auth.sh` and read
  the `HTTP` lines it prints.
- The webtop shows a certificate warning: the browser still holds only the old CA, or the
  BIG-IP is validating LDAPS against the stale `bigip-mgt-mfa-ca.crt` uploaded
  by the APM build — re-run `./deploy.sh --bigip` and see
  [../troubleshooting.md](../troubleshooting.md).
- Anything still unexplained after the anchors are confirmed on both units belongs with the lab
  operator, with the fingerprints from step 1 and the Verification section attached.
