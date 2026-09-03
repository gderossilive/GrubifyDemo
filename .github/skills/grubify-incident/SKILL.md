---
name: grubify-incident
description: >
  Retired cart-memory-leak incident demo. The cart endpoint no longer retains request buffers,
  so this skill must not be used to generate an OOM or HTTP 5xx incident. USE FOR: verifying that
  the retired scenario is not run. DO NOT USE FOR: triggering memory pressure, issue triage,
  deployment, or GitHub integration.
---

# Grubify Incident — Retired Cart OOM Scenario

The cart memory-leak scenario was retired after the permanent fix removed the unbounded request-buffer cache. Do not send a cart POST flood or expect an OOM/HTTP 5xx alert from the cart endpoint.

## Working directory

Run commands from this repository workspace:

```bash
cd /workspaces/GrubifyDemo
```

## Step 1: Source environment values

```bash
APP_RG="rg-grubify-app-agt01"
API_CA="ca-grubify-api-agt01"
SRE_RG="rg-grubify-sre-agt01"
AGENT="sre-agent-grubify"
LOGIC_APP="la-grubify-servicenow-handler"
ALERT="alert-http-5xx-grubify"
APP_URL="https://$(az containerapp show -g "$APP_RG" -n "$API_CA" --query properties.configuration.ingress.fqdn -o tsv)"
```

All values must be set. Use environment-specific resource group names if your deployment uses a different token.

## Step 2: Verify prerequisites

### 2a) Grubify is healthy

```bash
APP_URL="https://$(az containerapp show -g "$APP_RG" -n "$API_CA" --query properties.configuration.ingress.fqdn -o tsv)"
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

### 2c) Alert and ServiceNow receiver are wired

```bash
az monitor metrics alert show -g "$SRE_RG" -n "$ALERT" \
  --query '{enabled:enabled,severity:severity,actions:actions[].actionGroupId}' -o json

az logic workflow show -g "$SRE_RG" -n "$LOGIC_APP" \
  --query '{state:state,provisioningState:provisioningState}' -o json
```

The alert must be enabled and the Logic App must be enabled/succeeded.

## Retired procedure

Do not run the former 200-request cart POST flood. It was designed to exercise the removed 10 MiB-per-request cache and will no longer create memory pressure, an OOM, or an HTTP 5xx alert.

## Validation after deployment

Use a normal cart write and read to verify the fixed endpoint:

```bash
curl -s -o /dev/null -w "Cart add: HTTP %{http_code}\n" \
  -X POST -H "Content-Type: application/json" \
  -d '{"foodItemId":1,"quantity":1}' \
  "${APP_URL}/api/cart/demo-user/items"
curl -s -o /dev/null -w "Cart read: HTTP %{http_code}\n" \
  "${APP_URL}/api/cart/demo-user"
```

Both requests should return HTTP 200 without a restart or an alert.

## Constraints

- Do not use the cart endpoint for intentional memory-pressure testing.
- This retired scenario does not require GitHub integration.
