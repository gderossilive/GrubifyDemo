# Grubify - Food Delivery App

A modern food delivery application built with React TypeScript frontend and .NET backend, designed for deployment to Azure Container Apps using Azure Developer CLI (azd).

## 🍕 Features

- **Modern UI**: Beautiful, responsive design inspired by popular food delivery apps
- **Real Food Content**: Sample restaurants and food items with real images from Unsplash
- **Complete Food Delivery Flow**: Browse restaurants → Add to cart → Checkout → Track orders
- **Azure Container Apps**: Scalable, serverless container hosting
- **Azure Developer CLI**: One-command deployment and management

## 🏗️ Architecture

- **Frontend**: React 18 + TypeScript + Material-UI
- **Backend**: .NET 9 Web API with RESTful endpoints
- **Infrastructure**: Azure Container Apps + Azure Container Registry (ACR)
- **Deployment**: Azure Developer CLI (azd) with remote ACR builds — no local Docker required

## 🚀 Complete Deployment Guide

This guide shows how to deploy Grubify with **both backend versions** (v1 with memory leak, v2 with payment failures) for testing Azure SRE Agent scenarios.

## 📋 Prerequisites

Before deploying Grubify, ensure you have the following tools installed:

### Required Tools
- **[Azure Developer CLI (azd)](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd)** - Latest version
- **[Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)** - For additional Azure operations
- **Azure Subscription** - With Contributor/Owner permissions

> **Note**: Docker Desktop is **not required**. Container images are built directly in Azure Container Registry using ACR Tasks (remote builds).

## 🚀 Quick Start

### 1. Prerequisites Check
Before starting, run the automated prerequisites check script:

```bash
./scripts/check-prerequisites.sh
```

### 2. Initial Azure Setup

```bash
# Clone the repository
git clone https://github.com/gderossilive/GrubifyDemo.git
cd GrubifyDemo

# Login to Azure
azd auth login
az login --use-device-code

# Initialize azd environment
azd init

# Set Azure location (must be swedencentral — SRE Agent preview constraint)
azd env set AZURE_LOCATION swedencentral
```

### 3. Deploy Infrastructure & Applications

```bash
# Deploy infrastructure and applications
azd up
```

This creates:
- **Resource Group**: `rg-grubify-app`
- **Container Registry**: `crgrubify` — images are built here via ACR Tasks
- **Container Apps Environment**: `cae-grubify`
- **API Container App**: `ca-grubify-api`
- **Frontend Container App**: `ca-grubify-frontend`
- **Log Analytics Workspace**: `log-grubify`

### 4. Deploy the SRE Agent

The SRE Agent deployment script creates a dedicated SRE resource group,
Application Insights, a managed identity, Azure Monitor HTTP 5xx alerting,
ServiceNow incident routing, knowledge uploads, custom sub-agents, and the
ServiceNow response-plan filter. Azure Monitor supplies the HTTP 5xx signal;
ServiceNow is the incident system of record and the SRE Agent incident platform.

Create a local `.env` file with your subscription and optional notification
settings, plus ServiceNow credentials for incident routing:

```bash
AZURE_SUBSCRIPTION_ID=<your-subscription-id>
AZURE_LOCATION=swedencentral
INCIDENT_NOTIFICATION_EMAIL=<optional-email-address>
SERVICENOW_INSTANCE=<instance>
# Or set SERVICENOW_INSTANCE_URL=https://<instance>.service-now.com
SERVICENOW_USERNAME=<servicenow-user>
SERVICENOW_PASSWORD=<servicenow-password>
SERVICENOW_ASSIGNMENT_GROUP=<optional-servicenow-group-sys-id-or-name>
SERVICENOW_INDEXING_LOOKBACK_DAYS=30
```

Then run:

```bash
./scripts/deploy-sre-agent.sh
```

This creates:
- **SRE Resource Group**: `rg-grubify-sre`
- **SRE Agent**: `sre-agent-grubify`
- **Action Group**: `ag-sre-grubify`
- **HTTP 5xx Alert**: `alert-http-5xx-grubify`
- **ServiceNow Logic App URL**: saved locally in `.azure/servicenow-handler-url`
- **ServiceNow incident platform**: configured on the SRE Agent with native ServiceNow tools
- **AGT Governance Function URL**: emitted by azd as `AGT_FUNCTION_URL`
- **ServiceNow response filter**: `grubify-http-errors`, routed to `incident-handler-agt`

The deployment uploads all Markdown files in `knowledge/` and checks whether
they are indexed by SRE Agent memory. It also deploys a fixed sub-agent
allow-list: `code-analyzer`, `issue-triager`, `incident-handler-core`, and
`incident-handler-agt`. The governed `incident-handler-agt` is the default
ServiceNow response-plan target; `incident-handler-core.yaml` remains available
as an ungoverned fallback. `incident-handler-full.yaml` is kept in the repo as
a reserved/manual variant and is intentionally skipped because it shares the
same `spec.name` as the core handler.

The AGT governance Function App is deployed by azd as the `governance` service.
Verify it before deploying SRE content:

```bash
curl "$AGT_FUNCTION_URL/api/ready"
curl "$AGT_FUNCTION_URL/api/health"
```

### 5. ServiceNow Incident Routing

ServiceNow is the primary incident platform for the Grubify incident demo. The
deployment follows a native ServiceNow system-of-record pattern:

```text
Azure Monitor alert -> Action Group Logic App receiver -> ServiceNow incident
	-> SRE Agent ServiceNow incident platform -> incident-handler-agt
```

ServiceNow routing is enabled by default. Add these settings to `.env` before
running `./scripts/deploy-sre-agent.sh`:

```bash
ENABLE_SERVICENOW_HANDLER=true
SERVICENOW_INSTANCE=<instance>
# Or set SERVICENOW_INSTANCE_URL=https://<instance>.service-now.com
SERVICENOW_USERNAME=<servicenow-user>
SERVICENOW_PASSWORD=<servicenow-password>
SERVICENOW_ASSIGNMENT_GROUP=<optional-assignment-group>
SERVICENOW_INDEXING_LOOKBACK_DAYS=30
SERVICENOW_CATEGORY=software
```

The script deploys Logic App
`la-grubify-servicenow-handler` into `rg-grubify-sre`, stores its callback URL
in `.azure/servicenow-handler-url`, and wires `ag-sre-grubify` with a Logic App
receiver named `sre-logic-app`. The Logic App creates the ServiceNow incident,
then acknowledges the Azure Monitor alert with a comment such as `Routed to
ServiceNow incident INC0012345.` It does not forward an enriched payload to the
SRE Agent.

The SRE Agent is configured with native `ServiceNow` incident management. The
deployment validates the ServiceNow endpoint through the SRE backend and saves
ServiceNow incident indexing configuration at the SRE API. Incident indexing
requires an assignment group; if `SERVICENOW_ASSIGNMENT_GROUP` is empty, the
script tries common ServiceNow groups such as `Software`, `Service Desk`,
`Incident Management`, and `Help Desk`. The `grubify-http-errors` response
filter then routes matching ServiceNow incidents to `incident-handler-agt`,
which retrieves details with `GetServiceNowIncident`, has each tool call checked
by AGT governance hooks, and updates the ServiceNow record throughout the
lifecycle.

Set `ENABLE_SERVICENOW_HANDLER=false` only when you intentionally want the
direct Azure Monitor -> SRE Agent webhook fallback for local testing.

Verify the ServiceNow route:

```bash
az monitor action-group show \
	--resource-group rg-grubify-sre \
	--name ag-sre-grubify \
	--query "{logicAppReceivers:logicAppReceivers[].{name:name,useCommonAlertSchema:useCommonAlertSchema},webhookCount:length(webhookReceivers)}" \
	-o table

az rest --method get \
	--url "https://management.azure.com/subscriptions/<subscription-id>/resourceGroups/rg-grubify-sre/providers/Microsoft.Logic/workflows/la-grubify-servicenow-handler/runs?api-version=2016-06-01&\$top=5" \
	--query "value[].{status:properties.status,startTime:properties.startTime,endTime:properties.endTime}" \
	-o table
```

Azure Monitor does not replay an alert notification if the action group was
empty when the alert first fired. After fixing action group wiring, wait for the
metric alert to transition and fire again, or use Azure Monitor action-group test
notifications to validate the receiver path.

### 6. Optional Microsoft Teams Connector

Teams notification is optional. The normal incident flow still works when Teams
is not configured. To enable Teams checks in the deploy script, add these values
to `.env` before running `./scripts/deploy-sre-agent.sh`:

```bash
ENABLE_TEAMS_CONNECTOR=true
TEAMS_TENANT_ID=<entra-tenant-id>
TEAMS_GROUP_ID=<teams-group-id>
TEAMS_CHANNEL_ID=<teams-channel-id>
TEAMS_CLIENT_ID=<optional-app-client-id>
TEAMS_CLIENT_SECRET=<optional-app-client-secret>
```

The current SRE Agent preview API exposes connector listing but did not expose a
supported connector create/auth endpoint during validation. Applying the local
Teams connector YAML returns `Unsupported kind: DataConnector`. Because of that,
the script verifies whether a Microsoft Teams connector and Teams tools exist,
but it does not silently create or authenticate the connector. Register and
authenticate the Teams connector in the SRE Agent portal when required, then
rerun the script to verify it. A healthy portal-created connector exposes tools
such as `PostTeamsMessage`, `GetTeamsMessages`, and `ReplyToTeamsMessage`.

Verify connector and tool state:

```bash
AZURESRE_TOKEN=$(az account get-access-token \
	--resource "https://azuresre.ai" \
	--query accessToken -o tsv)

curl -s "$AGENT_ENDPOINT/api/v1/extendedAgent/dataconnectors" \
	-H "Authorization: Bearer $AZURESRE_TOKEN"

curl -s "$AGENT_ENDPOINT/api/v1/extendedAgent/systemtools" \
	-H "Authorization: Bearer $AZURESRE_TOKEN" | grep -i teams
```

### 7. Ready for SRE Scenarios

Now you have:
- ✅ **Frontend deployed** and working
- ✅ **Backend deployed** and working
- ✅ **Infrastructure configured** for testing scenarios

**SRE Agent Setup:**
1. **Deploy agent** with `./scripts/deploy-sre-agent.sh`
2. **Authorize the GitHub repo**: **https://github.com/gderossilive/GrubifyDemo** in the SRE Agent portal if prompted
3. **Configure ServiceNow** with the `.env` variables above so ServiceNow owns the incident record
4. **Enable Teams** with the `.env` variables above and portal connector setup when you want Teams notifications
5. **Simulate memory leak** by sending repeated `POST /api/cart/demo-user/items` requests to the API Container App
6. **Review the run** in ServiceNow, the SRE Agent portal, Teams, and GitHub depending on configured connectors

