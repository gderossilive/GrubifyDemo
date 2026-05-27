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

## PAT rotation

The `github-mcp` connector uses a fine-grained GitHub PAT scoped to
`gderossilive/GrubifyDemo` with `actions:write`, `contents:read`,
`issues:write`, `pull_requests:read`. Rotate quarterly. Owner: repo admin.
After rotation, push the new value to the agent via
`python3 bin/apply-extras.py` (loads `GITHUB_PAT` from `.env`).

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
