# Contributing

## Development setup
bigip-mgt-mfa is shell, declarative BIG-IP configuration, and a Keycloak realm template. There
is no build step and nothing to compile.

You need a Linux host with Docker and the compose V2 plugin, plus `openssl`, `jq`,
`gettext-base`, `curl`, `ldap-utils`, `dnsutils`, and `oathtool`. To exercise the BIG-IP half
you need a licensed BIG-IP with LTM and APM provisioned; an HA pair to exercise all of it.

```bash
cp .env.example .env
./deploy.sh --stack
```

The stack half contacts no appliance, so most work can be done without one.

## Testing
There is no unit-test suite; the tests are the two scripts that assert against a live
deployment.

```bash
./scripts/validate.sh              # exits with the number of failed checks
./scripts/demo-login.sh alice.admin
./scripts/demo-login.sh bob.user
```

Never validate destructively against a deployment someone is using. Bring up a throwaway
stack instead — `docker compose --profile bundled down -v` and redeploy is cheap.

Shell changes should pass `shellcheck`. Anything touching the BIG-IP must be re-runnable:
run it twice and confirm the second run converges rather than erroring or silently keeping
stale values.

## Documentation
Documentation is enforced. `.github/workflows/docs-lint.yml` runs
`.github/scripts/doc_lint.py` against `doc-standard.json` and fails the pull request on
missing sections, placeholder text, broken relative links, untagged code fences, and drift
between `.env.example` and `docs/reference/configuration.md`.

```bash
python3 .github/scripts/doc_lint.py
```

If you add an environment variable, document it. If you add a script, add it to
`docs/reference/cli.md`. If you change a decision, write an ADR rather than editing the old
one — the record of what was decided and why is the point.

Relaxing a lint rule is allowed; do it in `doc-standard.json` and record the reason in an ADR.

## Pull requests
`main` is protected, so all changes arrive by pull request.

Keep a pull request to one concern. Say what you changed, why, and how you verified it —
paste the `validate.sh` output if the change touches the deployment path. Note the TMOS
version you tested against; APM object schemas differ between releases and this repository
targets 21.x.
