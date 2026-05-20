#!/bin/bash
# deploy-sre-agent.sh
# Deploys a Grubify SRE Agent and wires Azure Monitor signals to ServiceNow-backed
# incidents, knowledge, core sub-agents, incident response filters, and optional Teams paths.

set -euo pipefail

# -- Load environment ----------------------------------------------------------
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
RESOURCE_TOKEN_FILE="${SCRIPT_DIR}/../.azure/resource-token"
RESOURCE_TOKEN="${GRUBIFY_RESOURCE_TOKEN:-${RESOURCE_TOKEN:-}}"
if [[ -z "$RESOURCE_TOKEN" && -f "$RESOURCE_TOKEN_FILE" ]]; then
  RESOURCE_TOKEN=$(<"$RESOURCE_TOKEN_FILE")
fi
if [[ -z "$RESOURCE_TOKEN" ]]; then
  mkdir -p "${SCRIPT_DIR}/../.azure"
  RESOURCE_TOKEN=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 5 || true)
  echo "$RESOURCE_TOKEN" > "$RESOURCE_TOKEN_FILE"
fi
if [[ ! "$RESOURCE_TOKEN" =~ ^[a-z0-9]{5}$ ]]; then
  echo "Resource token must be exactly 5 lowercase letters or digits. Current value: $RESOURCE_TOKEN" >&2
  echo "Set GRUBIFY_RESOURCE_TOKEN in .env or delete $RESOURCE_TOKEN_FILE to regenerate it." >&2
  exit 1
fi

APP_RG="${APP_RG:-rg-grubify-app-${RESOURCE_TOKEN}}"
SRE_RG="${SRE_RG:-rg-grubify-sre-${RESOURCE_TOKEN}}"
SUFFIX="grubify"
AGENT_NAME="sre-agent-${SUFFIX}"
IDENTITY_NAME="id-sre-${SUFFIX}"
APPI_NAME="appi-sre-${SUFFIX}"
LAW_NAME="law-sre-${SUFFIX}"
ACTION_GROUP_NAME="ag-sre-${SUFFIX}"
ALERT_NAME="alert-http-5xx-${SUFFIX}"
NOTIFICATION_EMAIL="${INCIDENT_NOTIFICATION_EMAIL:-${AZURE_NOTIFICATION_EMAIL:-}}"
GITHUB_REPO="${GITHUB_REPO:-}"
if [[ -n "$GITHUB_REPO" && "$GITHUB_REPO" == */* ]]; then
  GITHUB_REPO_OWNER="${GITHUB_REPO%%/*}"
  GITHUB_REPO_NAME="${GITHUB_REPO#*/}"
else
  GITHUB_REPO_OWNER="${GITHUB_REPO_OWNER:-${GITHUB_USER:-gderossilive}}"
  GITHUB_REPO_NAME="${GITHUB_REPO_NAME:-GrubifyDemo}"
fi
GITHUB_ACCESS_TOKEN="${GITHUB_PAT:-${GITHUB_TOKEN:-}}"
ENABLE_SERVICENOW_HANDLER="${ENABLE_SERVICENOW_HANDLER:-}"
SERVICENOW_INSTANCE="${SERVICENOW_INSTANCE:-}"
SERVICENOW_INSTANCE_URL="${SERVICENOW_INSTANCE_URL:-}"
SERVICENOW_USERNAME="${SERVICENOW_USERNAME:-}"
SERVICENOW_PASSWORD="${SERVICENOW_PASSWORD:-}"
SERVICENOW_ASSIGNMENT_GROUP="${SERVICENOW_ASSIGNMENT_GROUP:-}"
SERVICENOW_CATEGORY="${SERVICENOW_CATEGORY:-software}"
SERVICENOW_LOGIC_APP_NAME="${SERVICENOW_LOGIC_APP_NAME:-la-grubify-servicenow-handler}"
ENABLE_TEAMS_CONNECTOR="${ENABLE_TEAMS_CONNECTOR:-false}"
TEAMS_TENANT_ID="${TEAMS_TENANT_ID:-86d068c0-1c9f-4b9e-939d-15146ccf2ad6}"
TEAMS_GROUP_ID="${TEAMS_GROUP_ID:-231764ec-b797-41aa-988e-5a9a4c3bd49d}"
TEAMS_CHANNEL_ID="${TEAMS_CHANNEL_ID:-19:RcMSCHJ_hrKRbTc9QPrK7EAsaPXXTJkmub39pkKKLDE1@thread.tacv2}"
TEAMS_CLIENT_ID="${TEAMS_CLIENT_ID:-}"
TEAMS_CLIENT_SECRET="${TEAMS_CLIENT_SECRET:-}"

if [[ -z "$SERVICENOW_INSTANCE_URL" && -n "$SERVICENOW_INSTANCE" ]]; then
  if [[ "$SERVICENOW_INSTANCE" == http://* || "$SERVICENOW_INSTANCE" == https://* ]]; then
    SERVICENOW_INSTANCE_URL="${SERVICENOW_INSTANCE%/}"
  else
    SERVICENOW_INSTANCE_URL="https://${SERVICENOW_INSTANCE%.service-now.com}.service-now.com"
  fi
fi

ENABLE_SERVICENOW_HANDLER="${ENABLE_SERVICENOW_HANDLER:-true}"

SERVICENOW_HANDLER_ENABLED="false"
case "${ENABLE_SERVICENOW_HANDLER,,}" in
  true|1|yes|y) SERVICENOW_HANDLER_ENABLED="true" ;;
esac

TEAMS_CONNECTOR_ENABLED="false"
case "${ENABLE_TEAMS_CONNECTOR,,}" in
  true|1|yes|y) TEAMS_CONNECTOR_ENABLED="true" ;;
esac

if [[ "$SERVICENOW_HANDLER_ENABLED" == "true" ]]; then
  missing_servicenow_vars=()
  [[ -n "$SERVICENOW_INSTANCE_URL" ]] || missing_servicenow_vars+=(SERVICENOW_INSTANCE_URL)
  [[ -n "$SERVICENOW_USERNAME" ]] || missing_servicenow_vars+=(SERVICENOW_USERNAME)
  [[ -n "$SERVICENOW_PASSWORD" ]] || missing_servicenow_vars+=(SERVICENOW_PASSWORD)
  if (( ${#missing_servicenow_vars[@]} > 0 )); then
    echo "ServiceNow incident routing is enabled, but missing: ${missing_servicenow_vars[*]}" >&2
    echo "Set these in .env or explicitly use direct SRE fallback with ENABLE_SERVICENOW_HANDLER=false" >&2
    exit 1
  fi
fi

if [[ "$SERVICENOW_HANDLER_ENABLED" == "true" ]]; then
  SERVICENOW_CONNECTION_KEY=$(printf '%s:%s' "$SERVICENOW_USERNAME" "$SERVICENOW_PASSWORD" | base64 | tr -d '\n')
else
  SERVICENOW_CONNECTION_KEY=""
fi

build_incident_management_config() {
  if [[ "$SERVICENOW_HANDLER_ENABLED" == "true" ]]; then
    python3 - "$SERVICENOW_INSTANCE_URL" "$SERVICENOW_CONNECTION_KEY" <<'PY'
import json
import sys

connection_url, connection_key = sys.argv[1:3]
print(json.dumps({
    "type": "ServiceNow",
    "connectionName": "servicenow",
    "connectionUrl": connection_url,
    "connectionKey": connection_key,
}))
PY
  else
    python3 - <<'PY'
import json

print(json.dumps({
    "type": "AzMonitor",
    "connectionName": "azmonitor",
}))
PY
  fi
}

render_sre_config() {
  local config_file="$1"
  sed \
    -e "s|GITHUB_REPO_PLACEHOLDER|${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}|g" \
    -e "s|TEAMS_TENANT_ID_PLACEHOLDER|${TEAMS_TENANT_ID}|g" \
    -e "s|TEAMS_GROUP_ID_PLACEHOLDER|${TEAMS_GROUP_ID}|g" \
    -e "s|TEAMS_CHANNEL_ID_PLACEHOLDER|${TEAMS_CHANNEL_ID}|g" \
    -e "s|AZURESRE_AGENT_ENDPOINT_PLACEHOLDER|${AGENT_ENDPOINT:-}|g" \
    "$config_file"
}

wire_action_group_webhook() {
  local receiver_name="$1"
  local receiver_uri="$2"
  local arm_token
  local body
  local http_code

  arm_token=$(az account get-access-token --query accessToken -o tsv)
  body=$(python3 - "$receiver_name" "$receiver_uri" "${NOTIFICATION_EMAIL:-}" <<'PY'
import json
import sys

receiver_name, receiver_uri, notification_email = sys.argv[1:4]
properties = {
    "groupShortName": "sre-grubify",
    "enabled": True,
    "webhookReceivers": [
        {
            "name": receiver_name,
            "serviceUri": receiver_uri,
            "useCommonAlertSchema": True,
        }
    ],
}
if notification_email:
    properties["emailReceivers"] = [
        {
            "name": "SRE Notification",
            "emailAddress": notification_email,
            "useCommonAlertSchema": True,
        }
    ]

print(json.dumps({"location": "global", "properties": properties}))
PY
)

  http_code=$(printf '%s' "$body" | curl -s -o /tmp/sre_ag_put.json -w "%{http_code}" \
    -X PUT \
    "https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${SRE_RG}/providers/Microsoft.Insights/actionGroups/${ACTION_GROUP_NAME}?api-version=2023-01-01" \
    -H "Authorization: Bearer $arm_token" \
    -H "Content-Type: application/json" \
    --data-binary @-)

  if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
    echo "  ✓ Webhook receiver '$receiver_name' wired to action group $ACTION_GROUP_NAME"
  else
    echo "  ⚠ Could not wire webhook receiver '$receiver_name' (HTTP $http_code)"
    echo "    Add manually: $receiver_uri"
    echo "    Response: $(cat /tmp/sre_ag_put.json)"
  fi
}

upsert_incident_filter() {
  local filter_id="$1"
  local filter_name="$2"
  local incident_type="$3"
  local title_contains="$4"
  local handling_agent="$5"
  local priorities_json="${6:-[]}"
  local http_code
  local filter_body

  filter_body=$(python3 - "$filter_id" "$filter_name" "$incident_type" "$title_contains" "$handling_agent" "$priorities_json" <<'PY'
import json
import sys

filter_id, filter_name, incident_type, title_contains, handling_agent, priorities_json = sys.argv[1:7]
priorities = json.loads(priorities_json)
body = {
    "id": filter_id,
    "name": filter_name,
  "documentType": "IncidentFilterServiceNow" if incident_type == "ServiceNow" else "IncidentFilterAzMonitor",
  "partitionKey": "IncidentFilterServiceNow" if incident_type == "ServiceNow" else "IncidentFilterAzMonitor",
    "priorities": priorities,
    "incidentType": incident_type,
    "titleContains": title_contains,
    "agentMode": "autonomous",
    "handlingAgent": handling_agent,
    "isEnabled": True,
    "maxAutomatedInvestigationAttempts": 3,
    "deepInvestigationEnabled": False,
    "mergeEnabled": True,
    "mergeWindowHours": 3,
}
print(json.dumps(body))
PY
)

  http_code=$(printf '%s' "$filter_body" | curl -s -o /tmp/sre_incident_filter.json -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/${filter_id}" \
    -H "Authorization: Bearer $AZURESRE_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @-)

  if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "202" || "$http_code" == "204" ]]; then
    if ! python3 - "$filter_id" /tmp/sre_incident_filter.json >/dev/null <<'PY'
import json
import sys

expected_id = sys.argv[1]
response_path = sys.argv[2]
try:
    with open(response_path) as response_file:
        body = json.load(response_file)
except Exception:
    sys.exit(1)
if body.get("id") != expected_id:
    sys.exit(1)
PY
    then
      echo "  ⚠ Incident filter $filter_id — API did not return the expected JSON filter"
      echo "    Response: $(head -c 200 /tmp/sre_incident_filter.json)"
      return
    fi
    echo "  ✓ Incident filter $filter_id"
  else
    echo "  ⚠ Incident filter $filter_id — HTTP $http_code: $(cat /tmp/sre_incident_filter.json)"
  fi
}

check_knowledge_file_indexed() {
  local file_name="$1"
  local files_json
  files_json=$(curl -sf "${AGENT_ENDPOINT}/api/v1/agentmemory/files" \
    -H "Authorization: Bearer $AZURESRE_TOKEN" 2>/dev/null || true)
  if [[ -z "$files_json" ]]; then
    echo "unknown"
    return
  fi
  python3 -c '
import json
import sys

file_name = sys.argv[1]
payload = json.load(sys.stdin)
files = payload.get("files", []) if isinstance(payload, dict) else []
match = next((item for item in files if item.get("name") == file_name), None)
if not match:
    print("missing")
elif match.get("isIndexed") is True:
    print("indexed")
else:
    reason = match.get("errorReason") or "indexing pending"
    print(f"not-indexed: {reason}")
' "$file_name" <<<"$files_json" 2>/dev/null || echo "unknown"
}

verify_teams_connector() {
  local connector_json
  local tools_json
  local connector_names
  local teams_tools

  connector_json=$(curl -sf "${AGENT_ENDPOINT}/api/v1/extendedAgent/dataconnectors" \
    -H "Authorization: Bearer $AZURESRE_TOKEN" 2>/dev/null || true)
  tools_json=$(curl -sf "${AGENT_ENDPOINT}/api/v1/extendedAgent/systemtools" \
    -H "Authorization: Bearer $AZURESRE_TOKEN" 2>/dev/null || true)

  connector_names=$(python3 -c '
import json
import sys

payload = json.load(sys.stdin)
for connector in payload:
    name = connector.get("name", "")
    connector_type = connector.get("connectorType", "")
    if "team" in name.lower() or "team" in connector_type.lower():
        print(f"{name} ({connector_type})")
' <<<"${connector_json:-[]}" 2>/dev/null || true)

  teams_tools=$(python3 -c '
import json
import sys

payload = json.load(sys.stdin)
for tool in payload:
    name = tool.get("name") if isinstance(tool, dict) else str(tool)
  if "teams" in name.lower() or name in {"GetTeamsMessages", "PostTeamsMessage", "ReplyToTeamsMessage"}:
        print(name)
' <<<"${tools_json:-[]}" 2>/dev/null || true)

  if [[ -n "$connector_names" ]]; then
    echo "  ✓ Teams connector detected: $connector_names"
  elif [[ "$TEAMS_CONNECTOR_ENABLED" == "true" ]]; then
    echo "  ⚠ Teams connector is enabled in .env, but no Teams connector is registered"
    echo "    The current SRE API lists connectors but does not expose a supported connector apply endpoint."
    echo "    Register/authenticate the Microsoft Teams connector in the SRE Agent portal, then rerun this script to verify."
    echo "    A healthy portal-created connector exposes tools such as PostTeamsMessage, GetTeamsMessages, and ReplyToTeamsMessage."
    if [[ -n "$TEAMS_CLIENT_ID" && -n "$TEAMS_CLIENT_SECRET" ]]; then
      echo "    Teams client credentials were provided locally, but automatic connector auth is not supported by the discovered API."
    fi
  else
    echo "  ℹ Teams connector disabled — skipping connector registration"
  fi

  if [[ -n "$teams_tools" ]]; then
    echo "  ✓ Teams system tools available: $(echo "$teams_tools" | paste -sd ', ' -)"
  elif [[ "$TEAMS_CONNECTOR_ENABLED" == "true" ]]; then
    echo "  ⚠ Teams system tools are not available yet"
  else
    echo "  ℹ Teams system tools not required while ENABLE_TEAMS_CONNECTOR=false"
  fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Grubify SRE Agent Deployment"
echo "  Subscription : $SUBSCRIPTION"
echo "  Location     : $LOCATION"
echo "  Token        : $RESOURCE_TOKEN"
echo "  Agent RG     : $SRE_RG"
echo "  App RG       : $APP_RG"
echo "  ServiceNow   : $SERVICENOW_HANDLER_ENABLED"
echo "  Teams        : $TEAMS_CONNECTOR_ENABLED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

az account set --subscription "$SUBSCRIPTION"
INCIDENT_MANAGEMENT_CONFIG=$(build_incident_management_config)
INCIDENT_MANAGEMENT_CONFIG_PROPERTIES=$(echo "$INCIDENT_MANAGEMENT_CONFIG" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(",\n          ".join(f"\"{key}\": {json.dumps(value)}" for key, value in d.items()))')

# -- 1. Resource group ---------------------------------------------------------
echo ""
echo "▶ Step 1/12 — Resource group"
az group create --name "$SRE_RG" --location "$LOCATION" --output none
echo "  ✓ $SRE_RG"

# -- 2. Log Analytics + Application Insights ----------------------------------
echo ""
echo "▶ Step 2/12 — Log Analytics + Application Insights"
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
APPI_CONNECTION_STRING=$(az monitor app-insights component show \
  --resource-group "$SRE_RG" --app "$APPI_NAME" \
  --query connectionString -o tsv)
echo "  ✓ $LAW_NAME"
echo "  ✓ $APPI_NAME (appId: $APPI_APP_ID)"

# -- 3. User-assigned managed identity ----------------------------------------
echo ""
echo "▶ Step 3/12 — User-assigned managed identity"
IDENTITY_ID=$(az identity create \
  --resource-group "$SRE_RG" \
  --name "$IDENTITY_NAME" \
  --location "$LOCATION" \
  --query id -o tsv)
IDENTITY_PRINCIPAL=$(az identity show \
  --resource-group "$SRE_RG" \
  --name "$IDENTITY_NAME" \
  --query principalId -o tsv)

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
SRE_RG_ID=$(az group show --name "$SRE_RG" --query id -o tsv)
az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Monitoring Reader" \
  --scope "$SRE_RG_ID" \
  --output none 2>/dev/null || true
echo "  ✓ $IDENTITY_NAME"
echo "  ✓ Monitoring Reader + Contributor on $APP_RG"

# -- 4. SRE Agent --------------------------------------------------------------
echo ""
echo "▶ Step 4/12 — SRE Agent"
EXISTING_AGENT_ID=$(az resource show \
  --resource-group "$SRE_RG" \
  --resource-type "Microsoft.App/agents" \
  --name "$AGENT_NAME" \
  --api-version "2025-05-01-preview" \
  --query id -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_AGENT_ID" ]]; then
  echo "  ✓ $AGENT_NAME already exists — reusing it"
else
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
          ${INCIDENT_MANAGEMENT_CONFIG_PROPERTIES}
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
            \"applicationInsightsResourceId\": \"${APPI_ID}\",
            \"connectionString\": \"${APPI_CONNECTION_STRING}\"
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
fi

CURRENT_INCIDENT_PLATFORM=$(az resource show \
  --resource-group "$SRE_RG" \
  --resource-type "Microsoft.App/agents" \
  --name "$AGENT_NAME" \
  --api-version "2026-01-01" \
  --query "properties.incidentManagementConfiguration.type" -o tsv 2>/dev/null || true)
DESIRED_INCIDENT_PLATFORM=$(echo "$INCIDENT_MANAGEMENT_CONFIG" | python3 -c 'import json,sys; print(json.load(sys.stdin)["type"])')
if [[ "$CURRENT_INCIDENT_PLATFORM" != "$DESIRED_INCIDENT_PLATFORM" ]]; then
  PATCH_BODY=$(python3 - "$INCIDENT_MANAGEMENT_CONFIG" <<'PY'
import json
import sys

incident_management_config = json.loads(sys.argv[1])
print(json.dumps({"properties": {"incidentManagementConfiguration": incident_management_config}}))
PY
)
  az rest \
    --method patch \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${SRE_RG}/providers/Microsoft.App/agents/${AGENT_NAME}?api-version=2026-01-01" \
    --body "$PATCH_BODY" \
    --output none
  echo "  ✓ Incident platform set to $DESIRED_INCIDENT_PLATFORM"
else
  echo "  ✓ Incident platform already $DESIRED_INCIDENT_PLATFORM"
fi

AGENT_ENDPOINT=$(az resource show \
  --resource-group "$SRE_RG" \
  --resource-type "Microsoft.App/agents" \
  --name "$AGENT_NAME" \
  --api-version "2025-05-01-preview" \
  --query "properties.agentEndpoint" -o tsv)
echo "  ✓ $AGENT_NAME"
echo "  ✓ Endpoint: $AGENT_ENDPOINT"

# -- 4b. Connect GitHub repository --------------------------------------------
echo ""
echo "▶ Step 4b/12 — GitHub repository connection"
AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION}/resourceGroups/${SRE_RG}/providers/Microsoft.App/agents/${AGENT_NAME}"
ARM_TOKEN=$(az account get-access-token --query accessToken -o tsv)
GITHUB_PATCH_BODY=$(python3 - "$GITHUB_REPO_OWNER" "$GITHUB_REPO_NAME" "$GITHUB_ACCESS_TOKEN" <<'PY'
import json
import sys

owner, name, access_token = sys.argv[1:4]
git_hub_configuration = {
    "repositories": [
        {"owner": owner, "name": name}
    ]
}
if access_token:
    git_hub_configuration["patTokenOverride"] = access_token

print(json.dumps({"properties": {"gitHubConfiguration": git_hub_configuration}}))
PY
)
for _i in $(seq 1 10); do
  HTTP_CODE=$(printf '%s' "$GITHUB_PATCH_BODY" | curl -s -o /tmp/sre-github-patch.json -w "%{http_code}" -X PATCH \
    "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=2026-01-01" \
    -H "Authorization: Bearer $ARM_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @-)
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" || "$HTTP_CODE" == "202" ]]; then
    echo "  ✓ GitHub repo ${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME} connected (HTTP $HTTP_CODE)"
    if [[ -n "$GITHUB_ACCESS_TOKEN" ]]; then
      echo "  ✓ GitHub Code Access token override submitted"
    else
      echo "  ℹ GITHUB_PAT/GITHUB_TOKEN not set — repository configured without token override"
    fi
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

# -- 5. Action group -----------------------------------------------------------
echo ""
echo "▶ Step 5/12 — Action group"
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

# -- 6. HTTP 5xx signal on Grubify API ----------------------------------------
echo ""
echo "▶ Step 6/12 — HTTP 5xx signal"
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
    --description "Signal when Grubify returns HTTP 5xx errors — opens a ServiceNow-backed SRE investigation" \
    --auto-mitigate false \
    --action "$AG_ID" \
    --output none
  echo "  ✓ $ALERT_NAME"
fi

# -- 7. RBAC: grant deploying user access to the SRE Agent portal -------------
echo ""
echo "▶ Step 7/12 — SRE Agent portal access (RBAC)"
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

# -- 8. Knowledge documents ----------------------------------------------------
echo ""
echo "▶ Step 8/12 — Knowledge documents"
KNOWLEDGE_DIR="${SCRIPT_DIR}/../knowledge"
if [[ -d "$KNOWLEDGE_DIR" ]]; then
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
    uploaded_knowledge_files=()
    for f in "${KNOWLEDGE_DIR}"/*.md; do
      fname=$(basename "$f")
      HTTP_CODE=$(curl -s -o /tmp/sre_upload.json -w "%{http_code}" -X POST \
        "$UPLOAD_ENDPOINT" \
        -H "Authorization: Bearer $AZURESRE_TOKEN" \
        -F "files=@${f};type=text/markdown")
      if [[ "$HTTP_CODE" == "200" ]]; then
        echo "  ✓ $fname"
        uploaded_knowledge_files+=("$fname")
      else
        echo "  ⚠ $fname — HTTP $HTTP_CODE: $(cat /tmp/sre_upload.json)"
      fi
    done

    if (( ${#uploaded_knowledge_files[@]} > 0 )); then
      echo "  … verifying knowledge indexing"
      for _i in $(seq 1 12); do
        pending_files=()
        failed_files=()
        for fname in "${uploaded_knowledge_files[@]}"; do
          index_state=$(check_knowledge_file_indexed "$fname")
          if [[ "$index_state" == "indexed" ]]; then
            continue
          elif [[ "$index_state" == not-indexed:* ]]; then
            failed_files+=("$fname ($index_state)")
          else
            pending_files+=("$fname ($index_state)")
          fi
        done
        if (( ${#pending_files[@]} == 0 && ${#failed_files[@]} == 0 )); then
          echo "  ✓ All uploaded knowledge files are indexed"
          break
        fi
        if (( _i == 12 )); then
          for item in "${pending_files[@]}"; do echo "  ⚠ Knowledge not indexed: $item"; done
          for item in "${failed_files[@]}"; do echo "  ⚠ Knowledge indexing failed: $item"; done
        else
          sleep 10
          AZURESRE_TOKEN=$(az account get-access-token --resource "https://azuresre.ai" --query accessToken -o tsv 2>/dev/null)
        fi
      done
    fi
  else
    echo "  ⚠ Agent API not reachable after 5 min — upload docs manually via https://sre.azure.com"
  fi
else
  echo "  ⚠ No knowledge/ directory found — skipping"
fi

# -- 8b. Teams connector and tools --------------------------------------------
echo ""
echo "▶ Step 8b/12 — Teams connector and tools"
AZURESRE_TOKEN=$(az account get-access-token --resource "https://azuresre.ai" --query accessToken -o tsv 2>/dev/null)
verify_teams_connector

# -- 9. Custom sub-agents (Extended Agents) -----------------------------------
echo ""
echo "▶ Step 9/12 — Custom sub-agents (Agent Canvas)"
AGENTS_DIR="${SCRIPT_DIR}/../sre-config/agents"
AGENTS_TO_DEPLOY=("code-analyzer" "issue-triager" "incident-handler-core")
if [[ -d "$AGENTS_DIR" ]]; then
  AZURESRE_TOKEN=$(az account get-access-token --resource "https://azuresre.ai" --query accessToken -o tsv 2>/dev/null)
  APPLY_ENDPOINT="${AGENT_ENDPOINT}/api/v1/extendedAgent/apply"
  for agent_name in "${AGENTS_TO_DEPLOY[@]}"; do
    yaml_file="${AGENTS_DIR}/${agent_name}.yaml"
    if [[ ! -f "$yaml_file" ]]; then
      echo "  ⚠ Missing $yaml_file — skipping"
      continue
    fi
    yaml_body=$(render_sre_config "$yaml_file")
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
  if [[ -f "${AGENTS_DIR}/incident-handler-full.yaml" ]]; then
    echo "  ℹ incident-handler-full.yaml skipped — normal deployment uses incident-handler-core.yaml"
  fi
else
  echo "  ⚠ No sre-config/agents/ directory found — skipping"
fi

# -- 10. Response plans (HTTP triggers for ServiceNow-backed incidents) --------
echo ""
echo "▶ Step 10/12 — Alert response plans"
RP_DIR="${SCRIPT_DIR}/../sre-config/response-plans"
SRE_TRIGGER_URL=""
if [[ -d "$RP_DIR" ]]; then
  AZURESRE_TOKEN=$(az account get-access-token --resource "https://azuresre.ai" --query accessToken -o tsv 2>/dev/null)
  for rp_file in "${RP_DIR}"/*.yaml; do
    rp_name=$(basename "$rp_file" .yaml)
    TRIGGER_BODY=$(python3 - "$rp_file" <<'PYEOF'
import sys, json
try:
    import yaml
except ImportError:
    import re
    with open(sys.argv[1]) as f:
        raw = f.read()
    def extract(key):
        m = re.search(r'^' + key + r'\s*:\s*(.+)', raw, re.MULTILINE)
        return m.group(1).strip().strip('"\'') if m else ""
    def extract_block(key):
        m = re.search(r'^' + key + r'\s*:\s*([>|])\n((?:  .+\n?)+)', raw, re.MULTILINE)
        if m:
            style, value = m.groups()
            value = re.sub(r'^  ', '', value, flags=re.MULTILINE).strip()
            if style == '>':
                return ' '.join(line.strip() for line in value.splitlines() if line.strip())
            return value
        return extract(key)
    print(json.dumps({
        "name": extract("name"),
        "description": extract_block("description"),
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

    if [[ -n "${TRIGGER_URL:-}" ]]; then
      mkdir -p "${SCRIPT_DIR}/../.azure"
      echo "$TRIGGER_URL" > "${SCRIPT_DIR}/../.azure/sre-trigger-url"
      SRE_TRIGGER_URL="$TRIGGER_URL"
      echo "  ✓ SRE trigger URL saved for action group wiring"
    fi
  done
else
  echo "  ⚠ No sre-config/response-plans/ directory found — skipping"
fi

# -- 10b. Incident response plan filters --------------------------------------
echo ""
echo "▶ Step 10b/12 — Incident response plan filters"
AZURESRE_TOKEN=$(az account get-access-token --resource "https://azuresre.ai" --query accessToken -o tsv 2>/dev/null)
upsert_incident_filter "grubify-http-errors" "Grubify HTTP Errors Filter" "ServiceNow" "$ALERT_NAME" "incident-handler" "[]"

# -- 11. ServiceNow incident routing ------------------------------------------
echo ""
echo "▶ Step 11/12 — ServiceNow incident routing"
if [[ -z "${SRE_TRIGGER_URL:-}" && -f "${SCRIPT_DIR}/../.azure/sre-trigger-url" ]]; then
  SRE_TRIGGER_URL=$(<"${SCRIPT_DIR}/../.azure/sre-trigger-url")
fi

if [[ -z "${SRE_TRIGGER_URL:-}" ]]; then
  echo "  ⚠ SRE trigger URL unavailable — action group webhook was not changed"
elif [[ "$SERVICENOW_HANDLER_ENABLED" == "true" ]]; then
  SERVICENOW_TEMPLATE="${SCRIPT_DIR}/../infra/servicenow-logic-app.bicep"
  if [[ ! -f "$SERVICENOW_TEMPLATE" ]]; then
    echo "  ✗ Missing $SERVICENOW_TEMPLATE — cannot configure ServiceNow incident routing" >&2
    echo "    Set ENABLE_SERVICENOW_HANDLER=false only when you intentionally want direct SRE webhook fallback." >&2
    exit 1
  else
    deployment_name="servicenow-handler-$(date -u +%Y%m%d%H%M%S)"
    deploy_output=$(az deployment group create \
      --name "$deployment_name" \
      --resource-group "$SRE_RG" \
      --template-file "$SERVICENOW_TEMPLATE" \
      --parameters \
          location="$LOCATION" \
          logicAppName="$SERVICENOW_LOGIC_APP_NAME" \
          serviceNowInstanceUrl="$SERVICENOW_INSTANCE_URL" \
          serviceNowUsername="$SERVICENOW_USERNAME" \
          serviceNowPassword="$SERVICENOW_PASSWORD" \
          serviceNowAssignmentGroup="$SERVICENOW_ASSIGNMENT_GROUP" \
          serviceNowCategory="$SERVICENOW_CATEGORY" \
          sreTriggerUrl="$SRE_TRIGGER_URL" \
      --query properties.outputs \
      --output json)

    SERVICENOW_CALLBACK_URL=$(echo "$deploy_output" | python3 -c "import json,sys; print(json.load(sys.stdin)['callbackUrl']['value'])")
    mkdir -p "${SCRIPT_DIR}/../.azure"
    echo "$SERVICENOW_CALLBACK_URL" > "${SCRIPT_DIR}/../.azure/servicenow-handler-url"
    echo "  ✓ $SERVICENOW_LOGIC_APP_NAME deployed"
    wire_action_group_webhook "servicenow-azure-resource-handler" "$SERVICENOW_CALLBACK_URL"
  fi
else
  echo "  ℹ ServiceNow incident routing disabled — using direct SRE Agent webhook fallback"
  wire_action_group_webhook "sre-incident-handler" "$SRE_TRIGGER_URL"
fi

# -- 12. Summary ---------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ SRE Agent deployed successfully!"
echo ""
echo "  Agent name     : $AGENT_NAME"
echo "  Resource group : $SRE_RG"
echo "  Endpoint       : ${AGENT_ENDPOINT:-<provisioning>}"
echo "  ServiceNow     : $SERVICENOW_HANDLER_ENABLED"
echo "  Teams          : $TEAMS_CONNECTOR_ENABLED"
echo "  Portal         : https://sre.azure.com"
echo ""
echo "  Next steps:"
echo "  1. Open https://sre.azure.com and verify the agent is running"
echo "  2. Authorize the GitHub repo (${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}) via the Code card in the portal"
echo "  3. Verify ServiceNow incidents are created for Grubify HTTP 5xx signals"
echo "  4. If Teams is enabled, verify/register the Teams connector in the portal"
echo "  5. Run ./scripts/break-app.sh to trigger an incident demo"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
