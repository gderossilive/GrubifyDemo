# Grubify Post-Deploy Tests Runbook

This runbook documents how the `tests-manager` SRE Agent subagent runs
controlled post-deploy validation tests and the cart load trigger that
intentionally exercises the memory-leak path in
`GrubifyApi/Controllers/CartController.cs`.

`tests-manager` is invoked AFTER `deployment-manager` confirms a healthy
baseline. It never deploys code or mutates infrastructure.

## When to use

Use this runbook for any post-deploy validation in the Grubify demo
environment. The cart load trigger section is only used for the
`cart-leak-baseline` Step 0 demo flow.

## Required inputs

Before starting, confirm:

- Target API URL (Grubify Container Apps `api` ingress, https only).
- Target user ID (default `demo-user`).
- Operator approval to run the cart load trigger.
- The target API URL belongs to the approved Grubify demo environment.

If any input is missing or unconfirmed, stop and ask.

## Baseline smoke checks

Run these first. They must all succeed before the load trigger starts.

1. `GET {API_URL}/api/restaurants` → expect HTTP 200 and a JSON array.
2. `GET {API_URL}/api/fooditems` → expect HTTP 200 and a JSON array.
3. `GET {API_URL}/api/cart/demo-user` → expect HTTP 200 and a cart object.
4. `POST {API_URL}/api/cart/demo-user/items` with the payload below → expect
   HTTP 200 and an updated cart object.

Sample payload for the cart POST smoke check and load trigger:

```json
{
  "foodItemId": 1,
  "quantity": 1,
  "specialInstructions": "post-deploy validation"
}
```

If any baseline check fails, classify it as a deployment validation failure,
report it, and STOP. Do not start the load trigger.

## Cart load trigger

Only run this phase after baseline smoke checks pass.

### Loop limits

- Maximum requests: **200**
- Maximum duration: **8 minutes**
- Concurrency: **1** (single client, serial requests)
- Sleep between requests: **0.5s** (tune lower only with explicit approval)

### Procedure

Send repeated `POST {API_URL}/api/cart/demo-user/items` requests using the
sample payload, until any stop condition is met or the loop limits are
reached.

### Expected evidence

The cart endpoint allocates a retained 10 MB byte array per request, so
expect to observe:

- API logs containing `Analytics cache: Added request data. Total entries: N`
  and `Cache size: N MB`.
- Steady increase in `WorkingSetBytes` or memory-related metrics on the API
  Container App.
- HTTP 5xx responses on `POST /api/cart/demo-user/items` once memory
  pressure builds.
- Container App revision restart events.
- The configured HTTP 5xx alert firing in Azure Monitor.

### Stop conditions

Stop the loop as soon as one of these is observed:

- HTTP 5xx response from the cart POST endpoint.
- Container App revision restart.
- Configured alert fires.
- Loop limit (request count or duration) reached.

### Sample Python pattern (for ExecutePythonCode)

```python
import time
import requests

API_URL = "<provided by operator>"
ENDPOINT = f"{API_URL}/api/cart/demo-user/items"
PAYLOAD = {"foodItemId": 1, "quantity": 1, "specialInstructions": "load-trigger"}
MAX_REQUESTS = 200
MAX_DURATION_SECONDS = 8 * 60
SLEEP_SECONDS = 0.5

start = time.time()
for i in range(1, MAX_REQUESTS + 1):
    if time.time() - start > MAX_DURATION_SECONDS:
        break
    r = requests.post(ENDPOINT, json=PAYLOAD, timeout=10)
    if r.status_code >= 500:
        break
    time.sleep(SLEEP_SECONDS)
```

## Telemetry checks during the loop

Periodically (e.g., every 20 requests) query:

- Log Analytics for `Analytics cache` / `Cache size` log lines.
- App Insights `requests` table for HTTP 5xx on `/api/cart/.../items`.
- Container App memory metrics.

## Reporting

Produce a structured test report containing:

- Baseline smoke check results.
- Load trigger configuration (request count, payload, target URL,
  duration, sleep).
- Observed evidence with timestamps (cache-growth logs, memory growth,
  HTTP 5xx, container restart, alert firing).
- Whether expected incident-trigger evidence appeared, and after how many
  requests / how long.
- Recommended next step (typically handoff to `incident-handler`).

## Guardrails

- Never exceed the documented loop limits.
- Never run the load trigger outside the approved demo environment.
- Distinguish failure types:
  - Baseline failures = deployment validation failed; do NOT start the
    load trigger.
  - Post-trigger HTTP 5xx / OOM = expected demo evidence; hand off to
    `incident-handler`.
- Never modify infrastructure or invoke write tools.

## References

- Subagent: `sre-config/agents/tests-manager.yaml`
- Instructions: `sre-config/agents/instructions/tests-manager.instructions.md`
- Deployment runbook: `knowledge/grubify-deployment-runbook.md`
- Cart bug source: `GrubifyApi/Controllers/CartController.cs`
- Incident runbook: `knowledge/http-500-errors.md`
