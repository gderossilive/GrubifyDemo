# HTTP 500 Error Investigation Runbook

## Trigger Keywords
`500 error`, `internal server error`, `HTTP 500`, `server error`, `application error`, `memory leak`, `OOM`, `cart API`

## Scope
This runbook is for the Grubify demo application in this repository root.

Use it when the backend Azure Container App starts returning HTTP 5xx and Azure Monitor routes the incident to the SRE Agent.

This runbook is tied to:

- Azure deployment: `azure.yaml`
- Infrastructure: `infra/`
- SRE Agent deployment automation: `scripts/deploy-sre-agent.sh`
- Backend application source: `GrubifyApi/`
- Frontend application source: `grubify-frontend/`
- Upstream GitHub repository: `https://github.com/gderossilive/GrubifyDemo`

This demo primarily uses:

- Azure Monitor resource metrics
- Log Analytics tables for Azure Container Apps
- Container Apps control plane and logs

Do not assume rich application telemetry in Application Insights for the Grubify API. In the current implementation, Application Insights is primarily wired to SRE Agent logging, not to full app request, dependency, or exception instrumentation for the application.

---

## Lab-Specific Facts

### Deployed Application Shape

- Backend: ASP.NET Core Web API
- Frontend: React
- Backend Container App: `ca-grubify-api`
- Frontend Container App: `ca-grubify-frontend`
- Resource group: `rg-grubify-app`
- Container Apps environment: often reused from an existing environment; resolve the actual managed environment and Log Analytics workspace at investigation time

### Active Alert Configuration

The demo deploys one primary alert for this scenario:

- Resource: backend Container App (`ca-grubify-api`)
- Metric namespace: `microsoft.app/containerapps`
- Metric: `Requests`
- Dimension: `statusCodeCategory = 5xx`
- Threshold: `> 5` in `5` minutes
- Severity: `2`
- Alert name: `alert-http-5xx-grubify`

### Historical Root Cause Pattern In This Lab

A common intentional failure path in this lab has been the cart endpoint in:

- `GrubifyApi/Controllers/CartController.cs`

In some deployments, `POST /api/cart/{userId}/items` allocates and retains a new `10 MB` byte array on every request:

```csharp
var requestData = new byte[10 * 1024 * 1024];
RequestDataCache.Add(requestData);
```

Repeated requests to `/api/cart/demo-user/items` can then cause steady memory growth until the API starts returning HTTP 5xx and may restart under memory pressure.

Important: do not assume the checked-in branch always matches the running image. If live logs, stack traces, or deployed revision behavior disagree with the repository contents, trust the runtime evidence first and capture the source/runtime drift in the incident notes.

### Important Endpoint Notes

- There is no dedicated `/health` endpoint in the current API.
- There is no `/api/menu` endpoint in the current API.
- Prefer these endpoints for validation:
  - `GET /weatherforecast`
  - `GET /api/restaurants`
  - `GET /api/fooditems`
  - `POST /api/cart/demo-user/items`

---

## Valid Azure Monitor Metric Names For Container Apps

Use only these metric names with `az monitor metrics list`:

- `UsageNanoCores` for CPU usage
- `WorkingSetBytes` for memory usage
- `Requests` for request count
- `RestartCount` for container restarts
- `Replicas` for active replica count
- `CpuPercentage` for CPU percentage
- `MemoryPercentage` for memory percentage

---

## Investigation Workflow

## Phase 1: Identify The Actual Backend Resource

Resolve the current environment values first. This repository's `azd` deployment writes the resource group and URLs into the environment, while the app names are fixed in Bicep.

```bash
cd GrubifyDemo

azd env get-value AZURE_RESOURCE_GROUP
azd env get-value API_BASE_URL
azd env get-value FRONTEND_URL
```

You should expect values shaped like:

- Resource group: `rg-grubify-app`
- Backend app: `ca-grubify-api`
- Frontend app: `ca-grubify-frontend`

Get the backend resource ID because it is needed for metrics queries:

```bash
RG=$(azd env get-value AZURE_RESOURCE_GROUP)
APP=ca-grubify-api
FRONTEND=ca-grubify-frontend

az containerapp show -g "$RG" -n "$APP" --query id -o tsv
az containerapp show -g "$RG" -n "$FRONTEND" --query id -o tsv
```

If the `azd` environment is unavailable, fall back to the fixed resource group and list the apps directly:

```bash
RG=rg-grubify-app
az containerapp list -g "$RG" -o table
```

---

## Phase 2: Confirm The Symptom On Real Endpoints

Do not use `/health` or `/api/menu` for this lab.

```bash
APP_URL=$(azd env get-value CONTAINER_APP_URL)

curl -i "$APP_URL/weatherforecast"
curl -i "$APP_URL/api/restaurants"
curl -i "$APP_URL/api/fooditems"
curl -i -X POST "$APP_URL/api/cart/demo-user/items" \
  -H "Content-Type: application/json" \
  -d '{"foodItemId":1,"quantity":1}'
```

Interpretation:

- If `restaurants` and `fooditems` are still `200` but `cart` is failing, suspect the intentional memory leak path first.
- If all endpoints fail, check for app restart loops, revision issues, or broad resource exhaustion.

---

## Phase 3: Check Metrics First

Start with backend Container App metrics. This lab is designed so metrics are often the highest-signal evidence.

### 3.1 Azure CLI Metrics

```bash
RESOURCE_ID=$(az containerapp show -g "$RG" -n "$APP" --query id -o tsv)
START=$(date -u -d '1 hour ago' +"%Y-%m-%dT%H:%M:%SZ")
END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

az monitor metrics list --resource "$RESOURCE_ID" --metric "WorkingSetBytes" --interval PT5M --start-time "$START" --end-time "$END"
az monitor metrics list --resource "$RESOURCE_ID" --metric "MemoryPercentage" --interval PT5M --start-time "$START" --end-time "$END"
az monitor metrics list --resource "$RESOURCE_ID" --metric "RestartCount" --interval PT5M --start-time "$START" --end-time "$END"
az monitor metrics list --resource "$RESOURCE_ID" --metric "Requests" --interval PT5M --start-time "$START" --end-time "$END"
az monitor metrics list --resource "$RESOURCE_ID" --metric "CpuPercentage" --interval PT5M --start-time "$START" --end-time "$END"
```

### 3.2 AzureMetrics KQL

```kql
AzureMetrics
| where TimeGenerated > ago(1h)
| where ResourceProvider == "MICROSOFT.APP"
| where ResourceId has "/containerApps/ca-grubify-"
| where MetricName in ("WorkingSetBytes", "MemoryPercentage", "RestartCount", "Requests", "CpuPercentage")
| summarize AvgValue = avg(Average), MaxValue = max(Maximum), Total = sum(Total) by bin(TimeGenerated, 5m), MetricName, ResourceId
| order by TimeGenerated desc
```

### Resource Interpretation

| Signal | What it means in this lab |
|--------|----------------------------|
| `WorkingSetBytes` climbs steadily | Strong evidence of the cart leak |
| `MemoryPercentage` trends toward 100 | Container approaching 1 Gi limit |
| `RestartCount` increments | Likely OOM or crash restart |
| `Requests` with 5xx alert firing | Confirms incident trigger path |
| CPU moderate but memory high | More consistent with leak than CPU saturation |

---

## Phase 4: Inspect Container Logs

### 4.1 Container App Logs CLI

Use `--tail`, not `--since`.

```bash
az containerapp logs show -g "$RG" -n "$APP" --tail 300
az containerapp logs show -g "$RG" -n "$APP" --tail 300 --format text
```

### 4.2 Console Log Query

The cart leak emits useful console messages from the application code.

```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerName_s contains "grubify"
| where Log_s contains "Analytics cache" or Log_s contains "Cache size" or Log_s contains "error" or Log_s contains "exception" or Log_s contains "500"
| project TimeGenerated, ContainerName_s, Log_s
| order by TimeGenerated desc
```

These strings are especially relevant because `CartController` writes:

- `Analytics cache: Added request data. Total entries: ...`
- `Cache size: ...MB`

### 4.3 System Log Query For Restarts

```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerName_s contains "grubify"
| where Log_s contains "restart" or Log_s contains "crash" or Log_s contains "OOM" or Log_s contains "revision"
| project TimeGenerated, ContainerName_s, RevisionName_s, Log_s
| order by TimeGenerated desc
```

### 4.4 OOM-Focused Query

```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerName_s contains "grubify"
| where Log_s contains "OutOfMemory" or Log_s contains "OOM" or Log_s contains "memory pressure" or Log_s contains "heap" or Log_s contains "Cache size"
| project TimeGenerated, ContainerName_s, Log_s
| order by TimeGenerated desc
```

---

## Phase 5: Correlate The Failure To Source Code

For this demo, source correlation should start with the local repository checkout and, if enabled, continue to GitHub.

### Local Source Paths

- Backend API: `GrubifyApi/`
- Leak implementation: `GrubifyApi/Controllers/CartController.cs`

### Primary Root Cause Candidate

Inspect `CartController.AddItemToCart` first, but validate it against the running revision before assuming the checked-in file is authoritative.

What to look for:

1. Static mutable state that survives across requests.
2. Request-scoped buffers retained indefinitely.
3. Console logs proving cache growth.
4. Stack traces or line numbers from the running image that may not match the current branch.

If the deployed image shows OOMs or cache-growth logs on the cart path but the checked-in source does not, treat that as source/runtime drift and document both facts explicitly.

### Optional GitHub Correlation

If GitHub integration was configured during agent deployment, the agent may have:

- GitHub connector support for this repository
- Repository target: `gderossilive/GrubifyDemo`
- GitHub-aware subagents: `incident-handler`, `code-analyzer`, `issue-triager`

In that case, create or update a GitHub issue against the remote repository with:

- incident summary
- affected endpoint
- metric evidence
- log evidence
- source-level root cause
- remediation recommendation

---

## Phase 6: Recommended Remediation Paths

Choose the least invasive action that restores service and preserves evidence.

### Immediate Mitigations

#### Option A: Restart The Active Revision

Use when the service is already degraded and you need fast recovery.

```bash
az containerapp revision list -g "$RG" -n "$APP" -o table

REVISION=$(az containerapp revision list -g "$RG" -n "$APP" --query "[?properties.active].name | [0]" -o tsv)
az containerapp revision restart -g "$RG" -n "$APP" --revision "$REVISION"
```

#### Option B: Increase Replica Floor

Use when errors are intermittent and you need more headroom while the root cause is being fixed.

```bash
az containerapp update -g "$RG" -n "$APP" --min-replicas 3
```

#### Option C: Scale Memory-Constrained Workload

If the incident pattern is clearly memory pressure and a temporary config change is acceptable, update the Container App resources through the deployment pipeline rather than by hand-editing infrastructure state without tracking it. Prefer a documented follow-up change in Bicep or the app definition.

### When Not To Roll Back

Do not default to rollback for this scenario. The common failure in this lab is not a generic bad deploy. It is an intentional code-level leak triggered through `/api/cart/demo-user/items`.

---

## Phase 7: App Insights Queries Are Optional Only

The current Grubify API does not clearly configure rich request/dependency/exception telemetry to Application Insights. Queries against these tables may return sparse or empty results:

- `requests`
- `dependencies`
- `exceptions`
- `performanceCounters`

Use them only as supplemental evidence if data exists. Do not block diagnosis on them.

If data is present, these queries can still help:

```kql
requests
| where timestamp > ago(1h)
| where resultCode startswith "5"
| summarize FailedCount = count() by name, resultCode, url
| order by FailedCount desc
```

```kql
exceptions
| where timestamp > ago(1h)
| summarize Count = count() by type, outerMessage
| order by Count desc
```

---

## Quick Diagnosis Checklist

| Check | What to confirm |
|-------|------------------|
| Resource identity | You are analyzing `ca-grubify-*`, not the frontend app |
| Trigger path | Alert came from backend `Requests` metric with 5xx dimension |
| Endpoint validation | Use `/weatherforecast`, `/api/restaurants`, `/api/fooditems`, `/api/cart/...` |
| Memory trend | `WorkingSetBytes` and `MemoryPercentage` rise before or during errors |
| Restart evidence | `RestartCount` increases or system logs show restart/OOM events |
| Cart leak evidence | Logs show `Analytics cache` or `Cache size` growth |
| Source correlation | `CartController.AddItemToCart` or the deployed image stack trace explains the failure path |
| Source/runtime drift | Live logs and line numbers may be valid even if the checked-in branch no longer shows the same leak |
| GitHub path | If MCP is configured, file/update issue in `dm-chelupati/grubify` |

---

## Common Root Causes In This Lab

| Symptom | Likely cause | Next step |
|---------|--------------|-----------|
| `POST /api/cart/.../items` fails first | Intentional cart memory leak | Gather memory/log evidence, restart or scale, file code fix |
| Memory rises steadily, CPU not saturated | Leak, not CPU bottleneck | Prioritize memory evidence and restart history |
| All endpoints fail after memory growth | Container restart loop or broad resource exhaustion | Inspect `RestartCount`, revision health, system logs |
| 5xx appears after manual load test | Expected lab trigger from `break-app.sh` | Correlate timeline to cart POST flood |

---

## Escalation Criteria

Escalate immediately if any of these are true:

- Error rate remains high after restart or scale action.
- `RestartCount` continues to rise after mitigation.
- Both backend and frontend become unavailable.
- The issue does not correlate to the cart leak and suggests a broader platform or deployment problem.
- The agent lacks permission to execute the needed Container Apps action.

---

## Expected Investigation Summary

When closing the incident or creating a GitHub issue, include:

1. Backend app name, resource group, and incident time window.
2. Alert that fired: backend `Requests` metric with 5xx dimension.
3. Evidence from `AzureMetrics` showing memory growth and any restarts.
4. Evidence from `ContainerAppConsoleLogs_CL` or `ContainerAppSystemLogs_CL`.
5. Endpoint-level symptom, especially whether `/api/cart/demo-user/items` failed first.
6. Root cause tied to `CartController.AddItemToCart` and the retained `10 MB` request buffers.
7. Immediate mitigation taken, if any.
8. Follow-up code fix recommendation.

That is the correct investigation path for HTTP 500 incidents in the Grubify Incident Lab as currently implemented in this repository.
