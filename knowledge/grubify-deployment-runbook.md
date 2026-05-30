# Grubify Deployment Runbook

This runbook documents how the `deployment-manager` SRE Agent subagent
orchestrates Grubify releases through the GitHub Actions workflow
`.github/workflows/deploy-grubify.yml`. Deployment authority lives in CI;
the subagent only dispatches and validates.

## When to use

Use this runbook for any Grubify release where `deployment-manager` is asked
to dispatch a deployment, including the demo `cart-leak-baseline` Step 0
release.

## Release profiles

| Profile               | Purpose                                                      | API_VERSION | Notes                                                                 |
|-----------------------|--------------------------------------------------------------|-------------|------------------------------------------------------------------------|
| `cart-leak-baseline`  | Step 0 demo release that intentionally retains the cart bug. | `v1`        | Approved only for the Grubify demo environment.                       |
| `safe`                | Reserved for a future production-safe release.               | `v1`        | Not yet implemented; do not dispatch.                                 |

Do not use `API_VERSION=v2`. That order/payment failure path is a separate
scenario and is out of scope for this runbook.

## Preflight checks

Detailed preflight steps now live in the deployment-manager skill:

- `sre-config/agents/skills/deployment-manager-release-orchestration.skill.md`

Use the skill as source of truth for prerequisites, PAT source checks, and
Key Vault RBAC requirements.

## Workflow inputs

The workflow input contract is maintained in the deployment-manager skill.

## Default values (when the operator omits an input)

Defaults and input-resolution order now live in the deployment-manager skill.
The subagent must still echo the resolved set for operator ack before
dispatch (unless explicitly asked to skip confirmation).

## Natural-language invocation examples

Natural-language intent handling now lives in the deployment-manager skill.

## Dispatch procedure

Dispatch sequencing, PAT-first fallback, RG lookup fallback behavior,
terminal-state polling, and run-evidence requirements are now defined in the
deployment-manager skill.

## Failure-path handoff (Decision: auto-handoff)

Failure-path auto-handoff and exact payload shape are now defined in the
deployment-manager skill.

## GitHub auth

The no-PAT path is the SRE portal/GitHub MCP OAuth connection, authorized for
`gderossilive/GrubifyDemo` with `repo` and `workflow` scopes. A data-plane
`GitHubOAuth` connector created with `bin/apply-extras.py` is not a valid
replacement in the current backend; `/api/v2/extendedAgent/connectors/github/status`
reports that connector type as deprecated/disconnected.

`bin/apply-extras.py` applies the code repo entry by default and skips
`connector/github` unless explicitly enabled. If fully repeatable automation is
needed without portal OAuth repair, use explicit PAT connector mode:

```bash
ENABLE_GITHUB_AUTH_CONNECTOR=true GITHUB_AUTH_CONNECTOR_TYPE=pat GITHUB_PAT=<token-with-workflow-scope> python3 bin/apply-extras.py
```

For fine-grained PATs, grant Actions read/write on the repository. For classic
PATs, include `repo` and `workflow` scopes. If dispatch returns
`401 Bad credentials`, report `connector-authorization` and repair portal/MCP
OAuth or switch intentionally to PAT connector mode.

For arbitrary GitHub Actions workflows such as `.github/workflows/deploy-grubify.yml`,
the current built-in `TriggerWorkflow` tool is demo-specific and should not be
used unless the platform adds general workflow support. Prefer GitHub MCP if it
exposes workflow dispatch. The `new02` SRE Agent sandbox has been observed with
`/usr/bin/gh` version 2.92.0, but a live `gh workflow run` dispatch returned
unauthenticated/login-required when no terminal token was exported. The
repeatable fallback is the SRE Key Vault secret `GH-PAT` in
`kv-sre-grubify-${resourceToken}`. The deployment-manager retrieves that secret
inside `RunInTerminal`, exports it as `GH_TOKEN` only for `gh workflow run`, and
unsets it afterward. Do not use raw terminal `curl` against `api.github.com`
unless an explicit workflow-capable token is available and every request includes
an `Authorization` header.

The repeatable SRE content pipeline verifies this path after each apply. Expected
checks are: deployment-manager has `github-mcp/*`, has `connectors: [github]`,
and the live prompt retrieves `GH-PAT` from Key Vault for `gh workflow run`. If
those checks are missing, rerun `python3 bin/assemble-agent.py` and
`python3 bin/apply-extras.py` or `./scripts/deploy-sre-agent.sh` against the
target environment.

The authenticated terminal fallback dispatch shape is:

```bash
az account show >/dev/null 2>&1 || az login --identity --allow-no-subscriptions >/dev/null
export GH_TOKEN="$(az keyvault secret show --vault-name kv-sre-grubify-new02 --name GH-PAT --query value -o tsv)"
gh workflow run deploy-grubify.yml \
	--repo gderossilive/GrubifyDemo \
	--ref main \
	-f environment_name=new02 \
	-f resource_token=new02 \
	-f release_version=<release-version> \
	-f release_profile=cart-leak-baseline \
	-f deploy_mode=deploy
unset GH_TOKEN
```

## Baseline post-deploy validation

Baseline validation checks and failure handling are now defined in the
deployment-manager skill.

## Handoff to tests-manager

Handoff rules and payload details for tests-manager are now defined in the
deployment-manager skill.

## Rollback

Rollback procedure and constraints are now defined in the
deployment-manager skill.

## References

- Workflow: `.github/workflows/deploy-grubify.yml`
- Subagent: `sre-config/agents/deployment-manager.yaml`
- Instructions: `sre-config/agents/instructions/deployment-manager.instructions.md`
- Skill: `sre-config/agents/skills/deployment-manager-release-orchestration.skill.md`
- Cart bug source: `GrubifyApi/Controllers/CartController.cs`
- Tests runbook: `knowledge/grubify-tests-runbook.md`
