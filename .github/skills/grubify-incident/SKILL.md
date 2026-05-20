---
name: grubify-incident
description: >
  Run the Grubify Incident demo (Act 1: IT Operations). Triggers a memory leak in the Grubify
  container app, then observes the SRE Agent autonomously detect the HTTP 5xx alert, diagnose
  OOM as root cause, and remediate. USE FOR: break grubify app, trigger memory leak, run incident
  demo, Demo4, OOM simulation, SRE Agent remediation demo. DO NOT USE FOR: issue triage
  (use grubify-issue-triage), deploying grubify (use azd up), GitHub integration.
---

# Grubify Incident — Demo Skill

Run **Act 1: IT Operations** for the GrubifyIncidentLab demo. Trigger a memory leak in Grubify,
then watch the SRE Agent autonomously detect the HTTP 5xx alert, diagnose OOM as root cause,
and remediate.

## Working directory

Run commands from this repository workspace:

```bash
cd /workspaces/GrubifyDemo
```

## Step 1: Source environment values

```bash
APP_URL="https://$(az containerapp show -g rg-grubify-app-ids7x -n ca-grubify-api-ids7x --query properties.configuration.ingress.fqdn -o tsv)"
SRE_RG="rg-grubify-sre-sn-test-05191511"
AGENT="sre-agent-grubify"
```

All values must be set. Use environment-specific resource group names if your deployment uses a different token.

## Step 2: Verify prerequisites

### 2a) Grubify is healthy

```bash
APP_URL="https://$(az containerapp show -g rg-grubify-app-ids7x -n ca-grubify-api-ids7x --query properties.configuration.ingress.fqdn -o tsv)"
curl -s -o /dev/null -w "Restaurants: HTTP %{http_code}\n" "${APP_URL}/api/restaurants"
```

`/api/restaurants` must return HTTP 200. The current API has no dedicated `/health` endpoint.

### 2b) SRE Agent is Autonomous

```bash
az resource show -g "$SRE_RG" -n "$AGENT" \
  --resource-type Microsoft.App/agents \
  --query '{mode:properties.actionConfiguration.mode, accessLevel:properties.actionConfiguration.accessLevel}' -o json
```

Must show `mode: autonomous`.

## Step 3: Trigger the memory leak

```bash
url="${APP_URL}/api/cart/demo-user/items"
body='{"foodItemId":1,"quantity":1,"specialInstructions":"demo memory pressure"}'
for i in $(seq 1 200); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST -H "Content-Type: application/json" -d "$body" "$url"
done | sort | uniq -c
```

This sends 200 rapid POST requests to `/api/cart/demo-user/items`, flooding the in-memory cart
until the container approaches its 1Gi memory limit. Expect errors in later requests as memory
pressure builds.

## Step 4: Wait for alert + agent investigation

- Wait **5-8 minutes** for memory pressure to build and Azure Monitor to fire the HTTP 5xx alert.
- Azure Monitor calls the action group's Logic App receiver. The Logic App creates a ServiceNow incident and acknowledges the Azure Monitor alert.
- Direct the user to open ServiceNow and https://sre.azure.com → **Incidents** to watch the ServiceNow-backed investigation.

### What the agent does autonomously

1. Queries container logs for error patterns using KQL
2. Checks memory/CPU metrics via Azure Monitor
3. Searches the knowledge base for the HTTP 500 runbook
4. Identifies OOM / memory leak as root cause
5. Executes remediation (restart or scale the container)
6. Generates Python charts as evidence
7. Stores findings in memory for future incident correlation
8. Updates the ServiceNow incident throughout the lifecycle

## Step 5: Verify recovery

After the agent remediates:

```bash
APP_URL="https://$(az containerapp show -g rg-grubify-app-ids7x -n ca-grubify-api-ids7x --query properties.configuration.ingress.fqdn -o tsv)"
curl -s -o /dev/null -w "Restaurants: HTTP %{http_code}\n" "${APP_URL}/api/restaurants"
```

Should return HTTP 200.

## Reset (if needed)

To manually reset the demo without waiting for the agent, restart the active revision:

```bash
RG="rg-grubify-app-ids7x"
CA_NAME="ca-grubify-api-ids7x"
REVISION=$(az containerapp revision list -g "$RG" -n "$CA_NAME" --query '[0].name' -o tsv)
az containerapp revision restart -g "$RG" -n "$CA_NAME" --revision "$REVISION"
```

## Success criteria

- [ ] The cart POST burst completes with errors in the final requests (memory pressure)
- [ ] Logic App creates a ServiceNow incident
- [ ] SRE Agent portal shows an incident being investigated
- [ ] Agent identifies memory leak / OOM as root cause
- [ ] Container app recovers (HTTP 200 on API endpoints)

## Constraints

- Do not manually restart the container — let the agent remediate
- This demo does not require GitHub integration
