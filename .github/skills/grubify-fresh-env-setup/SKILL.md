---
name: grubify-fresh-env-setup
description: >
  End-to-end runbook to bootstrap a brand new Grubify environment with azd,
  fix token/resource-group pitfalls, grant SRE Agent access, and deploy SRE
  data-plane content (knowledge, subagents, and skills). USE FOR: create fresh
  environment, azd env bootstrap, new token setup, SRE Agent access setup,
  postdeploy/apply-extras recovery. DO NOT USE FOR: incident demo execution
  (use grubify-incident), issue triage demo (use grubify-issue-triage).
---

# Grubify Fresh Environment Setup — Runbook Skill

Use this skill to create and stabilize a **new Grubify environment** from scratch,
including SRE Agent access and content deployment.

## Working directory

```bash
cd /workspaces/GrubifyDemo
```

## Step 1: Create and select a fresh azd environment

```bash
ENV_NAME="new02"
AZ_SUB="06dbbc7b-2363-4dd4-9803-95d07f1a8d3e"
AZ_LOC="swedencentral"

azd env new "$ENV_NAME" --location "$AZ_LOC"
azd env select "$ENV_NAME"
azd env set AZURE_LOCATION "$AZ_LOC"
azd env set AZURE_SUBSCRIPTION_ID "$AZ_SUB"
```

## Step 2: Set token and resource group variables explicitly

Do this **before** deploying to avoid `rg-grubify-app-` (empty suffix).

```bash
# Use a 5-char unique token; for ENV_NAME=new02, token=new02 works.
TOKEN="new02"

azd env set GRUBIFY_RESOURCE_TOKEN "$TOKEN"
azd env set AZURE_RESOURCE_GROUP "rg-grubify-app-$TOKEN"
azd env set SRE_AGENT_RESOURCE_GROUP "rg-grubify-sre-$TOKEN"
azd env set SRE_AGENT_NAME "sre-agent-grubify"
azd env set AGT_FUNCTION_URL "https://func-agt-grubify-$TOKEN.azurewebsites.net"
```

Validate:

```bash
azd env get-values | grep -E "AZURE_ENV_NAME|GRUBIFY_RESOURCE_TOKEN|AZURE_RESOURCE_GROUP|SRE_AGENT_RESOURCE_GROUP|SRE_AGENT_NAME|AGT_FUNCTION_URL"
```

## Step 3: Deploy infra + apps

```bash
azd up --no-prompt
```

Verify deployment completion:

```bash
az deployment sub list --query "[?contains(name, '$ENV_NAME-')].{name:name,state:properties.provisioningState,timestamp:properties.timestamp}" -o table
```

Verify app and SRE RG names are correct:

```bash
az group list --query "[?contains(name, 'rg-grubify-app-$TOKEN') || contains(name, 'rg-grubify-sre-$TOKEN')].name" -o tsv
```

## Step 4: Grant SRE Agent Administrator to the operator

Fresh environments require SRE data-plane RBAC. ARM Owner alone can be insufficient.

```bash
UPN="admin@M365x16397930.onmicrosoft.com"
USER_OBJ_ID=$(az ad user show --id "$UPN" --query id -o tsv)
AGENT_ID=$(az resource show \
  -g "rg-grubify-sre-$TOKEN" \
  -n "sre-agent-grubify" \
  --resource-type Microsoft.App/agents \
  --api-version 2025-05-01-preview \
  --query id -o tsv)

az role assignment create \
  --assignee-object-id "$USER_OBJ_ID" \
  --assignee-principal-type User \
  --role "SRE Agent Administrator" \
  --scope "$AGENT_ID"
```

Verify:

```bash
az role assignment list \
  --assignee-object-id "$USER_OBJ_ID" \
  --scope "$AGENT_ID" \
  --include-inherited \
  --query "[?contains(roleDefinitionName,'SRE Agent')].{role:roleDefinitionName,scope:scope}" -o table
```

## Step 5: Apply SRE data-plane content

Run postdeploy content flow (knowledge + subagents + repos + skills):

```bash
azd hooks run postdeploy
```

If hook fails or was run with stale env values, apply directly:

```bash
set -a && eval "$(azd env get-values)" && set +a
python3 bin/assemble-agent.py
python3 bin/apply-extras.py
```

## Step 6: Validate runtime resources

```bash
az resource show \
  -g "rg-grubify-sre-$TOKEN" \
  -n "sre-agent-grubify" \
  --resource-type Microsoft.App/agents \
  --api-version 2025-05-01-preview \
  --query "{provisioningState:properties.provisioningState,runningState:properties.runningState,endpoint:properties.agentEndpoint}" -o json

az containerapp show -g "rg-grubify-app-$TOKEN" -n "ca-grubify-api-$TOKEN" \
  --query "{provisioningState:properties.provisioningState,runningStatus:properties.runningStatus,fqdn:properties.configuration.ingress.fqdn}" -o json

az containerapp show -g "rg-grubify-app-$TOKEN" -n "ca-grubify-frontend-$TOKEN" \
  --query "{provisioningState:properties.provisioningState,runningStatus:properties.runningStatus,fqdn:properties.configuration.ingress.fqdn}" -o json
```

## Step 7: Validate SRE content counts

```bash
AGENT_EP=$(az resource show \
  -g "rg-grubify-sre-$TOKEN" \
  -n "sre-agent-grubify" \
  --resource-type Microsoft.App/agents \
  --api-version 2025-05-01-preview \
  --query properties.agentEndpoint -o tsv)
TOK=$(az account get-access-token --resource https://azuresre.ai --query accessToken -o tsv)

curl -sS "$AGENT_EP/api/v2/extendedAgent/skills" -H "Authorization: Bearer $TOK"
curl -sS "$AGENT_EP/api/v1/extendedAgent/subagents" -H "Authorization: Bearer $TOK"
```

Expected portal state:
- Subagents: 6
- Skills: 2
- Knowledge sources populated

## Recovery playbook for common failures

### A) App RG became `rg-grubify-app-`
Cause: missing `GRUBIFY_RESOURCE_TOKEN` during deployment.

Fix:
1. Set `GRUBIFY_RESOURCE_TOKEN` and `AZURE_RESOURCE_GROUP` in azd env.
2. If global resource names already collided (storage/function/app plan), switch to a new unique 5-char token.
3. Re-run `azd up`.

### B) `apply-extras.py` targets wrong SRE RG
Cause: stale `SRE_AGENT_RESOURCE_GROUP` in azd env.

Fix:
1. `azd env set SRE_AGENT_RESOURCE_GROUP rg-grubify-sre-<token>`
2. Re-run `azd hooks run postdeploy` or `python3 bin/apply-extras.py`.

### C) Portal shows `Skills = 0`
Cause: standalone skills were not deployed, only subagent prompts were updated.

Fix:
1. Ensure `python3 bin/assemble-agent.py` generates non-empty `skills` in `build/agent.extras.json`.
2. Run `python3 bin/apply-extras.py` to push `/api/v2/extendedAgent/skills/*`.
3. Hard refresh SRE portal.

## Success criteria

- [ ] New app RG and SRE RG have correct token suffix
- [ ] `azd up` is `Succeeded`
- [ ] User has `SRE Agent Administrator` on SRE Agent resource
- [ ] SRE content applied successfully (knowledge + 6 subagents + 2 skills)
- [ ] API and frontend container apps are running
- [ ] SRE portal shows expected configuration after refresh
