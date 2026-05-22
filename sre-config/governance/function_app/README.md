# AGT Governance Function App

This Azure Functions app evaluates SRE Agent hook events for the Grubify `incident-handler-agt` sub-agent.

## Endpoints

- `GET /api/ready` returns a readiness response.
- `GET /api/health` reports the active AGT policy and rule count.
- `POST /api/hook` evaluates hook requests from the SRE Agent hook bridge.

## Deployment

The app is deployed by azd as the `governance` service. Bicep provisions the Linux Python Function App and outputs `AGT_FUNCTION_URL`, which `scripts/deploy-sre-agent.sh` embeds into the governed sub-agent hooks.

In the validated `grubify-agt` environment, the Function App is
`func-agt-grubify-agt01` in the application resource group
`rg-grubify-app-agt01`. The SRE Agent deployment script reads
`AGT_FUNCTION_URL` from the azd environment or from the caller's environment
and injects it into `incident-handler-agt.yaml` hook scripts.

## Configuration

- `AGT_POLICY_PATH`: policy file path, default `policies/grubify-sre-agent-policy-agt.yaml`.
- `AGT_MODE`: governance mode, default `agt-policy`.
- `AGT_AUDIT_STDOUT`: when `true`, emits governance decisions to stdout for platform logs.

## Policy Behavior

The default policy blocks source-code and shell-execution tools for the
governed runtime incident handler. It also checks final incident summaries for
the words `incident`, `root cause`, `evidence`, and `remediation`. Source-code
analysis should be handed off to `code-analyzer`; the default ServiceNow
incident filter routes HTTP 5xx incidents to the governed `incident-handler-agt`.
