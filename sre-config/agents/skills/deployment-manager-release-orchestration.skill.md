# Deployment Manager Skill: Release Orchestration

Use this skill as the execution contract for dispatching and validating Grubify releases.

## Scope

- Deployment authority is the configured GitHub Actions workflow
   `${WORKFLOW_FILE}` in `${REPO_FULL_NAME}` on `${WORKFLOW_REF}`.
- This subagent dispatches, monitors, validates, and hands off.
- Do not mutate Azure infrastructure directly.

## Runtime Parameters

Resolve parameters in this order: operator input -> environment/config -> defaults.

- `REPO_FULL_NAME` (default: `gderossilive/GrubifyDemo`)
- `WORKFLOW_FILE` (default: `.github/workflows/deploy-grubify.yml`)
- `WORKFLOW_REF` (default: `main`)
- `CONNECTOR_REF` (default: `connector/github`)
- `EXPECTED_REGION` (default: `swedencentral`)
- `DEFAULT_ENVIRONMENT_NAME` (default: `e2e01`)
- `DEFAULT_RESOURCE_TOKEN` (default: same as `environment_name`)
- `DEFAULT_RELEASE_PROFILE` (default: `cart-leak-baseline`)
- `DEFAULT_DEPLOY_MODE` (default: `deploy`)
- `DEFAULT_USER_ID` for cart checks (default: `demo-user`)

## Release Profiles

Supported release profiles are environment-configurable. Recommended defaults:

- `cart-leak-baseline`: demo Step 0 release (API_VERSION v1).
- `safe`: reserved and not implemented unless explicitly enabled.

Do not use API_VERSION v2.

## Preflight Checks

Before dispatch:

1. Validate `${WORKFLOW_FILE}` exists in `${REPO_FULL_NAME}`.
2. Resolve SRE data-plane endpoint from agent resource `properties.agentEndpoint`
   (do not assume `properties.configuration.endpoint`).
3. For SRE data-plane API calls, use an access token with audience/resource
   `https://azuresre.ai`.
4. Confirm auth prerequisites are present (OIDC or required GitHub secrets).
5. Confirm target environment_name and resource_token.
6. Confirm target region matches `${EXPECTED_REGION}`.
7. If PAT fallback is used, ensure PAT source exists via one of:
   - GITHUB_PAT
   - GITHUB_PAT_SECRET_URI
   - GITHUB_PAT_KEYVAULT_NAME + GITHUB_PAT_SECRET_NAME
8. For Key Vault PAT read, executing identity must have Key Vault Secrets User.

## Connector and Repo Semantics

- Treat Notification connectors and Code Repository entries as separate surfaces.
- `${CONNECTOR_REF}` readiness is a connector check; GitHub repository presence is
   a code-repo check.
- UI may show both Teams and GitHub as "connected", while connector collection
   APIs may return only Teams and GitHub appears under repos.
- Do not infer connector availability from connector count alone.

## Workflow Inputs

Required inputs:

- environment_name
- resource_token
- release_version
- release_profile
- deploy_mode

Default resolution order: operator-provided values first, then defaults.

Defaults:

- environment_name = `${DEFAULT_ENVIRONMENT_NAME}`
- resource_token = `${DEFAULT_RESOURCE_TOKEN}` (or derive from environment_name)
- release_profile = `${DEFAULT_RELEASE_PROFILE}`
- deploy_mode = `${DEFAULT_DEPLOY_MODE}`
- release_version = `YYYYMMDD-<7-char SHA of ${WORKFLOW_REF}>`

Always echo resolved input set and wait for explicit confirmation unless operator explicitly asked for without confirmation/no confirm.

## Deploy Intent Recognition

Treat these as deploy intents: deploy, release, ship, roll out, push, promote, cut a release.

## Dispatch Procedure

1. Resolve all five inputs.
2. Echo resolved set and obtain confirmation unless explicitly skipped.
3. Dispatch workflow with mandatory path preference:
    - Primary: server-side connector use with `${CONNECTOR_REF}`
       (GitHubPat or OAuth), where secrets are resolved only by backend runtime.
   - Secondary: github-mcp workflow dispatch only when PAT fallback cannot start.
4. For PAT fallback:
    - Invoke backend connector-use path (for example, dispatch API with
       `connectorRef=${CONNECTOR_REF}`).
   - Do not read connector secret material from data-plane APIs.
    - Require backend evidence that `${CONNECTOR_REF}` is Connected/Ready.
    - Separately require repo evidence that `${REPO_FULL_NAME}` is present/Ready in
       the code-repo surface.
    - Dispatch GitHub `workflow_dispatch` for `${WORKFLOW_FILE}` on
       `${WORKFLOW_REF}` via backend connector-use operation.
   - Poll workflow run via GitHub REST or backend status endpoint until terminal.
5. If legacy environment app RG lookup fails for rg-grubify-app-${resource_token}, resolve actual RG from ACR cr${resource_token}.

## Hard Evidence Rule

A deployment is valid only with run_id and run_url obtained in the current conversation.
Do not substitute Azure revision/image observations for dispatch evidence.
Do not use gh auth status as a gate in this sandbox.
Do not treat connector secret reads as valid evidence; only run_id/run_url and workflow status evidence count.

## Monitoring and Terminal States

Poll until terminal conclusion in: success, failure, cancelled, timed_out.
Always include run_url in progress updates.

## Post-Success Baseline Validation

After terminal success:

1. Frontend URL returns HTTP 200.
2. API responds for:
   - GET /api/restaurants
   - GET /api/fooditems
   - GET /api/cart/{userId} (`${DEFAULT_USER_ID}` default)
3. POST /api/cart/${DEFAULT_USER_ID}/items returns 2xx with valid cart body.
4. POST /api/orders returns 201.
5. Confirm new revision is active and receiving traffic via Log Analytics or App Insights.

If telemetry backends are unavailable/not provisioned, classify telemetry as
"evidence unavailable" and report the reason explicitly; do not mark deployment
failed when all functional baseline checks pass.

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

1. Re-dispatch `${WORKFLOW_FILE}` with previous known-good release_version.
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
- Never call connector read APIs to extract PAT/secret values.
- Use connector metadata/status reads only (Connected/Ready), and use server-side connector execution for dispatch.
