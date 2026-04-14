#!/bin/bash
# deploy-sre-agent.sh
# Deploys a brand-new SRE Agent for Grubify, wiring it to:
#   - The rg-grubify-app Container Apps (API + Frontend)
#   - Application Insights (created fresh)
#   - HTTP 5xx alert → SRE Agent action group
#   - Azure Monitor incident management
# Usage: ./scripts/deploy-sre-agent.sh

set -euo pipefail

# ── Load environment ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "$ENV_FILE" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +o allexport
fi

SUBSCRIPTION="${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID in .env}"
LOCATION="${AZURE_LOCATION:-swedencentral}"
APP_RG="rg-grubify-app"
SRE_RG="rg-grubify-sre"
SUFFIX="grubify"
AGENT_NAME="sre-agent-${SUFFIX}"
IDENTITY_NAME="id-sre-${SUFFIX}"
APPI_NAME="appi-sre-${SUFFIX}"
LAW_NAME="law-sre-${SUFFIX}"
ACTION_GROUP_NAME="ag-sre-${SUFFIX}"
ALERT_NAME="alert-http-5xx-${SUFFIX}"
NOTIFICATION_EMAIL="${INCIDENT_NOTIFICATION_EMAIL:-${AZURE_NOTIFICATION_EMAIL:-}}"
GITHUB_REPO_OWNER="${GITHUB_REPO_OWNER:-gderossilive}"
GITHUB_REPO_NAME="${GITHUB_REPO_NAME:-GrubifyDemo}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Grubify SRE Agent Deployment"
echo "  Subscription : $SUBSCRIPTION"
echo "  Location     : $LOCATION"
echo "  Agent RG     : $SRE_RG"
echo "  App RG       : $APP_RG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

az account set --subscription "$SUBSCRIPTION"

# ── 1. Resource group ─────────────────────────────────────────────────────────
echo ""
echo "▶ Step 1/7 — Resource group"
az group create --name "$SRE_RG" --location "$LOCATION" --output none
echo "  ✓ $SRE_RG"

# ── 2. Log Analytics + Application Insights ───────────────────────────────────
echo ""
echo "▶ Step 2/7 — Log Analytics + Application Insights"
LAW_ID=$(az monitor log-analytics workspace create \
  --resource-group "$SRE_RG" \
  --workspace-name "$LAW_NAME" \
  --location "$LOCATION" \
  --retention-time 30 \
  --query id -o tsv)
APPI_ID=$(az monitor app-insights component create \
  --resource-group "$SRE_RG" \
  --app "$APPI_NAME" \
  --location "$LOCATION" \
  --workspace "$LAW_ID" \
  --query id -o tsv)
APPI_APP_ID=$(az monitor app-insights component show \
  --resource-group "$SRE_RG" --app "$APPI_NAME" \
  --query appId -o tsv)
echo "  ✓ $LAW_NAME"
echo "  ✓ $APPI_NAME (appId: $APPI_APP_ID)"

# ── 3. User-assigned managed identity ────────────────────────────────────────
echo ""
echo "▶ Step 3/7 — User-assigned managed identity"
IDENTITY_ID=$(az identity create \
  --resource-group "$SRE_RG" \
  --name "$IDENTITY_NAME" \
  --location "$LOCATION" \
  --query id -o tsv)
IDENTITY_PRINCIPAL=$(az identity show \
  --resource-group "$SRE_RG" \
  --name "$IDENTITY_NAME" \
  --query principalId -o tsv)

# Grant Monitoring Reader + Contributor on App RG so the agent can query metrics / act
APP_RG_ID=$(az group show --name "$APP_RG" --query id -o tsv)
az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Monitoring Reader" \
  --scope "$APP_RG_ID" \
  --output none 2>/dev/null || true
az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "$APP_RG_ID" \
  --output none 2>/dev/null || true
# Also grant on own SRE RG
SRE_RG_ID=$(az group show --name "$SRE_RG" --query id -o tsv)
az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Monitoring Reader" \
  --scope "$SRE_RG_ID" \
  --output none 2>/dev/null || true
echo "  ✓ $IDENTITY_NAME"
echo "  ✓ Monitoring Reader + Contributor on $APP_RG"

# ── 4. SRE Agent ──────────────────────────────────────────────────────────────
echo ""
echo "▶ Step 4/7 — SRE Agent"
az resource create \
  --resource-group "$SRE_RG" \
  --resource-type "Microsoft.App/agents" \
  --name "$AGENT_NAME" \
  --location "$LOCATION" \
  --is-full-object \
  --properties "{
    \"location\": \"${LOCATION}\",
    \"identity\": {
      \"type\": \"SystemAssigned, UserAssigned\",
      \"userAssignedIdentities\": {
        \"${IDENTITY_ID}\": {}
      }
    },
    \"properties\": {
      \"actionConfiguration\": {
        \"accessLevel\": \"High\",
        \"mode\": \"autonomous\",
        \"identity\": \"${IDENTITY_ID}\"
      },
      \"incidentManagementConfiguration\": {
        \"type\": \"AzMonitor\",
        \"connectionName\": \"azmonitor\"
      },
      \"knowledgeGraphConfiguration\": {
        \"identity\": \"${IDENTITY_ID}\",
        \"managedResources\": [
          \"${APP_RG_ID}\"
        ]
      },
      \"logConfiguration\": {
        \"applicationInsightsConfiguration\": {
          \"appId\": \"${APPI_APP_ID}\",
          \"applicationInsightsResourceId\": \"${APPI_ID}\"
        }
      },
      \"upgradeChannel\": \"Preview\",
      \"monthlyAgentUnitLimit\": 10000,
      \"experimentalSettings\": {
        \"EnableWorkspaceTools\": true
      }
    }
  }" \
  --output none

AGENT_ENDPOINT=$(az resource show \
  --resource-group "$SRE_RG" \
  --resource-type "Microsoft.App/agents" \
  --name "$AGENT_NAME" \
  --api-version "2025-05-01-preview" \
  --query "properties.agentEndpoint" -o tsv)
echo "  ✓ $AGENT_NAME"
echo "  ✓ Endpoint: $AGENT_ENDPOINT"

# ── 4b. Connect GitHub repository ────────────────────────────────────────────
echo ""
echo "▶ Step 4b — GitHub repository connection"
AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION}/resourceGroups/${SRE_RG}/providers/Microsoft.App/agents/${AGENT_NAME}"
ARM_TOKEN=$(az account get-access-token --query accessToken -o tsv)
# Wait up to 5 min for agent to accept updates (may be BuildingKnowledgeGraph)
for _i in $(seq 1 10); do
  HTTP_CODE=$(curl -s -o /tmp/sre-github-patch.json -w "%{http_code}" -X PATCH \
    "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=2025-05-01-preview" \
    -H "Authorization: Bearer $ARM_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"properties\":{\"gitHubConfiguration\":{\"repositories\":[{\"owner\":\"${GITHUB_REPO_OWNER}\",\"name\":\"${GITHUB_REPO_NAME}\"}]}}}")
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" || "$HTTP_CODE" == "202" ]]; then
    echo "  ✓ GitHub repo ${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME} connected (HTTP $HTTP_CODE)"
    break
  elif [[ "$HTTP_CODE" == "409" ]]; then
    echo "  … agent busy (HTTP 409), retrying in 30s…"
    sleep 30
  else
    echo "  ⚠ Unexpected HTTP $HTTP_CODE — see /tmp/sre-github-patch.json"
    cat /tmp/sre-github-patch.json
    break
  fi
done

# ── 5. Action group ───────────────────────────────────────────────────────────
echo ""
echo "▶ Step 5/7 — Action group"
AG_ARGS=(
  --resource-group "$SRE_RG"
  --name "$ACTION_GROUP_NAME"
  --short-name "sre-grubify"
  --output none
)
if [[ -n "${NOTIFICATION_EMAIL:-}" ]]; then
  AG_ARGS+=(--email-receiver name="SRE Notification" email-address="$NOTIFICATION_EMAIL" use-common-alert-schema true)
fi
az monitor action-group create "${AG_ARGS[@]}"
AG_ID=$(az monitor action-group show \
  --resource-group "$SRE_RG" \
  --name "$ACTION_GROUP_NAME" \
  --query id -o tsv)
echo "  ✓ $ACTION_GROUP_NAME"

# ── 6. HTTP 5xx alert on Grubify API ─────────────────────────────────────────
echo ""
echo "▶ Step 6/7 — HTTP 5xx alert"
# Get the Container App resource ID for the API
CA_API_ID=$(az containerapp show -g "$APP_RG" -n "ca-${SUFFIX}-api" --query id -o tsv 2>/dev/null || \
           az containerapp list -g "$APP_RG" -o json | python3 -c "import json,sys; apps=json.load(sys.stdin); print([a['id'] for a in apps if 'api' in a['name']][0])")
if [[ -z "$CA_API_ID" ]]; then
  echo "  ⚠ Could not find API Container App in $APP_RG — skipping alert"
else
  az monitor metrics alert create \
    --resource-group "$SRE_RG" \
    --name "$ALERT_NAME" \
    --scopes "$CA_API_ID" \
    --condition "total Requests > 5 where statusCodeCategory includes 5xx" \
    --window-size 5m \
    --evaluation-frequency 1m \
    --severity 2 \
    --description "Alert when Grubify returns HTTP 5xx errors — triggers SRE Agent investigation" \
    --auto-mitigate false \
    --action "$AG_ID" \
    --output none
  echo "  ✓ $ALERT_NAME"
fi

# ── 7. RBAC — grant deploying user access to the SRE Agent portal ───────────
echo ""
echo "▶ Step 7/7 — SRE Agent portal access (RBAC)"
DEPLOYER_OID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
AGENT_RESOURCE_ID=$(az resource show -g "$SRE_RG" \
  --resource-type "Microsoft.App/agents" -n "$AGENT_NAME" \
  --api-version "2025-05-01-preview" --query id -o tsv)
if [[ -n "$DEPLOYER_OID" ]]; then
  az role assignment create \
    --assignee-object-id "$DEPLOYER_OID" \
    --assignee-principal-type User \
    --role "SRE Agent Administrator" \
    --scope "$AGENT_RESOURCE_ID" \
    --output none 2>/dev/null || true
  echo "  ✓ SRE Agent Administrator granted to current user"
else
  echo "  ⚠ Could not determine signed-in user — assign 'SRE Agent Administrator' manually"
  echo "    Scope: $AGENT_RESOURCE_ID"
fi

# ── 8. Knowledge documents ────────────────────────────────────────────────────
echo ""
echo "▶ Step 8/11 — Knowledge documents"
KNOWLEDGE_DIR="${SCRIPT_DIR}/../knowledge"
if [[ -d "$KNOWLEDGE_DIR" ]]; then
  # Wait for agent to be reachable (up to 5 min)
  AZURESRE_TOKEN=$(az account get-access-token --resource "https://azuresre.ai" --query accessToken -o tsv 2>/dev/null)
  UPLOAD_ENDPOINT="${AGENT_ENDPOINT}/api/v1/agentmemory/upload"
  UPLOAD_OK=0
  for _w in $(seq 1 10); do
    HEALTH=$(curl -s -o /dev/null -w "%{http_code}" \
      "${AGENT_ENDPOINT}/api/v1/agentmemory/status" \
      -H "Authorization: Bearer $AZURESRE_TOKEN" -H "Accept: application/json")
    if [[ "$HEALTH" == "200" ]]; then UPLOAD_OK=1; break; fi
    echo "  … waiting for agent API ($HEALTH), retry in 30s"
    sleep 30
    AZURESRE_TOKEN=$(az account get-access-token --resource "https://azuresre.ai" --query accessToken -o tsv 2>/dev/null)
  done
  if [[ "$UPLOAD_OK" == "1" ]]; then
    for f in "${KNOWLEDGE_DIR}"/*.md; do
      fname=$(basename "$f")
      HTTP_CODE=$(curl -s -o /tmp/sre_upload.json -w "%{http_code}" -X POST \
        "$UPLOAD_ENDPOINT" \
        -H "Authorization: Bearer $AZURESRE_TOKEN" \
        -F "files=@${f};type=text/plain")
      if [[ "$HTTP_CODE" == "200" ]]; then
        echo "  ✓ $fname"
      else
        echo "  ⚠ $fname — HTTP $HTTP_CODE: $(cat /tmp/sre_upload.json)"
      fi
    done
  else
    echo "  ⚠ Agent API not reachable after 5 min — upload docs manually via https://sre.azure.com"
  fi
else
  echo "  ⚠ No knowledge/ directory found — skipping"
fi

# ── 9. Custom sub-agents (Extended Agents) ───────────────────────────────────
echo ""
echo "▶ Step 9/11 — Custom sub-agents (Agent Canvas)"
AGENTS_DIR="${SCRIPT_DIR}/../sre-config/agents"
GITHUB_REPO="gderossilive/GrubifyDemo"
if [[ -d "$AGENTS_DIR" ]]; then
  # Refresh token (may have expired during knowledge upload)
  AZURESRE_TOKEN=$(az account get-access-token --resource "https://azuresre.ai" --query accessToken -o tsv 2>/dev/null)
  APPLY_ENDPOINT="${AGENT_ENDPOINT}/api/v1/extendedAgent/apply"
  for yaml_file in "${AGENTS_DIR}"/*.yaml; do
    agent_name=$(basename "$yaml_file" .yaml)
    # Substitute placeholder with actual GitHub repo
    yaml_body=$(sed "s|GITHUB_REPO_PLACEHOLDER|${GITHUB_REPO}|g" "$yaml_file")
    HTTP_CODE=$(echo "$yaml_body" | curl -s -o /tmp/sre_agent_apply.json -w "%{http_code}" \
      -X PUT "$APPLY_ENDPOINT" \
      -H "Authorization: Bearer $AZURESRE_TOKEN" \
      -H "Content-Type: application/x-yaml" \
      --data-binary @-)
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" || "$HTTP_CODE" == "202" || "$HTTP_CODE" == "204" ]]; then
      echo "  ✓ $agent_name"
    else
      echo "  ⚠ $agent_name — HTTP $HTTP_CODE: $(cat /tmp/sre_agent_apply.json)"
    fi
  done
else
  echo "  ⚠ No sre-config/agents/ directory found — skipping"
fi

# ── 10. Response plans (HTTP triggers for Azure Monitor alerts) ───────────────
echo ""
echo "▶ Step 10/11 — Alert response plans"
RP_DIR="${SCRIPT_DIR}/../sre-config/response-plans"
if [[ -d "$RP_DIR" ]]; then
  AZURESRE_TOKEN=$(az account get-access-token --resource "https://azuresre.ai" --query accessToken -o tsv 2>/dev/null)
  for rp_file in "${RP_DIR}"/*.yaml; do
    rp_name=$(basename "$rp_file" .yaml)

    # Parse YAML with python3 → JSON body for the trigger API
    TRIGGER_BODY=$(python3 - "$rp_file" << 'PYEOF'
import sys, json
try:
    import yaml
except ImportError:
    # Fallback manual parse for simple YAML
    import re
    with open(sys.argv[1]) as f:
        raw = f.read()
    def extract(key):
        m = re.search(r'^' + key + r'\s*:\s*(.+)', raw, re.MULTILINE)
        return m.group(1).strip().strip('"\'') if m else ""
    def extract_block(key):
        m = re.search(r'^' + key + r'\s*:\s*\|\n((?:  .+\n?)+)', raw, re.MULTILINE)
        if m:
            return re.sub(r'^  ', '', m.group(1), flags=re.MULTILINE).strip()
        return extract(key)
    print(json.dumps({
        "name": extract("name"),
        "description": extract("description"),
        "agentPrompt": extract_block("agentPrompt"),
        "agent": extract("agent"),
        "agentMode": extract("agentMode") or "autonomous",
    }))
    sys.exit(0)
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f)
print(json.dumps({
    "name": d.get("name", ""),
    "description": str(d.get("description", "")).strip(),
    "agentPrompt": str(d.get("agentPrompt", "")).strip(),
    "agent": d.get("agent", ""),
    "agentMode": d.get("agentMode", "autonomous"),
}))
PYEOF
)

    # Check if a trigger with this name already exists
    EXISTING_ID=$(curl -sf "${AGENT_ENDPOINT}/api/v1/httptriggers" \
      -H "Authorization: Bearer $AZURESRE_TOKEN" 2>/dev/null | \
      python3 -c "import json,sys; lst=json.load(sys.stdin); n=next((t['id'] for t in lst if t.get('name')==json.loads('${TRIGGER_BODY}'.replace(\"'\", '\"') if False else '{}').get('name','__none__')), None); print(n or '')" 2>/dev/null || echo "")
    # Simpler duplicate check using the name field directly
    RP_TRIGGER_NAME=$(echo "$TRIGGER_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
    EXISTING_ID=$(curl -sf "${AGENT_ENDPOINT}/api/v1/httptriggers" \
      -H "Authorization: Bearer $AZURESRE_TOKEN" 2>/dev/null | \
      python3 -c "import json,sys; lst=json.load(sys.stdin); t=next((x for x in lst if x.get('name')=='${RP_TRIGGER_NAME}'),None); print(t['id'] if t else '')" 2>/dev/null || echo "")

    if [[ -n "$EXISTING_ID" && "$EXISTING_ID" != "None" ]]; then
      TRIGGER_URL=$(curl -sf "${AGENT_ENDPOINT}/api/v1/httptriggers/${EXISTING_ID}" \
        -H "Authorization: Bearer $AZURESRE_TOKEN" 2>/dev/null | \
        python3 -c "import json,sys; print(json.load(sys.stdin).get('triggerUrl',''))" 2>/dev/null || echo "")
      echo "  ✓ $rp_name — already exists (id: $EXISTING_ID)"
    else
      HTTP_CODE=$(echo "$TRIGGER_BODY" | curl -s -o /tmp/sre_rp.json -w "%{http_code}" \
        -X POST "${AGENT_ENDPOINT}/api/v1/httptriggers/create" \
        -H "Authorization: Bearer $AZURESRE_TOKEN" \
        -H "Content-Type: application/json" \
        --data-binary @-)
      if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
        TRIGGER_URL=$(python3 -c "import json; print(json.load(open('/tmp/sre_rp.json')).get('triggerUrl',''))" 2>/dev/null || echo "")
        TRIGGER_ID=$(python3 -c "import json; print(json.load(open('/tmp/sre_rp.json')).get('triggerId',''))" 2>/dev/null || echo "")
        echo "  ✓ $rp_name created (id: $TRIGGER_ID)"
      else
        echo "  ⚠ $rp_name — HTTP trigger creation failed (HTTP $HTTP_CODE): $(cat /tmp/sre_rp.json)"
        TRIGGER_URL=""
      fi
    fi

    # Wire trigger URL → action group as a webhook receiver
    if [[ -n "${TRIGGER_URL:-}" ]]; then
      # Save URL for reference (.azure/ is gitignored)
      mkdir -p "${SCRIPT_DIR}/../.azure"
      echo "$TRIGGER_URL" > "${SCRIPT_DIR}/../.azure/sre-trigger-url"

      # Add webhook receiver via ARM REST API (action groups use 'global' location)
      ARM_TOKEN_RP=$(az account get-access-token --query accessToken -o tsv)
      AG_PUT_CODE=$(curl -s -o /tmp/sre_ag_put.json -w "%{http_code}" \
        -X PUT \
        "https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${SRE_RG}/providers/Microsoft.Insights/actionGroups/${ACTION_GROUP_NAME}?api-version=2023-01-01" \
        -H "Authorization: Bearer $ARM_TOKEN_RP" \
        -H "Content-Type: application/json" \
        -d "{
          \"location\": \"global\",
          \"properties\": {
            \"groupShortName\": \"sre-grubify\",
            \"enabled\": true,
            \"webhookReceivers\": [
              {
                \"name\": \"sre-incident-handler\",
                \"serviceUri\": \"${TRIGGER_URL}\",
                \"useCommonAlertSchema\": true
              }
            ]
          }
        }")
      if [[ "$AG_PUT_CODE" == "200" || "$AG_PUT_CODE" == "201" ]]; then
        echo "  ✓ Webhook wired to action group $ACTION_GROUP_NAME"
      else
        echo "  ⚠ Could not auto-wire webhook (HTTP $AG_PUT_CODE) — add manually:"
        echo "    $TRIGGER_URL"
      fi
    fi
  done
else
  echo "  ⚠ No sre-config/response-plans/ directory found — skipping"
fi

# ── 11. Summary ────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ SRE Agent deployed successfully!"
echo ""
echo "  Agent name     : $AGENT_NAME"
echo "  Resource group : $SRE_RG"
echo "  Endpoint       : ${AGENT_ENDPOINT:-<provisioning>}"
echo "  Portal         : https://sre.azure.com"
echo ""
echo "  Next steps:"
echo "  1. Open https://sre.azure.com and verify the agent is running"
echo "  2. Authorize the GitHub repo (gderossilive/GrubifyDemo) via the Code card in the portal"
echo "  3. Run ./scripts/break-app.sh to trigger an incident demo"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
