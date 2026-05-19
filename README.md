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
response-plan webhook. Azure Monitor supplies the HTTP 5xx signal; ServiceNow
is the incident system of record.

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
- **SRE Trigger URL**: saved locally in `.azure/sre-trigger-url`
- **ServiceNow Logic App URL**: saved locally in `.azure/servicenow-handler-url`

The deployment uploads all Markdown files in `knowledge/` and checks whether
they are indexed by SRE Agent memory. It also deploys a fixed sub-agent
allow-list: `code-analyzer`, `issue-triager`, and `incident-handler-core`.
`incident-handler-full.yaml` is kept in the repo as a reserved/manual variant
and is intentionally skipped because it shares the same `spec.name` as the core
handler.

### 5. ServiceNow Incident Routing

ServiceNow is the primary incident platform for the Grubify incident demo. The
deployment follows the ServiceNowAzureResourceHandler pattern from the
AzSreAgentLab parent demo:

```text
Azure Monitor alert -> Logic App -> ServiceNow incident -> SRE Agent
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
SERVICENOW_CATEGORY=software
```

The script deploys Logic App
`la-grubify-servicenow-handler` into `rg-grubify-sre`, stores its callback URL
in `.azure/servicenow-handler-url`, and points `ag-sre-grubify` at the Logic
App. The Logic App creates the ServiceNow incident first, then forwards the
original Azure Monitor alert plus `serviceNow.number`, `serviceNow.sysId`, and
`serviceNow.url` to the SRE Agent trigger.

Set `ENABLE_SERVICENOW_HANDLER=false` only when you intentionally want the
direct Azure Monitor -> SRE Agent webhook fallback for local testing.

Verify the ServiceNow route:

```bash
az monitor action-group show \
	--resource-group rg-grubify-sre \
	--name ag-sre-grubify \
	--query "properties.webhookReceivers[].name" \
	-o table

az logic workflow run list \
	--resource-group rg-grubify-sre \
	--name la-grubify-servicenow-handler \
	--query "[0:5].{status:status,startTime:startTime}" \
	-o table
```

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
5. **Simulate memory leak** with `./scripts/break-app.sh`
6. **Review the run** in ServiceNow, the SRE Agent portal, Teams, and GitHub depending on configured connectors

