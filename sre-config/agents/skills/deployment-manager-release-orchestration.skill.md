# Deployment Manager Skill: Release Orchestration

Use this skill as the execution contract for dispatching and validating Grubify releases.

## Scope

- Deployment authority is GitHub Actions workflow .github/workflows/deploy-grubify.yml.
- This subagent dispatches, monitors, validates, and hands off.
- Do not mutate Azure infrastructure directly.

## Release Profiles

- cart-leak-baseline: demo Step 0 release (API_VERSION v1), approved only for Grubify demo environment.
- safe: reserved and not implemented; do not dispatch.

Do not use API_VERSION v2.

## Preflight Checks

Before dispatch:

1. Verify workflow file exists in gderossilive/GrubifyDemo.
2. Confirm auth prerequisites are present (OIDC or required GitHub secrets).
3. Confirm target environment_name and resource_token.
4. Confirm region is swedencentral.
5. If PAT fallback is used, ensure PAT source exists via one of:
   - GITHUB_PAT
   - GITHUB_PAT_SECRET_URI
   - GITHUB_PAT_KEYVAULT_NAME + GITHUB_PAT_SECRET_NAME
6. For Key Vault PAT read, executing identity must have Key Vault Secrets User.

## Workflow Inputs

Required inputs:

- environment_name
- resource_token
- release_version
- release_profile
- deploy_mode

Default resolution order: operator-provided values first, then defaults.

Defaults:

- environment_name = e2e01
- resource_token = e2e01
- release_profile = cart-leak-baseline
- deploy_mode = deploy
- release_version = YYYYMMDD-<7-char main SHA>

Always echo resolved input set and wait for explicit confirmation unless operator explicitly asked for without confirmation/no confirm.

## Deploy Intent Recognition

Treat these as deploy intents: deploy, release, ship, roll out, push, promote, cut a release.

## Dispatch Procedure

1. Resolve all five inputs.
2. Echo resolved set and obtain confirmation unless explicitly skipped.
3. Dispatch workflow with mandatory path preference:
   - Primary: PAT fallback using connector/github GitHubPat token.
   - Secondary: github-mcp workflow dispatch only when PAT fallback cannot start.
4. For PAT fallback:
   - Read connector/github via SRE data-plane endpoint.
   - Require dataConnectorType GitHubPat and non-empty accessToken.
   - Dispatch GitHub REST workflow_dispatch for deploy-grubify.yml on main.
   - Poll workflow run via REST until terminal.
5. If legacy environment app RG lookup fails for rg-grubify-app-${resource_token}, resolve actual RG from ACR cr${resource_token}.

## Hard Evidence Rule

A deployment is valid only with run_id and run_url obtained in the current conversation.
Do not substitute Azure revision/image observations for dispatch evidence.
Do not use gh auth status as a gate in this sandbox.

## Monitoring and Terminal States

Poll until terminal conclusion in: success, failure, cancelled, timed_out.
Always include run_url in progress updates.

## Post-Success Baseline Validation

After terminal success:

1. Frontend URL returns HTTP 200.
2. API responds for:
   - GET /api/restaurants
   - GET /api/fooditems
   - GET /api/cart/{userId} (demo-user default)
3. POST /api/cart/demo-user/items returns 2xx with valid cart body.
4. POST /api/orders returns 201.
5. Confirm new revision is active and receiving traffic via Log Analytics or App Insights.

If any baseline check fails: classify as deployment validation failure, recommend rollback, and do not hand off to tests-manager.

## Failure-Path Handoff (Mandatory)

For terminal non-success (failure/cancelled/timed_out), hand off to incident-handler-core.

Handoff context shape:

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

Retrieve last_failed_step and failure_logs_tail using github-mcp or GitHub REST fallback.
After handoff, report run_url and handoff confirmation to operator.

## Handoff to tests-manager

Only when baseline checks pass and operator requested test/load-trigger phase.
Provide frontend URL, API URL, release profile, release version, revision name, and ACR image tag.

## Rollback

If release fails baseline validation or regression is reported:

1. Re-dispatch deploy-grubify.yml with previous known-good release_version.
2. Keep same release_profile.
3. Use deploy_mode=deploy when infrastructure is unchanged.
4. Re-run baseline validation.

## Reporting Contract

Produce structured summary with:

- resolved release inputs
- run_url, conclusion, duration
- baseline checks pass/fail per item
- next step (tests-manager handoff, rollback, or human review)
- references: revision name, ACR image tag, App Insights resource ID, Log Analytics workspace ID

## Guardrails

- Never call write-capable Azure mutation paths.
- Never bypass validation or force unsupported profile behavior.
- Never claim success without run_id and run_url evidence.
