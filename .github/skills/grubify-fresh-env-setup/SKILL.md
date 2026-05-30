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

# SRE Agent sandbox VNet integration is opt-in while the preview data plane
# returns 404 for VNet-enabled agent sites in this environment.
azd env set ENABLE_SRE_AGENT_VNET_INTEGRATION false

# Override CIDRs only if enabling VNet integration.
azd env set SRE_AGENT_VNET_ADDRESS_PREFIX "10.80.0.0/16"
azd env set SRE_AGENT_SUBNET_ADDRESS_PREFIX "10.80.0.0/24"
```

With `ENABLE_SRE_AGENT_VNET_INTEGRATION=false`, the agent is created without
`vnetConfiguration` so the portal and data-plane APIs serve normally. If VNet
integration is explicitly enabled, the deployment provisions
`vnet-sre-agent-$TOKEN` and `snet-sre-agent-$TOKEN` in the SRE resource group and
associates the subnet with a NAT Gateway. Patch sandbox egress to `Unrestricted`
for open outbound access after agent creation. To use an existing subnet instead,
set `EXISTING_SRE_AGENT_SUBNET_RESOURCE_ID` before the first deploy. The subnet
must be in the same Azure region as the agent, delegated to
`Microsoft.App/environments`, and have outbound connectivity. Do not change this
value after agent creation; the agent `subnetResourceId` is immutable.

Validate:

```bash
azd env get-values | grep -E "AZURE_ENV_NAME|GRUBIFY_RESOURCE_TOKEN|AZURE_RESOURCE_GROUP|SRE_AGENT_RESOURCE_GROUP|SRE_AGENT_NAME|AGT_FUNCTION_URL|ENABLE_SRE_AGENT_VNET_INTEGRATION|SRE_AGENT_.*ADDRESS_PREFIX"
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

If VNet integration is enabled, verify the SRE Agent delegated subnet and sandbox egress settings:

```bash
az network vnet subnet show \
  -g "rg-grubify-sre-$TOKEN" \
  --vnet-name "vnet-sre-agent-$TOKEN" \
  -n "snet-sre-agent-$TOKEN" \
  --query "{addressPrefix:addressPrefix,delegations:delegations[].serviceName}" -o json

az resource show \
  -g "rg-grubify-sre-$TOKEN" \
  -n "sre-agent-grubify" \
  --resource-type Microsoft.App/agents \
  --api-version 2025-05-01-preview \
  --query "{provisioningState:properties.provisioningState,subnet:properties.vnetConfiguration.subnetResourceId,endpoint:properties.agentEndpoint}" -o json
```

For any fresh or restored agent, verify the portal and data-plane route before applying content:

```bash
TOK=$(az account get-access-token --resource https://azuresre.ai --query accessToken -o tsv)
EP=$(az resource show \
  -g "rg-grubify-sre-$TOKEN" \
  -n "sre-agent-grubify" \
  --resource-type Microsoft.App/agents \
  --api-version 2025-05-01-preview \
  --query properties.agentEndpoint -o tsv)

curl -sS -o /dev/null -w "%{http_code}\n" "$EP/" -H "Authorization: Bearer $TOK"
curl -sS -o /dev/null -w "%{http_code}\n" "$EP/api/v2/extendedAgent/agents" -H "Authorization: Bearer $TOK"
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

## Step 5b: Configure GitHub auth for deployment-manager

The `deployment-manager` subagent is configured with `github-mcp/*`,
`connectors: [github]`, and a `RunInTerminal` fallback that uses
`gh workflow run`. The platform uses the connected GitHub repository OAuth/PAT
credential automatically for supported GitHub operations. For arbitrary workflow
dispatch such as `deploy-grubify.yml`, this repo also provisions a Key Vault in
the SRE Agent resource group and stores the terminal fallback PAT as secret
`GH-PAT`.

For `new02`, do not create a data-plane `GitHubOAuth` connector with
`bin/apply-extras.py`; the current backend reports that connector type as
deprecated/disconnected. Instead, authorize the repository in the SRE portal /
GitHub MCP flow and make sure authorization includes `repo` and `workflow`
scopes. If the OAuth app was authorized without `workflow`, re-authorize the
connector rather than adding an unrelated local PAT.

After `azd up` creates the Key Vault, store a workflow-capable PAT without
printing it:

```bash
set -a && eval "$(azd env get-values)" && set +a
read -rsp "GitHub PAT: " GITHUB_PAT && echo
az keyvault secret set \
  --vault-name "kv-sre-grubify-${GRUBIFY_RESOURCE_TOKEN}" \
  --name "${SRE_GITHUB_PAT_SECRET_NAME:-GH-PAT}" \
  --value "$GITHUB_PAT" \
  --output none
unset GITHUB_PAT
```

The Bicep deployment grants both SRE Agent identities `Key Vault Secrets User`
on this vault. The deployment-manager fallback retrieves `GH-PAT`, exports it as
`GH_TOKEN` for `gh workflow run`, and unsets it after the command.

For fully repeatable non-portal connector automation only, opt into PAT
connector mode:

```bash
set -a && eval "$(azd env get-values)" && set +a
ENABLE_GITHUB_AUTH_CONNECTOR=true GITHUB_AUTH_CONNECTOR_TYPE=pat GITHUB_PAT=<token-with-workflow-scope> \
  python3 bin/apply-extras.py \
  --skip-knowledge --skip-subagents --skip-skills
```

Default expected output without PAT mode:
```
  Code repos : 1 GitHub repo(s)
    skipped connector/github (ENABLE_GITHUB_AUTH_CONNECTOR is false)
    applied repo/GrubifyDemo
```

If the backend already registered the same URL as `repo/github`, the apply script
will reuse that existing repo name and print `applied repo/github`.

Verify:
```bash
AGENT_EP=$(azd env get-values | grep SRE_AGENT_ENDPOINT | cut -d= -f2 | tr -d '"')
TOKEN=$(az account get-access-token --resource https://azuresre.ai --query accessToken -o tsv)
curl -s "$AGENT_EP/api/v2/extendedAgent/connectors/github/status" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('type:', d.get('type'))
print('healthy:', d.get('healthy'))
print('status:', d.get('status'))
print('message:', d.get('message'))
"
```

Expected for default portal/MCP OAuth: the code repo is connected/ready and no
data-plane `GitHubOAuth` connector is required. OAuth tokens are
backend-managed and are not expected to be readable from connector metadata.

Also grant `SRE Agent Administrator` to both agent managed identities (otherwise
the subagent gets 403 when reading its own connector keys at runtime):

```bash
SCOPE=$(az resource show \
  -g "rg-grubify-sre-$TOKEN" -n "sre-agent-grubify" \
  --resource-type Microsoft.App/agents \
  --api-version 2025-05-01-preview --query id -o tsv)

for id in $(az resource show \
  -g "rg-grubify-sre-$TOKEN" -n "sre-agent-grubify" \
  --resource-type Microsoft.App/agents \
  --api-version 2025-05-01-preview \
  --query "identity.userAssignedIdentities | values(@)[].principalId" -o tsv); do
  echo "Granting SRE Agent Administrator to $id"
  az role assignment create \
    --assignee-object-id "$id" \
    --assignee-principal-type ServicePrincipal \
    --role "SRE Agent Administrator" \
    --scope "$SCOPE"
done
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

### D) deployment-manager gets 401/403 on GitHub dispatch
Cause: the GitHub connector OAuth/PAT token lacks workflow dispatch permission,
the connector sign-in is disconnected, or agent identities lack SRE Agent
Administrator.

Fix:
1. In the SRE portal, complete or repair GitHub OAuth/MCP sign-in with `repo` and
  `workflow` scopes. For fine-grained PAT connector mode, grant Actions read
  and write permission on the target repo.
2. For repeatable non-portal automation, run Step 5b in explicit PAT connector
  mode; do not create a data-plane `GitHubOAuth` connector.
3. Grant `SRE Agent Administrator` to both agent managed identities.
4. If `azd deploy` was never run, images default to placeholder — run `azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT cr<token>.azurecr.io && azd deploy`.

### E) Container apps still serve default welcome page after `azd up`
Cause: ACR empty — remote builds were skipped or registry endpoint env var was missing.

Fix:
```bash
azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT "cr${TOKEN}.azurecr.io"
azd deploy --no-prompt
```

## Success criteria

- [ ] New app RG and SRE RG have correct token suffix
- [ ] `azd up` is `Succeeded`
- [ ] User has `SRE Agent Administrator` on SRE Agent resource
- [ ] SRE content applied successfully (knowledge + 6 subagents + 2 skills)
- [ ] API and frontend container apps are running with real Grubify images
- [ ] GitHub repo/auth path is ready: portal GitHub MCP/OAuth is connected with
  `repo` + `workflow`, or explicit PAT connector mode is configured with
  workflow permission
- [ ] `deployment-manager` has `github-mcp/*`, `connectors: [github]`, and the
  `gh workflow run` fallback in its live prompt
- [ ] Both agent managed identities have `SRE Agent Administrator` on SRE Agent resource
- [ ] SRE portal shows expected configuration after refresh
