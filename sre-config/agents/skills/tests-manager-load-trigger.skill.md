# Tests Manager Skill: Cart Load Trigger

Use this skill as the execution contract for post-deploy validation and alert-trigger testing.

## Required Inputs

Do not begin execution until the operator confirms all of the following:

- Target API URL (approved Grubify demo API ingress, https only).
- Target user ID (default: demo-user).
- Explicit approval to run the cart load trigger.

If any input is missing or ambiguous, stop and ask.

## Baseline Smoke Checks

Run in order. All must pass before stress testing starts.

1. GET {API_URL}/api/restaurants -> expect HTTP 200 and JSON array.
2. GET {API_URL}/api/fooditems -> expect HTTP 200 and JSON array.
3. GET {API_URL}/api/cart/{userId} -> expect HTTP 200 and cart object.
4. POST {API_URL}/api/cart/{userId}/items with payload below -> expect HTTP 2xx and updated cart.

Payload:

```json
{
  "foodItemId": 1,
  "quantity": 1,
  "specialInstructions": "post-deploy validation"
}
```

If any baseline check fails: classify as deployment validation failure, report, and stop.

## Alert Trigger Load Profile

Default sustained profile:

- max_requests = 1500
- max_duration_seconds = 900
- workers = 6
- sleep_seconds = 0.1
- target_5xx = 6

Only use a lighter profile if the operator explicitly requests it.

Stop when any condition is met:

- total 5xx responses observed >= 6
- Azure Monitor alert is confirmed fired
- container revision restart is observed
- max requests or max duration reached

## ExecutePythonCode Pattern

```python
import time
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed

API_URL = "<provided by operator>"
USER_ID = "demo-user"
ENDPOINT = f"{API_URL}/api/cart/{USER_ID}/items"
PAYLOAD = {"foodItemId": 1, "quantity": 1, "specialInstructions": "load-trigger"}
MAX_REQUESTS = 1500
MAX_DURATION_SECONDS = 15 * 60
WORKERS = 6
SLEEP_SECONDS = 0.1
TARGET_5XX = 6

start = time.time()
sent = 0
errors_5xx = 0


def hit_once(_):
    try:
        r = requests.post(ENDPOINT, json=PAYLOAD, timeout=10)
        return r.status_code
    except Exception:
        return 599


with ThreadPoolExecutor(max_workers=WORKERS) as pool:
    while sent < MAX_REQUESTS and time.time() - start <= MAX_DURATION_SECONDS and errors_5xx < TARGET_5XX:
        burst = min(WORKERS, MAX_REQUESTS - sent)
        futures = [pool.submit(hit_once, i) for i in range(burst)]
        sent += burst
        for f in as_completed(futures):
            status = f.result()
            if status >= 500:
                errors_5xx += 1
        time.sleep(SLEEP_SECONDS)

print({"sent": sent, "errors_5xx": errors_5xx, "elapsed_sec": int(time.time() - start)})
```

## Telemetry Observation Cadence

During the loop, every 50 requests or 30 seconds:

- Query Log Analytics for cart cache growth log lines.
- Query App Insights requests for 5xx on /api/cart/.../items.
- Check memory trend and restart evidence for the API Container App.

## Reporting Contract

Always produce:

- baseline smoke check outcomes
- final load profile used
- request volume, 5xx total, elapsed time
- evidence timestamps (logs, memory rise, 5xx, restart, alert)
- next step recommendation (handoff to incident-handler when incident evidence appears)

## Guardrails

- Never run outside approved Grubify demo environment.
- Never exceed profile limits.
- Distinguish baseline failure from expected post-trigger incident evidence.
- Never modify infrastructure and never invoke write tools.
