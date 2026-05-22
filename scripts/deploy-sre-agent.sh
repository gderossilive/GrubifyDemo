#!/usr/bin/env bash
# deploy-sre-agent.sh
#
# Lightweight Grubify SRE Agent wrapper for the v2 deployment model.
# Infrastructure and agent content now flow through azd/Bicep plus
# bin/assemble-agent.py and bin/apply-extras.py. This script only runs that
# v2 content flow and applies ServiceNow/Teams extras that are not yet modeled
# in Bicep.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +o allexport
fi

azd_value() {
  local name="$1"
  if command -v azd >/dev/null 2>&1; then
    azd env get-value "$name" 2>/dev/null || true
  fi
}

az_value() {
  local query="$1"
  az account show --query "$query" -o tsv 2>/dev/null || true
}

first_non_empty() {
  for value in "$@"; do
    if [[ -n "${value:-}" ]]; then
      printf '%s' "$value"
      return
    fi
  done
}

url_encode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
PY
}

yaml_config_value() {
  local path="$1"
  local key_path="$2"
  if [[ ! -f "$path" ]]; then
  return 0
  fi
  python3 - "$path" "$key_path" <<'PY'
import os
import re
import sys

try:
  import yaml
except ImportError:
  sys.exit(0)

env_pattern = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")

def expand_env(value):
  if isinstance(value, dict):
    return {key: expand_env(item) for key, item in value.items()}
  if isinstance(value, list):
    return [expand_env(item) for item in value]
  if not isinstance(value, str):
    return value
  return env_pattern.sub(lambda match: os.environ.get(match.group(1), match.group(2) or ""), value)

path, key_path = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
  data = expand_env(yaml.safe_load(handle) or {})
value = data
for part in key_path.split("."):
  if isinstance(value, dict):
    value = value.get(part, "")
  else:
    value = ""
  if value in (None, ""):
    break
if isinstance(value, bool):
  print(str(value).lower())
elif isinstance(value, (str, int, float)):
  print(value)
PY
}

SUBSCRIPTION="$(first_non_empty "$(azd_value AZURE_SUBSCRIPTION_ID)" "${AZURE_SUBSCRIPTION_ID:-}" "$(az_value id)")"
LOCATION="$(first_non_empty "$(azd_value AZURE_LOCATION)" "${AZURE_LOCATION:-}" "swedencentral")"
APP_RG="$(first_non_empty "$(azd_value AZURE_RESOURCE_GROUP)" "${APP_RG:-}" "${AZURE_RESOURCE_GROUP:-}")"
SRE_RG="$(first_non_empty "$(azd_value SRE_AGENT_RESOURCE_GROUP)" "${SRE_RG:-}" "${SRE_AGENT_RESOURCE_GROUP:-}")"
AGENT_NAME="$(first_non_empty "$(azd_value SRE_AGENT_NAME)" "${AGENT_NAME:-}" "${SRE_AGENT_NAME:-}" "sre-agent-grubify")"
AGENT_ENDPOINT="$(first_non_empty "$(azd_value SRE_AGENT_ENDPOINT)" "${AGENT_ENDPOINT:-}" "${SRE_AGENT_ENDPOINT:-}")"
AGT_FUNCTION_URL="$(first_non_empty "$(azd_value AGT_FUNCTION_URL)" "${AGT_FUNCTION_URL:-}")"

RESOURCE_TOKEN_FILE="${REPO_ROOT}/.azure/resource-token"
RESOURCE_TOKEN="$(first_non_empty "$(azd_value GRUBIFY_RESOURCE_TOKEN)" "${GRUBIFY_RESOURCE_TOKEN:-}" "${RESOURCE_TOKEN:-}")"
if [[ -z "$RESOURCE_TOKEN" && -f "$RESOURCE_TOKEN_FILE" ]]; then
  RESOURCE_TOKEN="$(<"$RESOURCE_TOKEN_FILE")"
fi
if [[ -z "$APP_RG" && -n "$RESOURCE_TOKEN" ]]; then
  APP_RG="rg-grubify-app-${RESOURCE_TOKEN}"
fi
if [[ -z "$SRE_RG" && -n "$RESOURCE_TOKEN" ]]; then
  SRE_RG="rg-grubify-sre-${RESOURCE_TOKEN}"
fi

if [[ -z "$SUBSCRIPTION" ]]; then
  echo "Set AZURE_SUBSCRIPTION_ID or log in with az before running this script." >&2
  exit 1
fi
if [[ -z "$SRE_RG" ]]; then
  echo "Could not resolve the SRE Agent resource group. Run azd up first or set SRE_AGENT_RESOURCE_GROUP." >&2
  exit 1
fi

SUFFIX="grubify"
ACTION_GROUP_NAME="${ACTION_GROUP_NAME:-ag-sre-${SUFFIX}}"
ALERT_NAME="${ALERT_NAME:-alert-http-5xx-${SUFFIX}}"
INCIDENT_HANDLER_AGENT="${INCIDENT_HANDLER_AGENT:-incident-handler-agt}"
NOTIFICATION_EMAIL="${INCIDENT_NOTIFICATION_EMAIL:-${AZURE_NOTIFICATION_EMAIL:-}}"

GITHUB_REPO="${GITHUB_REPO:-}"
if [[ -n "$GITHUB_REPO" && "$GITHUB_REPO" == */* ]]; then
  GITHUB_REPO_OWNER="${GITHUB_REPO%%/*}"
  GITHUB_REPO_NAME="${GITHUB_REPO#*/}"
else
  GITHUB_REPO_OWNER="${GITHUB_REPO_OWNER:-${GITHUB_USER:-gderossilive}}"
  GITHUB_REPO_NAME="${GITHUB_REPO_NAME:-GrubifyDemo}"
fi

ENABLE_SERVICENOW_HANDLER="${ENABLE_SERVICENOW_HANDLER:-true}"
SERVICENOW_CONFIG_FILE="${SERVICENOW_CONFIG_FILE:-${REPO_ROOT}/sre-config/incident-platforms/servicenow.yaml}"
SERVICENOW_INSTANCE="${SERVICENOW_INSTANCE:-}"
SERVICENOW_INSTANCE_URL="${SERVICENOW_INSTANCE_URL:-}"
SERVICENOW_USERNAME="${SERVICENOW_USERNAME:-}"
SERVICENOW_PASSWORD="${SERVICENOW_PASSWORD:-}"
SERVICENOW_ASSIGNMENT_GROUP="${SERVICENOW_ASSIGNMENT_GROUP:-$(yaml_config_value "$SERVICENOW_CONFIG_FILE" spec.assignmentGroup)}"
SERVICENOW_INDEXING_LOOKBACK_DAYS="${SERVICENOW_INDEXING_LOOKBACK_DAYS:-$(yaml_config_value "$SERVICENOW_CONFIG_FILE" spec.lookbackDays)}"
SERVICENOW_INDEXING_LOOKBACK_DAYS="${SERVICENOW_INDEXING_LOOKBACK_DAYS:-30}"
SERVICENOW_CATEGORY="${SERVICENOW_CATEGORY:-software}"
SERVICENOW_LOGIC_APP_NAME="${SERVICENOW_LOGIC_APP_NAME:-la-grubify-servicenow-handler}"

ENABLE_TEAMS_CONNECTOR="${ENABLE_TEAMS_CONNECTOR:-false}"
TEAMS_TENANT_ID="${TEAMS_TENANT_ID:-86d068c0-1c9f-4b9e-939d-15146ccf2ad6}"
TEAMS_GROUP_ID="${TEAMS_GROUP_ID:-231764ec-b797-41aa-988e-5a9a4c3bd49d}"
TEAMS_CHANNEL_ID="${TEAMS_CHANNEL_ID:-19:RcMSCHJ_hrKRbTc9QPrK7EAsaPXXTJkmub39pkKKLDE1@thread.tacv2}"

SERVICENOW_HANDLER_ENABLED="false"
case "${ENABLE_SERVICENOW_HANDLER,,}" in
  true|1|yes|y) SERVICENOW_HANDLER_ENABLED="true" ;;
esac

TEAMS_CONNECTOR_ENABLED="false"
case "${ENABLE_TEAMS_CONNECTOR,,}" in
  true|1|yes|y) TEAMS_CONNECTOR_ENABLED="true" ;;
esac

if [[ -z "$SERVICENOW_INSTANCE_URL" && -n "$SERVICENOW_INSTANCE" ]]; then
  if [[ "$SERVICENOW_INSTANCE" == http://* || "$SERVICENOW_INSTANCE" == https://* ]]; then
    SERVICENOW_INSTANCE_URL="${SERVICENOW_INSTANCE%/}"
  else
    SERVICENOW_INSTANCE_URL="https://${SERVICENOW_INSTANCE%.service-now.com}.service-now.com"
  fi
fi

require_agent_endpoint() {
  if [[ -n "$AGENT_ENDPOINT" ]]; then
    return
  fi
  AGENT_ENDPOINT="$(az resource show \
    --resource-group "$SRE_RG" \
    --resource-type "Microsoft.App/agents" \
    --name "$AGENT_NAME" \
    --api-version "2025-05-01-preview" \
    --query "properties.agentEndpoint" -o tsv 2>/dev/null || true)"
  if [[ -z "$AGENT_ENDPOINT" ]]; then
    echo "Could not resolve SRE Agent endpoint. Run azd up first or set SRE_AGENT_ENDPOINT/AGENT_ENDPOINT." >&2
    exit 1
  fi
}

get_sre_token() {
  az account get-access-token --resource "https://azuresre.ai" --query accessToken -o tsv
}

configure_servicenow_connection() {
  local missing=()
  [[ -n "$SERVICENOW_INSTANCE_URL" ]] || missing+=(SERVICENOW_INSTANCE_URL)
  [[ -n "$SERVICENOW_USERNAME" ]] || missing+=(SERVICENOW_USERNAME)
  [[ -n "$SERVICENOW_PASSWORD" ]] || missing+=(SERVICENOW_PASSWORD)
  if (( ${#missing[@]} > 0 )); then
    echo "ServiceNow is enabled but missing: ${missing[*]}" >&2
    exit 1
  fi

  local agent_id
  local arm_token
  local body
  local http_code

  agent_id="$(az resource show \
    --resource-group "$SRE_RG" \
    --resource-type "Microsoft.App/agents" \
    --name "$AGENT_NAME" \
    --api-version "2025-05-01-preview" \
    --query id -o tsv)"
  arm_token="$(az account get-access-token --query accessToken -o tsv)"
  body="$(python3 - "$SERVICENOW_INSTANCE_URL" "$SERVICENOW_USERNAME" "$SERVICENOW_PASSWORD" <<'PY'
import json
import sys

connection_url, username, password = sys.argv[1:4]
connection_key = json.dumps({"username": username, "password": password}, separators=(",", ":"))
print(json.dumps({
    "properties": {
        "incidentManagementConfiguration": {
            "type": "ServiceNow",
            "connectionName": "servicenow",
            "connectionUrl": connection_url,
            "connectionKey": connection_key,
        }
    }
}))
PY
)"

  http_code="$(printf '%s' "$body" | curl -s -o /tmp/sre_servicenow_arm_patch.json -w "%{http_code}" \
    -X PATCH \
    "https://management.azure.com${agent_id}?api-version=2025-05-01-preview" \
    -H "Authorization: Bearer $arm_token" \
    -H "Content-Type: application/json" \
    --data-binary @-)"

  if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "202" ]]; then
    echo "  OK SRE Agent ServiceNow incident connection configured"
  else
    echo "  WARN SRE Agent ServiceNow incident connection failed (HTTP $http_code): $(cat /tmp/sre_servicenow_arm_patch.json)"
  fi
}

run_v2_flow() {
  echo "==> Assembling and applying SRE Agent v2 content"
  (
    cd "$REPO_ROOT"
    AGT_FUNCTION_URL="$AGT_FUNCTION_URL" \
    SRE_AGENT_NAME="$AGENT_NAME" \
    SRE_AGENT_RESOURCE_GROUP="$SRE_RG" \
    SRE_AGENT_ENDPOINT="$AGENT_ENDPOINT" \
    GITHUB_REPO="${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}" \
    TEAMS_TENANT_ID="$TEAMS_TENANT_ID" \
    TEAMS_GROUP_ID="$TEAMS_GROUP_ID" \
    TEAMS_CHANNEL_ID="$TEAMS_CHANNEL_ID" \
      python3 bin/assemble-agent.py

    SRE_AGENT_NAME="$AGENT_NAME" \
    SRE_AGENT_RESOURCE_GROUP="$SRE_RG" \
    SRE_AGENT_ENDPOINT="$AGENT_ENDPOINT" \
      python3 bin/apply-extras.py
  )
}

deploy_arm_connectors() {
  local parameters_file="${REPO_ROOT}/build/agent.parameters.json"
  local connectors_json
  local connector_count
  if [[ ! -f "$parameters_file" ]]; then
    echo "  WARN missing $parameters_file; skipping ARM connector deployment"
    return
  fi

  connectors_json="$(jq -c '.parameters.sreConnectors // []' "$parameters_file")"
  connector_count="$(jq 'length' <<<"$connectors_json")"
  if [[ "$connector_count" -eq 0 ]]; then
    echo "  ARM connectors: none"
    return
  fi

  az deployment group create \
    --name "sre-agent-connectors-$(date -u +%Y%m%d%H%M%S)" \
    --resource-group "$SRE_RG" \
    --template-file "${REPO_ROOT}/infra/core/host/sre-agent-extensions.bicep" \
    --parameters agentName="$AGENT_NAME" connectors="$connectors_json" \
    --output none
  echo "  OK deployed ${connector_count} ARM connector(s)"
}

wire_action_group_logic_app() {
  local receiver_name="$1"
  local logic_app_id="$2"
  local callback_url="$3"
  local arm_token
  local body
  local http_code

  arm_token="$(az account get-access-token --query accessToken -o tsv)"
  body="$(python3 - "$receiver_name" "$logic_app_id" "$callback_url" "${NOTIFICATION_EMAIL:-}" <<'PY'
import json
import sys

receiver_name, logic_app_id, callback_url, notification_email = sys.argv[1:5]
properties = {
    "groupShortName": "sre-grubify",
    "enabled": True,
    "logicAppReceivers": [
        {
            "name": receiver_name,
            "resourceId": logic_app_id,
            "callbackUrl": callback_url,
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
)"

  http_code="$(printf '%s' "$body" | curl -s -o /tmp/sre_ag_put.json -w "%{http_code}" \
    -X PUT \
    "https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${SRE_RG}/providers/Microsoft.Insights/actionGroups/${ACTION_GROUP_NAME}?api-version=2023-01-01" \
    -H "Authorization: Bearer $arm_token" \
    -H "Content-Type: application/json" \
    --data-binary @-)"

  if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
    echo "  OK action group $ACTION_GROUP_NAME wired to Logic App receiver $receiver_name"
  else
    echo "  WARN could not wire Logic App receiver $receiver_name (HTTP $http_code)"
    echo "       Response: $(cat /tmp/sre_ag_put.json)"
  fi
}

ensure_http_5xx_alert() {
  if [[ -z "$APP_RG" ]]; then
    echo "  WARN app resource group is unknown; skipping HTTP 5xx alert wiring"
    return
  fi

  local ca_api_id
  local action_group_id
  ca_api_id="$(az containerapp show -g "$APP_RG" -n "ca-${SUFFIX}-api" --query id -o tsv 2>/dev/null || true)"
  if [[ -z "$ca_api_id" ]]; then
    ca_api_id="$(az containerapp list -g "$APP_RG" -o json 2>/dev/null | python3 -c "import json,sys; apps=json.load(sys.stdin); print(next((a['id'] for a in apps if 'api' in a.get('name','')), ''))" 2>/dev/null || true)"
  fi
  if [[ -z "$ca_api_id" ]]; then
    echo "  WARN could not find API Container App in $APP_RG; skipping HTTP 5xx alert"
    return
  fi

  az monitor action-group create \
    --resource-group "$SRE_RG" \
    --name "$ACTION_GROUP_NAME" \
    --short-name "sre-grubify" \
    --output none
  action_group_id="$(az monitor action-group show -g "$SRE_RG" -n "$ACTION_GROUP_NAME" --query id -o tsv)"

  az monitor metrics alert create \
    --resource-group "$SRE_RG" \
    --name "$ALERT_NAME" \
    --scopes "$ca_api_id" \
    --condition "total Requests > 5 where statusCodeCategory includes 5xx" \
    --window-size 5m \
    --evaluation-frequency 1m \
    --severity 2 \
    --description "Signal when Grubify returns HTTP 5xx errors for ServiceNow-backed SRE investigation" \
    --auto-mitigate false \
    --action "$action_group_id" \
    --output none
  echo "  OK HTTP 5xx alert $ALERT_NAME targets $ca_api_id"
}

resolve_servicenow_assignment_group() {
  if [[ -n "$SERVICENOW_ASSIGNMENT_GROUP" ]]; then
    printf '%s' "$SERVICENOW_ASSIGNMENT_GROUP"
    return
  fi

  local search_term
  local encoded_search
  local groups_json
  for search_term in "Software" "Service Desk" "Incident Management" "Help Desk"; do
    encoded_search="$(url_encode "$search_term")"
    groups_json="$(curl -sf "${AGENT_ENDPOINT}/api/v2/incidents/indexing/servicenow/assignment-groups?search=${encoded_search}" \
      -H "Authorization: Bearer $AZURESRE_TOKEN" \
      -H "X-ServiceNow-Endpoint: $SERVICENOW_INSTANCE_URL" \
      -H "X-ServiceNow-Username: $SERVICENOW_USERNAME" \
      -H "X-ServiceNow-Password: $SERVICENOW_PASSWORD" 2>/dev/null || true)"
    if [[ -n "$groups_json" ]]; then
      python3 -c '
import json
import sys

search_term = sys.argv[1].lower()
try:
    groups = json.load(sys.stdin)
except Exception:
    groups = []
if not isinstance(groups, list):
    groups = []
exact = next((group for group in groups if str(group.get("name", "")).lower() == search_term), None)
chosen = exact or (groups[0] if groups else None)
if chosen:
    print(chosen.get("sys_id") or chosen.get("name") or "")
' "$search_term" <<<"$groups_json"
      return
    fi
  done
}

configure_servicenow_indexing() {
  local missing=()
  [[ -n "$SERVICENOW_INSTANCE_URL" ]] || missing+=(SERVICENOW_INSTANCE_URL)
  [[ -n "$SERVICENOW_USERNAME" ]] || missing+=(SERVICENOW_USERNAME)
  [[ -n "$SERVICENOW_PASSWORD" ]] || missing+=(SERVICENOW_PASSWORD)
  if (( ${#missing[@]} > 0 )); then
    echo "ServiceNow is enabled but missing: ${missing[*]}" >&2
    exit 1
  fi

  local validation_body
  local validation_code
  local validation_result
  local assignment_group
  local indexing_body
  local indexing_code

  validation_body="$(python3 - "$SERVICENOW_INSTANCE_URL" "$SERVICENOW_USERNAME" "$SERVICENOW_PASSWORD" <<'PY'
import json
import sys

endpoint, username, password = sys.argv[1:4]
print(json.dumps({"endpoint": endpoint, "username": username, "password": password}))
PY
)"
  validation_code="$(printf '%s' "$validation_body" | curl -s -o /tmp/sre_servicenow_validation.json -w "%{http_code}" \
    -X POST "${AGENT_ENDPOINT}/api/v1/incidentplatformvalidation/servicenow" \
    -H "Authorization: Bearer $AZURESRE_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @-)"
  validation_result="$(python3 - /tmp/sre_servicenow_validation.json <<'PY' 2>/dev/null || true
import json
import sys

try:
    with open(sys.argv[1]) as response_file:
        print(json.load(response_file).get("result", ""))
except Exception:
    pass
PY
)"
  if [[ "$validation_code" != "200" || "$validation_result" != "valid" ]]; then
    echo "  WARN ServiceNow validation failed in SRE backend (HTTP $validation_code, result: ${validation_result:-unknown})"
    return
  fi
  echo "  OK ServiceNow credentials validated by SRE backend"

  assignment_group="$(resolve_servicenow_assignment_group)"
  if [[ -z "$assignment_group" ]]; then
    echo "  WARN ServiceNow indexing requires an assignment group; set SERVICENOW_ASSIGNMENT_GROUP and rerun"
    return
  fi

  indexing_body="$(python3 - "$assignment_group" "$SERVICENOW_INDEXING_LOOKBACK_DAYS" <<'PY'
import json
import sys

assignment_group, lookback_days = sys.argv[1:3]
print(json.dumps({
    "providerType": "servicenow",
    "assignmentGroup": assignment_group,
    "lookbackDays": int(lookback_days),
}))
PY
)"
  indexing_code="$(printf '%s' "$indexing_body" | curl -s -o /tmp/sre_servicenow_indexing.json -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v2/incidents/indexing/servicenow/configuration" \
    -H "Authorization: Bearer $AZURESRE_TOKEN" \
    -H "Content-Type: application/json" \
    -H "X-ServiceNow-Endpoint: $SERVICENOW_INSTANCE_URL" \
    -H "X-ServiceNow-Username: $SERVICENOW_USERNAME" \
    -H "X-ServiceNow-Password: $SERVICENOW_PASSWORD" \
    --data-binary @-)"
  if [[ "$indexing_code" == "200" || "$indexing_code" == "201" || "$indexing_code" == "202" || "$indexing_code" == "204" ]]; then
    echo "  OK ServiceNow incident indexing configured"
  else
    echo "  WARN ServiceNow indexing configuration failed (HTTP $indexing_code): $(cat /tmp/sre_servicenow_indexing.json)"
  fi
}

upsert_response_plan_filter() {
  local response_plan="${REPO_ROOT}/sre-config/response-plans/http-5xx-response-plan.yaml"
  if [[ ! -f "$response_plan" ]]; then
    echo "  WARN missing $response_plan; skipping response plan filter"
    return
  fi

  local filter_body
  local filter_id
  local http_code
  filter_body="$(python3 - "$response_plan" "$ALERT_NAME" "$INCIDENT_HANDLER_AGENT" <<'PY'
import json
import os
import re
import sys

try:
    import yaml
except ImportError as exc:
    raise SystemExit("PyYAML is required to apply response plan filters") from exc

env_pattern = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")

def expand_env(value):
  if isinstance(value, dict):
    return {key: expand_env(item) for key, item in value.items()}
  if isinstance(value, list):
    return [expand_env(item) for item in value]
  if not isinstance(value, str):
    return value
  return env_pattern.sub(lambda match: os.environ.get(match.group(1), match.group(2) or ""), value)

path, alert_name, handler = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
  plan = expand_env(yaml.safe_load(handle) or {})
filter_config = dict(plan.get("responsePlanFilter") or {})
filter_config["titleContains"] = filter_config.get("titleContains") or alert_name
filter_config["handlingAgent"] = filter_config.get("handlingAgent") or handler
filter_config["agentMode"] = filter_config.get("agentMode") or "autonomous"
filter_config["isEnabled"] = filter_config.get("isEnabled", True)
filter_config["maxAutomatedInvestigationAttempts"] = filter_config.get("maxAutomatedInvestigationAttempts", 3)
filter_config["deepInvestigationEnabled"] = filter_config.get("deepInvestigationEnabled", False)
filter_config["mergeEnabled"] = filter_config.get("mergeEnabled", True)
filter_config["mergeWindowHours"] = filter_config.get("mergeWindowHours", 3)
print(json.dumps(filter_config))
PY
)"
  filter_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$filter_body")"
  http_code="$(printf '%s' "$filter_body" | curl -s -o /tmp/sre_incident_filter.json -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/${filter_id}" \
    -H "Authorization: Bearer $AZURESRE_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @-)"
  if [[ "$http_code" == "409" ]]; then
    http_code="$(printf '%s' "$filter_body" | curl -s -o /tmp/sre_incident_filter.json -w "%{http_code}" \
      -X POST "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/${filter_id}" \
      -H "Authorization: Bearer $AZURESRE_TOKEN" \
      -H "Content-Type: application/json" \
      --data-binary @-)"
  fi
  if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "202" || "$http_code" == "204" ]]; then
    echo "  OK response plan filter $filter_id"
  else
    echo "  WARN response plan filter $filter_id failed (HTTP $http_code): $(cat /tmp/sre_incident_filter.json)"
  fi
}

deploy_servicenow_logic_app() {
  local template="${REPO_ROOT}/infra/servicenow-logic-app.bicep"
  if [[ ! -f "$template" ]]; then
    echo "Missing $template; cannot configure ServiceNow routing." >&2
    exit 1
  fi

  local deployment_name
  local deploy_output
  local callback_url
  local logic_app_id
  local principal_id
  deployment_name="servicenow-handler-$(date -u +%Y%m%d%H%M%S)"
  deploy_output="$(az deployment group create \
    --name "$deployment_name" \
    --resource-group "$SRE_RG" \
    --template-file "$template" \
    --parameters \
      location="$LOCATION" \
      logicAppName="$SERVICENOW_LOGIC_APP_NAME" \
      serviceNowInstanceUrl="$SERVICENOW_INSTANCE_URL" \
      serviceNowUsername="$SERVICENOW_USERNAME" \
      serviceNowPassword="$SERVICENOW_PASSWORD" \
      serviceNowAssignmentGroup="$SERVICENOW_ASSIGNMENT_GROUP" \
      serviceNowCategory="$SERVICENOW_CATEGORY" \
      azureSubscriptionId="$SUBSCRIPTION" \
    --query properties.outputs \
    --output json)"

  callback_url="$(python3 -c "import json,sys; print(json.load(sys.stdin)['callbackUrl']['value'])" <<<"$deploy_output")"
  logic_app_id="$(python3 -c "import json,sys; print(json.load(sys.stdin)['logicAppId']['value'])" <<<"$deploy_output")"
  principal_id="$(python3 -c "import json,sys; print(json.load(sys.stdin)['logicAppPrincipalId']['value'])" <<<"$deploy_output")"

  if [[ -n "$principal_id" ]]; then
    az role assignment create \
      --assignee-object-id "$principal_id" \
      --assignee-principal-type ServicePrincipal \
      --role "Monitoring Contributor" \
      --scope "/subscriptions/${SUBSCRIPTION}" \
      --output none 2>/dev/null || true
    echo "  OK Logic App can acknowledge Azure Monitor alerts"
  fi

  mkdir -p "${REPO_ROOT}/.azure"
  printf '%s' "$callback_url" > "${REPO_ROOT}/.azure/servicenow-handler-url"
  echo "  OK $SERVICENOW_LOGIC_APP_NAME deployed"
  wire_action_group_logic_app "sre-logic-app" "$logic_app_id" "$callback_url"
}

verify_teams_connector() {
  if [[ "$TEAMS_CONNECTOR_ENABLED" != "true" ]]; then
    echo "  Teams connector disabled; skipping Teams verification"
    return
  fi

  local connector_json
  local tools_json
  local connector_names
  local teams_tools
  connector_json="$(curl -sf "${AGENT_ENDPOINT}/api/v1/extendedAgent/dataconnectors" \
    -H "Authorization: Bearer $AZURESRE_TOKEN" 2>/dev/null || true)"
  tools_json="$(curl -sf "${AGENT_ENDPOINT}/api/v1/extendedAgent/systemtools" \
    -H "Authorization: Bearer $AZURESRE_TOKEN" 2>/dev/null || true)"

  connector_names="$(python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    payload = []
for connector in payload if isinstance(payload, list) else []:
    name = connector.get("name", "")
    connector_type = connector.get("connectorType", "")
    if "team" in name.lower() or "team" in connector_type.lower():
        print(f"{name} ({connector_type})")
' <<<"${connector_json:-[]}" 2>/dev/null || true)"
  teams_tools="$(python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    payload = []
for tool in payload if isinstance(payload, list) else []:
    name = tool.get("name") if isinstance(tool, dict) else str(tool)
    if "teams" in name.lower() or name in {"GetTeamsMessages", "PostTeamsMessage", "ReplyToTeamsMessage"}:
        print(name)
' <<<"${tools_json:-[]}" 2>/dev/null || true)"

  if [[ -n "$connector_names" ]]; then
    echo "  OK Teams connector detected: $connector_names"
  else
    echo "  WARN Teams connector enabled, but no Teams connector is registered in SRE Agent"
  fi

  if [[ -n "$teams_tools" ]]; then
    echo "  OK Teams system tools available: $(echo "$teams_tools" | paste -sd ', ' -)"
  else
    echo "  WARN Teams system tools are not available yet"
  fi
}

echo "==> Grubify SRE Agent v2 extras"
echo "    Subscription : $SUBSCRIPTION"
echo "    App RG       : ${APP_RG:-<unknown>}"
echo "    SRE RG       : $SRE_RG"
echo "    Agent        : $AGENT_NAME"
echo "    Endpoint     : ${AGENT_ENDPOINT:-<resolve after azd>}"
echo "    ServiceNow   : $SERVICENOW_HANDLER_ENABLED"
echo "    Teams        : $TEAMS_CONNECTOR_ENABLED"

az account set --subscription "$SUBSCRIPTION"
require_agent_endpoint
run_v2_flow
deploy_arm_connectors

AZURESRE_TOKEN="$(get_sre_token)"

echo "==> Teams extras"
verify_teams_connector

if [[ "$SERVICENOW_HANDLER_ENABLED" == "true" ]]; then
  echo "==> ServiceNow extras"
  ensure_http_5xx_alert
  configure_servicenow_connection
  configure_servicenow_indexing
  upsert_response_plan_filter
  deploy_servicenow_logic_app
else
  echo "==> ServiceNow extras disabled"
fi

echo "==> Done"
echo "    Agent endpoint : $AGENT_ENDPOINT"
echo "    Portal         : https://sre.azure.com"
