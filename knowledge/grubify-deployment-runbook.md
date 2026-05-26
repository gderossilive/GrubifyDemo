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

Before dispatching the workflow, confirm:

1. The repository contains `.github/workflows/deploy-grubify.yml`.
2. Required GitHub Secrets or OIDC federation are configured:
   - `AZURE_CLIENT_ID`
   - `AZURE_TENANT_ID`
   - `AZURE_SUBSCRIPTION_ID`
   - (Optional fallback) `AZURE_CREDENTIALS` service-principal JSON.
3. The target azd environment name and resource token are known.
4. Region is `swedencentral` (SRE Agent preview constraint).
5. If using PAT fallback, ensure PAT source is available:
   - Direct env var: `GITHUB_PAT`, or
   - Key Vault source via `GITHUB_PAT_SECRET_URI`, or
   - Key Vault name+secret via `GITHUB_PAT_KEYVAULT_NAME` +
     `GITHUB_PAT_SECRET_NAME`.
6. For Key Vault-backed PAT reads, grant the executing identity Key Vault RBAC
   role `Key Vault Secrets User` on the vault.

## Workflow inputs

The deployment workflow exposes the following `workflow_dispatch` inputs:

- `environment_name` — azd environment name, for example `grubify-demo`.
- `resource_token` — short token used in resource names, for example `demo01`.
- `release_version` — semantic version string, for example `0.2.0-step0`.
- `release_profile` — one of the documented release profiles.
- `deploy_mode` — `up` for first-time provisioning or `deploy` for
  app-only redeploys after provisioning.

## Default values (when the operator omits an input)

When an operator triggers a deploy via chat without supplying every input,
resolve missing values from this table and confirm them back before dispatch.
Do NOT silently apply defaults — always echo the resolved set for ack.

| Input             | Default              | Notes                                              |
|-------------------|----------------------|----------------------------------------------------|
| `environment_name`| `e2e01`              | Current live azd environment.                      |
| `resource_token`  | `e2e01`              | Matches the environment_name.                      |
| `release_profile` | `cart-leak-baseline` | Only documented profile today.                     |
| `deploy_mode`     | `deploy`             | App-only redeploy; use `up` only when infra changes.|
| `release_version` | `YYYYMMDD-<shortsha>`| Auto-generated from current UTC date + 7-char SHA of `main`. Example: `20260526-7ff693b`. |

## Natural-language invocation examples

The operator may phrase requests in many ways. Recognize these as deploy
intents (keywords: `deploy`, `release`, `ship`, `roll out`, `push`):

- **Terse**: "deploy to e2e01" → resolve all 5 inputs from defaults, confirm, dispatch.
- **Version only**: "release 0.3.0 to e2e01" → `release_version=0.3.0`, rest from defaults.
- **Verbose**: "ship version 0.3.0 to environment e2e01 using profile cart-leak-baseline in deploy mode" → use exactly as specified, confirm, dispatch.
- **Skip confirmation** (advanced): "deploy 0.3.0 to e2e01 without confirmation" → dispatch immediately after resolving defaults; still report the resolved set in the summary.

## Dispatch procedure

1. Resolve all 5 workflow inputs (operator-supplied first, then defaults).
2. Echo the resolved set to the operator and wait for `yes`/`go`/`confirm`
   unless the operator explicitly said "without confirmation".
3. Dispatch `.github/workflows/deploy-grubify.yml` with PAT fallback first.
    If PAT fallback cannot start, use GitHub MCP as secondary path.

    PAT fallback steps:
    - Read `connector/github` from
       `GET /api/v2/extendedAgent/connectors/github` on the SRE endpoint.
    - Confirm `dataConnectorType=GitHubPat` and extract
       `extendedProperties.accessToken`.
    - Call GitHub REST directly to dispatch:
       `POST /repos/gderossilive/GrubifyDemo/actions/workflows/deploy-grubify.yml/dispatches`.
    Secondary path:
    - Use `github-mcp` workflow dispatch only if PAT fallback cannot start.
    Resource-group note:
    - The app RG may not always match `rg-grubify-app-${resource_token}` in
       legacy environments. If that RG lookup fails, resolve the real RG from
       the ACR named `cr${resource_token}` and continue with that RG.
4. Poll the workflow run status until it reaches a terminal conclusion
   (`success`, `failure`, `cancelled`, or `timed_out`).
5. Capture the run URL, conclusion, and duration for the release summary.
6. On non-`success` conclusion, follow the **Failure-path handoff** section.

Notes for fallback mode:

- Do not treat `gh auth status` as authoritative in the sandbox.
- Prefer direct REST with `Authorization: Bearer <connector PAT>`.
- A deploy is valid only when a run id and run URL are present.

## Failure-path handoff (Decision: auto-handoff)

If the dispatched workflow run ends with `conclusion != success`, the
subagent MUST hand off to `incident-handler-core` for investigation. Do not
stop at "report only".

Handoff payload shape (pass verbatim as the handoff context):

```json
{
  "source": "deployment-manager",
  "run_url": "https://github.com/<owner>/<repo>/actions/runs/<run_id>",
  "run_id": "<run_id>",
  "conclusion": "failure|cancelled|timed_out",
  "last_failed_step": "<job>/<step name>",
  "failure_logs_tail": "<last ~50 lines of the failed step's log>",
  "release_inputs": {
    "environment_name": "...",
    "resource_token": "...",
    "release_version": "...",
    "release_profile": "...",
    "deploy_mode": "..."
  }
}
```

Use `github-mcp` tools or GitHub REST fallback to retrieve
`last_failed_step` and the failing job's log tail. After handoff, also report
the run URL + handoff confirmation to the operator in chat.

## PAT rotation

The `github-mcp` connector uses a fine-grained GitHub PAT scoped to
`gderossilive/GrubifyDemo` with `actions:write`, `contents:read`,
`issues:write`, `pull_requests:read`. Rotate quarterly. Owner: repo admin.
After rotation, push the new value to the agent via
`python3 bin/apply-extras.py` (loads `GITHUB_PAT` from `.env`).

## Baseline post-deploy validation

After a successful workflow run:

1. Verify the frontend URL returns HTTP 200.
2. Verify the API URL responds for at least:
   - `GET /api/restaurants`
   - `GET /api/fooditems`
   - `GET /api/cart/{userId}` (use `demo-user`).
3. Verify a single `POST /api/cart/demo-user/items` returns 2xx with a valid
   cart body.
4. Verify `POST /api/orders` returns `201`.
5. Confirm the new revision is active in Container Apps and is receiving
   traffic via Log Analytics or App Insights.

If any baseline check fails, treat it as a deployment validation failure,
recommend rollback, and do not hand off to `tests-manager`.

## Handoff to tests-manager

When baseline checks pass and the operator explicitly requests the test or
load-trigger phase, hand off to the `tests-manager` subagent. Provide:

- The target frontend and API URLs.
- The release profile and release version.
- The Container App revision name and ACR image tag.

`deployment-manager` does NOT run the cart load trigger itself.

## Rollback

If a release fails baseline validation or a regression is reported later:

1. Re-dispatch `deploy-grubify.yml` with the previous known-good
   `release_version` and the same `release_profile`.
2. Use `deploy_mode=deploy` if infrastructure is unchanged.
3. Re-run baseline validation after the rollback completes.

## References

- Workflow: `.github/workflows/deploy-grubify.yml`
- Subagent: `sre-config/agents/deployment-manager.yaml`
- Instructions: `sre-config/agents/instructions/deployment-manager.instructions.md`
- Cart bug source: `GrubifyApi/Controllers/CartController.cs`
- Tests runbook: `knowledge/grubify-tests-runbook.md`
