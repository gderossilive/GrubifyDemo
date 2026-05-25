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

## Workflow inputs

The deployment workflow exposes the following `workflow_dispatch` inputs:

- `environment_name` — azd environment name, for example `grubify-demo`.
- `resource_token` — short token used in resource names, for example `demo01`.
- `release_version` — semantic version string, for example `0.2.0-step0`.
- `release_profile` — one of the documented release profiles.
- `deploy_mode` — `up` for first-time provisioning or `deploy` for
  app-only redeploys after provisioning.

## Dispatch procedure

1. Gather and confirm all required workflow inputs from the operator.
2. Dispatch `.github/workflows/deploy-grubify.yml` using the GitHub MCP tools.
3. Poll the workflow run status until it reaches a terminal conclusion
   (`success`, `failure`, `cancelled`, or `timed_out`).
4. Capture the run URL, conclusion, and duration for the release summary.

## Baseline post-deploy validation

After a successful workflow run:

1. Verify the frontend URL returns HTTP 200.
2. Verify the API URL responds for at least:
   - `GET /api/restaurants`
   - `GET /api/fooditems`
   - `GET /api/cart/{userId}` (use `demo-user`).
3. Verify a single `POST /api/cart/demo-user/items` returns 2xx with a valid
   cart body.
4. Confirm the new revision is active in Container Apps and is receiving
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
