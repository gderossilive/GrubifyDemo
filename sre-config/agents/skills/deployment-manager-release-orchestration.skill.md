# Deployment Manager Skill: Release Orchestration

Use this skill as the execution contract for dispatching, monitoring, and
validating Grubify releases through GitHub Actions.

## Scope

- Deployment authority is the configured GitHub Actions workflow
  `${WORKFLOW_FILE}` in `${REPO_FULL_NAME}` on `${WORKFLOW_REF}`.
- This subagent resolves release inputs, triggers the workflow, tracks the run,
  validates baseline health, and hands off when needed.
- Do not mutate Azure infrastructure directly. Azure access is read-only
  evidence and validation.

## Runtime Parameters

Resolve parameters in this order: operator input -> environment/config ->
defaults.

- `REPO_FULL_NAME` (default: `gderossilive/GrubifyDemo`)
- `WORKFLOW_FILE` (default: `.github/workflows/deploy-grubify.yml`)
- `WORKFLOW_REF` (default: `main`)
- `EXPECTED_REGION` (default: `swedencentral`)
- `DEFAULT_ENVIRONMENT_NAME` (default: `e2e01`)
- `DEFAULT_RESOURCE_TOKEN` (default: same as `environment_name`)
- `DEFAULT_RELEASE_PROFILE` (default: `cart-leak-baseline`)
- `DEFAULT_DEPLOY_MODE` (default: `deploy`)
- `DEFAULT_USER_ID` for cart checks (default: `demo-user`)
- `SRE_AGENT_API_VERSION` (required default: `2025-05-01-preview`)

## Release Profiles

Supported release profiles are environment-configurable. Defaults:

- `cart-leak-baseline`: demo Step 0 release with `API_VERSION=v1`.
- `safe`: reserved; do not use unless explicitly enabled in environment config.

Refuse unsupported release profiles and explain the supported values. Do not use
`API_VERSION=v2`.

## GitHub Connector Authentication

The GitHub connector OAuth/PAT token is the default credential for GitHub
workflow operations. The operator does not need to provide a separate PAT.

Platform GitHub workflow tools authenticate through `GitHubClientFactory`, which
asks `IOAuthTokenService.GetValidGitHubTokenAsync()` for the current GitHub
token. That token is the same credential obtained when the GitHub repository is
connected through the connector. The platform refreshes OAuth tokens at request
time through the connector credential store.

Credential precedence:

1. `GitHubSettings.PatTokenOverride`, if configured, takes precedence.
2. Otherwise use the connector OAuth/PAT credential.

Required workflow-dispatch permissions:

- OAuth connector: OAuth authorization must include `workflow` and `repo`.
- Classic PAT connector: PAT must include `workflow`.
- Fine-grained PAT connector: Actions read and write permission is required for
  `${REPO_FULL_NAME}`.

If dispatch fails because the token lacks workflow permission, report that the
GitHub connector must be re-authorized or repaired. Do not ask for a separate
PAT unless the operator intentionally wants to configure `PatTokenOverride`.

## Built-In Workflow Tool Caveat

The built-in `TriggerWorkflow` tool is not a general GitHub Actions trigger in
the current platform. It is hardcoded to these demo workflow filenames:

- `main_oa-demo-web-stage.yml`
- `main_oa-demo-web-canary.yml`
- `main_oa-demo-web-prod-westus.yml`

Although `TriggerWorkflow`, `TrackWorkflow`, and
`CheckPullRequestMergeStatus` use the connector token automatically, do not use
`TriggerWorkflow` for `${WORKFLOW_FILE}` unless it matches one of those
supported demo filenames or the platform explicitly adds general support.

## Workflow Inputs

Required inputs:

- `environment_name`
- `resource_token`
- `release_version`
- `release_profile`
- `deploy_mode`

Defaults:

- `environment_name = ${DEFAULT_ENVIRONMENT_NAME}`
- `resource_token = ${DEFAULT_RESOURCE_TOKEN}` or derive from
  `environment_name`
- `release_profile = ${DEFAULT_RELEASE_PROFILE}`
- `deploy_mode = ${DEFAULT_DEPLOY_MODE}`
- `release_version = YYYYMMDD-<7-char SHA of ${WORKFLOW_REF}>`

Always echo the resolved input set and wait for explicit confirmation unless the
operator explicitly asked for `without confirmation` or `no confirm`.

## Preflight Checks

Before dispatch:

1. Validate `${WORKFLOW_FILE}` exists in `${REPO_FULL_NAME}` at
   `${WORKFLOW_REF}`.
2. Validate the target region is `${EXPECTED_REGION}`.
3. Confirm target `environment_name`, `resource_token`, `release_profile`, and
   `deploy_mode`.
4. Confirm the workflow input contract accepts the five required inputs.
5. Confirm GitHub connector authorization is expected to include workflow
   dispatch permission. If evidence shows missing scope/permission, block with a
   connector authorization action.
6. If collecting SRE Agent endpoint evidence, use Microsoft.App/agents API
   version `2025-05-01-preview` and `properties.agentEndpoint`.
7. Create one evidence directory for the attempt:
   `/tmp/deploy-${resource_token}-${YYYYMMDDHHMMSS}`.

## Dispatch Procedure

Use this preference order for general Grubify workflow dispatch:

1. `RunInTerminal` with GitHub CLI:

   ```bash
   gh workflow run "${WORKFLOW_FILE}" \
     --repo "${REPO_FULL_NAME}" \
     --ref "${WORKFLOW_REF}" \
     -f environment_name="${environment_name}" \
     -f resource_token="${resource_token}" \
     -f release_version="${release_version}" \
     -f release_profile="${release_profile}" \
     -f deploy_mode="${deploy_mode}"
   ```

   The platform outbound proxy injects the GitHub connector OAuth/PAT token for
   `api.github.com`. Do not require `GITHUB_PAT`, `GH_TOKEN`, or a locally
   readable OAuth token before trying this path.

2. GitHub MCP connector, if configured and authenticated. Use its native
   workflow dispatch and run-tracking capabilities when available.

3. Built-in `TriggerWorkflow` only when the target workflow filename is one of
   the supported demo-specific filenames listed above.

Record the chosen dispatch path, command or tool input, response status, and any
returned run metadata in the evidence directory. Never print secret values.

If a dispatch path returns HTTP 401, HTTP 403, missing `workflow` scope, or
Actions read/write permission failure, stop that path and report the exact
authorization failure. Do not retry equivalent unauthenticated GitHub API calls.

## Run Discovery and Tracking

After a successful dispatch request, discover the run for `${WORKFLOW_FILE}` and
`${WORKFLOW_REF}` using one authenticated path:

- `gh run list --repo ${REPO_FULL_NAME} --workflow ${WORKFLOW_FILE} --branch
  ${WORKFLOW_REF}` with filtering by creation time and inputs when available.
- GitHub MCP run listing/tracking.
- A verified backend status endpoint.
- Built-in `TrackWorkflow` only for runs created through a supported built-in
  workflow path.

Poll until terminal conclusion in: `success`, `failure`, `cancelled`, or
`timed_out`. Include `run_url` in progress updates and final reporting.

## Hard Evidence Rule

A deployment is valid only with `run_id` and `run_url` obtained during the
current conversation. Do not substitute Azure revision, ACR image, or telemetry
observations for dispatch evidence.

If a run is visible but the requested workflow inputs cannot be proven, report:
`healthy environment observed, requested release inputs unproven`.

## Post-Success Baseline Validation

After terminal success:

1. Frontend URL returns HTTP 200.
2. API responds for:
   - `GET /api/restaurants`
   - `GET /api/fooditems`
   - `GET /api/cart/{userId}` using `${DEFAULT_USER_ID}` unless overridden
3. `POST /api/cart/${DEFAULT_USER_ID}/items` returns 2xx with a valid cart body.
4. `POST /api/orders` returns 201.
5. Confirm the new revision is active and receiving traffic through Log
   Analytics or App Insights when telemetry is available.

If telemetry backends are unavailable, classify telemetry as `evidence
unavailable` and report why. Do not fail deployment when all functional baseline
checks pass.

If any functional baseline check fails, classify it as deployment validation
failure, recommend rollback, and do not hand off to tests-manager.

## Failure-Path Handoff

For terminal non-success states, hand off to incident-handler-core.

Handoff context shape:

```json
{
  "source": "deployment-manager",
  "run_url": "https://github.com/<owner>/<repo>/actions/runs/<run_id>",
  "run_id": "<run_id>",
  "conclusion": "failure|cancelled|timed_out",
  "last_failed_step": "<job>/<step name>",
  "failure_logs_tail": "<last ~50 lines of the failed step log>",
  "release_inputs": {
    "environment_name": "...",
    "resource_token": "...",
    "release_version": "...",
    "release_profile": "...",
    "deploy_mode": "..."
  }
}
```

Retrieve `last_failed_step` and `failure_logs_tail` through authenticated GitHub
MCP, `gh run view`, or another authenticated backend status path.

## Handoff to tests-manager

Only hand off to tests-manager when baseline checks pass and the operator
requested the post-deploy test or load-trigger phase. Provide frontend URL, API
URL, release profile, release version, revision name, and ACR image tag when
available.

## Rollback

If release fails baseline validation or a regression is reported:

1. Re-dispatch `${WORKFLOW_FILE}` with the previous known-good
   `release_version`.
2. Keep the same `release_profile` unless the operator chooses another
   supported profile.
3. Use `deploy_mode=deploy` when infrastructure is unchanged.
4. Re-run baseline validation.

## Reporting Contract

Produce a structured release summary with:

- resolved release inputs
- dispatch path used
- run_id, run_url, conclusion, duration
- baseline checks pass/fail per item
- next step: tests-manager handoff, rollback, connector authorization repair, or
  human review
- references: revision name, ACR image tag, App Insights resource ID, Log
  Analytics workspace ID when available

When blocked or evidence is incomplete, include:

- blocked path: `github-cli`, `github-mcp`, `built-in-triggerworkflow`,
  `connector-authorization`, `non-authoritative-shell`, or `azure-evidence`
- first failing status/code/message
- next operator action required
- evidence statement when applicable: `healthy environment observed, requested
  release inputs unproven`

Never report `unexpected_type:GitHubOAuth`, never ask to restore `GitHubPat`, and
never ask for dispatch-capable PAT proof when the GitHub connector is OAuth.
Report OAuth failures as connector authorization or scope/permission issues with
the actual failing status.

## Optional Documentation PR Gate

If a post-deploy documentation update or PR is requested, verify authenticated
GitHub access before creating commits, pushing branches, or opening a PR. Keep
PR work separate from the deployment result.