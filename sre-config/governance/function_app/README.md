# AGT Governance Function App

This Azure Functions app evaluates SRE Agent hook events for the Grubify `incident-handler-agt` sub-agent.

## Endpoints

- `GET /api/ready` returns a readiness response.
- `GET /api/health` reports the active AGT policy and rule count.
- `POST /api/hook` evaluates hook requests from the SRE Agent hook bridge.

## Deployment

The app is deployed by azd as the `governance` service. Bicep provisions the Linux Python Function App and outputs `AGT_FUNCTION_URL`, which `scripts/deploy-sre-agent.sh` embeds into the governed sub-agent hooks.

## Configuration

- `AGT_POLICY_PATH`: policy file path, default `policies/grubify-sre-agent-policy-agt.yaml`.
- `AGT_MODE`: governance mode, default `agt-policy`.
- `AGT_AUDIT_STDOUT`: when `true`, emits governance decisions to stdout for platform logs.
