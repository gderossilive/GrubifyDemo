# Grubify Incident Lab Architecture

## Overview

This knowledge file describes the actual implementation of the Grubify incident lab in this repository.

- Deployment entry point: `azure.yaml`
- Infrastructure: `infra/`
- SRE Agent automation: `scripts/deploy-sre-agent.sh`
- Application source used by the lab: `GrubifyApi/` and `grubify-frontend/`
- Repository: `https://github.com/gderossilive/GrubifyDemo.git`

This lab does not deploy a generic Node.js container. It deploys the vendored Grubify application in this repo:

- Backend: ASP.NET Core Web API (`GrubifyApi`)
- Frontend: React frontend (`grubify-frontend`)
- Hosting: Azure Container Apps
- Agent platform: Azure SRE Agent with ServiceNow-backed incident routing

---

## Deployment Model

The app is deployed with `azd up` from the repository root.

### Control Plane

`azure.yaml` provisions the application and infrastructure through Bicep:

- `infra.provider: bicep`
- `infra.path: infra`
- service definitions for the React frontend and .NET API

Container images are built remotely with Azure Container Registry Tasks, so the demo does not require a local Docker daemon.

### Azure Resource Topology

`infra/main.bicep` is subscription-scoped and creates a dedicated application
resource group. By default, resource names use a five-character
`resourceToken` derived from the azd environment name, or a caller-supplied
`GRUBIFY_RESOURCE_TOKEN`/`RESOURCE_TOKEN` during SRE configuration.

| Resource | Azure type | Naming pattern | Purpose |
|----------|------------|----------------|---------|
| Resource group | `Microsoft.Resources/resourceGroups` | `rg-grubify-app-${resourceToken}` | Isolates app resources |
| Container Apps environment | `Microsoft.App/managedEnvironments` | `cae-${resourceToken}` | Shared environment for backend, frontend, and app logs |
| Backend Container App | `Microsoft.App/containerApps` | `ca-grubify-api-${resourceToken}` | Hosts the Grubify API |
| Frontend Container App | `Microsoft.App/containerApps` | `ca-grubify-frontend-${resourceToken}` | Hosts the React frontend |
| Azure Container Registry | `Microsoft.ContainerRegistry/registries` | environment-derived ACR name | Remote image builds |
| Governance Function App | `Microsoft.Web/sites` | `func-agt-grubify-${resourceToken}` | AGT hook policy service |
| SRE resource group | `Microsoft.Resources/resourceGroups` | `rg-grubify-sre-${resourceToken}` | Isolates SRE Agent resources |
| Log Analytics workspace | `Microsoft.OperationalInsights/workspaces` | `law-sre-grubify` | Stores agent/app investigation data |
| Application Insights | `Microsoft.Insights/components` | `appi-sre-grubify` | Stores SRE Agent telemetry |
| User-assigned managed identity | `Microsoft.ManagedIdentity/userAssignedIdentities` | `id-sre-grubify` | Agent action and knowledge graph identity |
| SRE Agent | `Microsoft.App/agents` | `sre-agent-grubify` | Incident detection and remediation |
| Action Group | `Microsoft.Insights/actionGroups` | `ag-sre-grubify` | Alert action target |
| Metric alert | `Microsoft.Insights/metricAlerts` | `alert-http-5xx-grubify` | Triggers on backend HTTP 5xx |
| ServiceNow Logic App | `Microsoft.Logic/workflows` | `la-grubify-servicenow-handler` | Opens ServiceNow incidents from alerts |

---

## Container App Configuration

The deployment creates two Container Apps in the same Container Apps environment.

### Backend API Container App

Defined through the `infra/core/host/container-app.bicep` module:

- Name pattern: `ca-grubify-api-${resourceToken}`
- External ingress: `true`
- Target port: `8080`
- CPU: `0.5`
- Memory: `1Gi`
- Scale: `minReplicas: 1`, `maxReplicas: 1`
- Initial image: placeholder hello-world image, later replaced by post-provision deployment

Runtime environment variables configured in Bicep:

- `ASPNETCORE_ENVIRONMENT=Production`
- `AllowedOrigins__0=https://ca-grubify-frontend-${resourceToken}.<container-app-domain>`

That matches the backend CORS policy in `GrubifyApi/Program.cs`.

### Frontend Container App

Also defined through the `infra/core/host/container-app.bicep` module:

- Name pattern: `ca-grubify-frontend-${resourceToken}`
- External ingress: `true`
- Target port: `80`
- Scale: `minReplicas: 1`, `maxReplicas: 1`

Frontend runtime configuration is injected through:

- `REACT_APP_API_BASE_URL=https://<backend-fqdn>/api`

---

## Build And Release Flow

The lab uses Azure Developer CLI service definitions and remote ACR builds to turn the provisioned infrastructure into a runnable demo.

### Image Build

The script runs remote builds in ACR:

- API image source: `GrubifyApi/Dockerfile`
- API image tag: `grubify-api:latest`
- Frontend image source: `grubify-frontend/Dockerfile`
- Frontend image tag: `grubify-frontend:latest`

### Deployment Updates

After the ACR builds finish, the script updates both Container Apps with `az containerapp update`.

This means the actual running demo is built from the source in this repository, not from a prebuilt public image.

---

## Monitoring And Alerting

### Telemetry Signal Storage — What Is Collected And Where

| Signal type | What is collected | Storage | Query surface |
|---|---|---|---|
| **Logs** | Container stdout/stderr (`Console.WriteLine`, ASP.NET Core request logs) | Log Analytics workspace (`law-${uniqueSuffix}`) — table `ContainerAppConsoleLogs_CL` | `QueryLogAnalyticsByWorkspaceId`, KQL |
| **Metrics** | Azure Monitor Container Apps platform metrics only (`Requests`, `WorkingSetBytes`, `CpuUsage`, `RestartCount`, `Replicas`) — no custom app metrics | Azure Monitor (automatic, no SDK required) | `az monitor metrics list`, Azure portal |
| **Traces** | **None.** The Grubify API has no OpenTelemetry SDK, no `Activity` instrumentation, and no App Insights SDK configured. No distributed traces are collected. | N/A | N/A |
| **Agent telemetry** | SRE Agent internal telemetry (not Grubify app telemetry) | Application Insights (`appi-${uniqueSuffix}`) | `QueryAppInsightsByResourceId` |

See `grubify-app-architecture.md` for the per-endpoint breakdown of the application surface and telemetry expectations.

### Log Analytics

The Container Apps environment is configured with:

- `destination: log-analytics`
- Log Analytics workspace ID and shared key from the monitoring module

This is where the incident runbooks expect to query Container Apps logs.

### Application Insights

In this lab, Application Insights is created in `monitoring.bicep` and wired into the SRE Agent through `modules/sre-agent.bicep`:

- `properties.logConfiguration.applicationInsightsConfiguration.appId`
- `properties.logConfiguration.applicationInsightsConfiguration.connectionString`

This Application Insights instance stores SRE Agent internal telemetry only. The Grubify API does not configure the Application Insights SDK so no application-level traces, requests, or exceptions flow into this instance. The app investigation workflow relies on:

- Azure Monitor resource metrics (no SDK required)
- Container Apps platform logs in Log Analytics

### Alert Rule

The active alert configured by the lab is a single metric alert on the backend Container App:

- Metric namespace: `microsoft.app/containerapps`
- Metric name: `Requests`
- Dimension: `statusCodeCategory = 5xx`
- Threshold: `> 5`
- Aggregation: `Total`
- Window: `PT5M`
- Evaluation frequency: `PT1M`
- Severity: `3`

This alert is intentionally simple. The SRE Agent is expected to determine whether the 5xx symptom is caused by memory pressure, an OOM restart, a code bug, or another runtime issue.

---

## SRE Agent Configuration

The SRE Agent is created by `scripts/deploy-sre-agent.sh` with:

- API version: `2025-05-01-preview`
- Name: `sre-agent-grubify`
- Identity type: `SystemAssigned, UserAssigned`
- Knowledge graph managed resource scope: the demo resource group
- Action mode: `autonomous`
- Access level: `High`

The agent starts with an empty `mcpServers` list in ARM and is configured further by the post-provision script.

### Managed Identity Permissions

`scripts/deploy-sre-agent.sh` creates the user-assigned identity
`id-sre-grubify` and grants it the roles needed for the demo environment:

- `Monitoring Reader` on the app resource group
- `Contributor` on the app resource group
- `Monitoring Reader` on the SRE resource group

This is the permission set the agent uses to inspect resources, query
telemetry, and perform write actions such as Container App remediation. The
validated `grubify-agt` environment has these assignments on
`rg-grubify-app-agt01` and `rg-grubify-sre-agt01`.

### Incident Platform Wiring

Azure Monitor remains the HTTP 5xx metric signal source, but ServiceNow is the incident system of record. The deployment creates an Azure Monitor metric alert and action group, then routes the action group through a Logic App receiver. The Logic App opens a ServiceNow incident and acknowledges the Azure Monitor alert; the SRE Agent receives the incident later through its native ServiceNow incident platform, not through a forwarded HTTP payload.

The deployment creates a response plan filter:

- Filter ID: `grubify-http-errors`
- Incident type: `ServiceNow`
- Handling agent: `incident-handler-agt`
- Mode: `autonomous`

So the runtime flow is:

1. Backend Container App emits HTTP 5xx.
2. Azure Monitor metric alert fires.
3. The action group calls the ServiceNow Logic App.
4. The Logic App opens a ServiceNow incident and acknowledges the Azure Monitor alert with a comment that references the ServiceNow incident number.
5. The SRE Agent ServiceNow incident platform detects the ServiceNow incident.
6. The `grubify-http-errors` response plan routes the ServiceNow incident to `incident-handler-agt`, which retrieves the incident details from ServiceNow, evaluates tool calls through AGT governance hooks, and updates/resolves the ServiceNow record.

ServiceNow incident indexing requires an assignment group. `SERVICENOW_ASSIGNMENT_GROUP` can provide one explicitly; otherwise the deploy script tries common ServiceNow groups such as `Software`, `Service Desk`, `Incident Management`, and `Help Desk`. The deploy script sends `providerType: servicenow` when saving indexing configuration, but the current ServiceNow-specific GET response omits that field; verify indexing by checking `assignmentGroup` and `lookbackDays`. Azure Monitor does not replay notifications that fired while the action group had no valid receiver, so action-group wiring must be correct before the next alert transition.

---

## Knowledge Base And Subagents

The post-provision script uploads all Markdown files in `knowledge/` into Agent Memory. That includes:

- `grubify-infra-architecture.md` — deployment model, resource topology, monitoring wiring (this file)
- `grubify-app-architecture.md` — component graph, API/entity relationships, fault injection map, observability gaps
- `http-500-errors.md`
- `incident-report-template.md`
- `github-issue-triage.md` when GitHub integration is enabled

### Always-Created Subagents

The deployment always applies these custom agents:

- `incident-handler-core.yaml` as `incident-handler`
- `incident-handler-agt.yaml` as `incident-handler-agt` for the governed default ServiceNow response path
- `code-analyzer.yaml`
- `issue-triager.yaml`

`incident-handler-core.yaml` remains available as an ungoverned fallback.
`incident-handler-full.yaml` is kept as a manual/reserved variant and is intentionally skipped in normal deployment because it shares the same `spec.name` as the core handler.

Core tools used by `incident-handler-agt`:

- `SearchMemory`
- `RunAzCliReadCommands`
- `RunAzCliWriteCommands`
- `GetAzCliHelp`
- `QueryLogAnalyticsByWorkspaceId`
- `QueryAppInsightsByResourceId`
- `ExecutePythonCode`

### GitHub-Enabled Subagents

The deployment configures the SRE Agent code repo entry. GitHub issue triage
still depends on a valid GitHub token/connector and the `issue-triager` agent.

The default target repository is `${GITHUB_USER}/GrubifyDemo` when `GITHUB_REPO` is not set. Set `GITHUB_REPO` explicitly for forks or alternate demo repositories.

The data-plane `GitHubOAuth` connector created by `bin/apply-extras.py` is not
enabled by default because the current backend reports that connector type as
deprecated/disconnected. Authenticate GitHub OAuth from **Builder → Connectors**
or the GitHub MCP connection with `repo` and `workflow` scopes for the no-PAT
path. For fully repeatable non-portal automation, explicitly set
`ENABLE_GITHUB_AUTH_CONNECTOR=true`, `GITHUB_AUTH_CONNECTOR_TYPE=pat`, and
`GITHUB_PAT` so `bin/apply-extras.py` creates a `GitHubPat` connector.

Likewise, the assembler no longer emits `KnowledgeText` ARM connectors for each
markdown file in `knowledge/` (`ENABLE_KNOWLEDGE_CONNECTORS=false` by default).
Those files are still uploaded as proper **Knowledge sources** through the
data-plane `/api/v1/agentmemory/upload` endpoint and remain searchable via
`SearchMemory`.

---

## GitHub Repository Mapping

There are two repository contexts in this lab:

### 1. Local Source Used For Deployment

The app that Azure runs comes from the source in this repository:

- `GrubifyApi/`
- `grubify-frontend/`

### 2. Remote Repository Used By GitHub MCP

When GitHub integration is enabled, the SRE Agent uses the configured GitHub repository to inspect source and create or update issues. By default, that repository is:

- `${GITHUB_USER}/GrubifyDemo`

That is why the YAML specs use `GITHUB_REPO_PLACEHOLDER` and the deploy script resolves it before creating GitHub-aware subagents.

---

## Application Surface Actually Deployed

The backend routes are implemented by ASP.NET Core controllers under `GrubifyApi/Controllers/`.

Representative endpoints exposed by the deployed API include:

| Endpoint | Method | Implementation |
|----------|--------|----------------|
| `/weatherforecast` | `GET` | `WeatherForecastController` |
| `/api/restaurants` | `GET` | `RestaurantsController.GetRestaurants` |
| `/api/restaurants/{id}` | `GET` | `RestaurantsController.GetRestaurant` |
| `/api/restaurants/search?query=` | `GET` | `RestaurantsController.SearchRestaurants` |
| `/api/fooditems` | `GET` | `FoodItemsController.GetFoodItems` |
| `/api/fooditems/{id}` | `GET` | `FoodItemsController.GetFoodItem` |
| `/api/fooditems/restaurant/{restaurantId}` | `GET` | `FoodItemsController.GetFoodItemsByRestaurant` |
| `/api/orders` | `POST` | `OrdersController.PlaceOrder` |
| `/api/orders/{id}` | `GET` | `OrdersController.GetOrder` |
| `/api/orders/user/{userId}` | `GET` | `OrdersController.GetUserOrders` |
| `/api/cart/{userId}` | `GET` | `CartController.GetCart` |
| `/api/cart/{userId}/items` | `POST` | `CartController.AddItemToCart` |
| `/api/cart/{userId}/items/{itemId}` | `PUT` | `CartController.UpdateCartItem` |
| `/api/cart/{userId}` | `DELETE` | `CartController.ClearCart` |

Notes:

- There is no dedicated `/health` endpoint in the current API.
- There is no `/api/menu` route in the current API.
- The lab’s fault injection and investigation should focus on the routes above.

---

## Actual Failure Mode Used By The Demo

The intentional incident is implemented in `GrubifyApi/Controllers/CartController.cs`.

The `POST /api/cart/{userId}/items` handler does two things that matter for the incident:

1. It stores carts in a static in-memory dictionary: `UserCarts`.
2. It allocates a new `10 MB` byte array for every request and appends it to the static `RequestDataCache` list.

That second behavior is the direct memory leak in the current code:

- `var requestData = new byte[10 * 1024 * 1024];`
- `RequestDataCache.Add(requestData);`

Under repeated calls to `/api/cart/demo-user/items`, memory grows without cleanup until the container approaches its `1Gi` memory limit. The observed symptom becomes HTTP 5xx responses and potentially container restarts.

### Trigger Mechanism

The incident demo repeatedly calls:

```bash
POST /api/cart/demo-user/items
```

with a JSON body like:

```json
{"foodItemId":1,"quantity":1}
```

The script defaults to:

- `200` requests
- `0.5` seconds between requests

---

## Troubleshooting Anchored To This Lab

### Primary Resources To Inspect

- Backend Container App: `ca-grubify-api-${resourceToken}`
- Frontend Container App: `ca-grubify-frontend-${resourceToken}`
- Container Apps environment: `cae-${resourceToken}` unless an existing environment is supplied
- Governance Function App: `func-agt-grubify-${resourceToken}`
- SRE Agent: `sre-agent-grubify`
- Metric alert: `alert-http-5xx-grubify`
- ServiceNow Logic App: `la-grubify-servicenow-handler`

### Metrics That Match The Runbook

The runbook in `knowledge/http-500-errors.md` is aligned to Azure Container Apps metrics such as:

- `UsageNanoCores`
- `WorkingSetBytes`
- `Requests`
- `RestartCount`
- `Replicas`
- `CpuPercentage`
- `MemoryPercentage`

### Useful Log Query Shape

For Container Apps console logs in the linked Log Analytics workspace:

```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where Log_s contains "error" or Log_s contains "exception" or Log_s contains "500"
| summarize ErrorCount = count() by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

---

## Summary

The Grubify incident lab in this repository is a Bicep + azd + Azure Container Apps deployment of a .NET API and React frontend, with an Azure SRE Agent configured to consume ServiceNow incidents created from Azure Monitor HTTP 5xx alerts and optionally integrate with GitHub.

The architecture is intentionally simple:

- one resource group per environment
- one backend Container App that fails under a real code-level memory leak
- one frontend Container App
- one Log Analytics workspace for app logs
- one Application Insights instance for agent telemetry
- one SRE Agent with autonomous ServiceNow-backed incident handling
- one HTTP 5xx alert that routes through a Logic App into ServiceNow
- one ServiceNow response filter that routes matching incidents to `incident-handler-agt`

That is the implementation agents should reason from when diagnosing Grubify incidents in this lab.

---

## Related Knowledge

- `grubify-app-architecture.md` — component dependency graph, entity model, fault injection map, and observability gaps (what the app actually emits vs. what is detectable)
