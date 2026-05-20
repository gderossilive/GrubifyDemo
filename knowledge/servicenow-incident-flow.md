# Grubify ServiceNow Incident Flow

This document describes the primary ServiceNow incident-routing path for Grubify HTTP 5xx incidents.

## Purpose

Azure Monitor remains the metric signal source for HTTP 5xx detection, but ServiceNow is the incident system of record and the SRE Agent incident platform. Azure Monitor alerts call a Logic App through an Action Group Logic App receiver. The Logic App creates a ServiceNow incident and acknowledges the Azure Monitor alert. The SRE Agent then discovers the incident through its native ServiceNow incident platform and response-plan filter.

## Flow

1. Grubify API returns HTTP 5xx responses.
2. Azure Monitor metric alert `alert-http-5xx-grubify` fires.
3. Action group `ag-sre-grubify` calls Logic App `la-grubify-servicenow-handler` through a Logic App receiver named `sre-logic-app`.
4. The Logic App creates a ServiceNow incident through the Table API.
5. The Logic App acknowledges the Azure Monitor alert with a comment that references the ServiceNow incident number.
6. The SRE Agent ServiceNow incident platform indexes the ServiceNow incident.
7. The `grubify-http-errors` response filter routes the incident to `incident-handler`.
8. The `incident-handler` sub-agent retrieves details from ServiceNow, diagnoses the alert, remediates the application, and updates ServiceNow when ServiceNow tools are available.

## No Enriched Forwarding Payload

The Logic App does not post an enriched HTTP payload to the SRE Agent in the normal ServiceNow path. The SRE Agent should not expect `serviceNow.number`, `serviceNow.sysId`, or Azure alert details in an HTTP trigger body.

Instead, the SRE Agent receives the incident through native ServiceNow incident management. The `incident-handler` should use the current ServiceNow incident context to identify the incident number or sys_id, then call `GetServiceNowIncident` to retrieve:

- `short_description`
- `description`
- `comments`
- `correlation_id`
- `correlation_display`
- Azure alert identifiers copied into the ServiceNow incident

## Agent Behavior

The ServiceNow incident is expected in the normal Grubify incident path. Treat that incident as the system-of-record ticket.

Expected lifecycle:

1. Acknowledge the ServiceNow incident if `AcknowledgeServiceNowIncident` is available.
2. Call `GetServiceNowIncident` to retrieve the current ServiceNow record and correlation details.
3. Run the normal Grubify HTTP 5xx diagnostic workflow.
4. Add a ServiceNow discussion entry containing root cause, key evidence, remediation steps, and links to any GitHub issue or Teams summary.
5. Resolve the ServiceNow incident after impact clears if `ResolveServiceNowIncident` is available.
6. If ServiceNow tools are unavailable, complete the SRE investigation and include the ServiceNow incident number and URL in the final report.

## ServiceNow Fields

The Logic App creates incidents with these default fields:

- `short_description`: Grubify Azure alert name
- `description`: alert rule, severity, fired time, and affected resource
- `category`: value from `SERVICENOW_CATEGORY`, default `software`
- `urgency`: `2`
- `impact`: `2`
- `contact_type`: `integration`
- `correlation_id`: Azure alert origin ID or alert ID
- `correlation_display`: `Grubify HTTP 5xx signal`
- `assignment_group`: optional value from `SERVICENOW_ASSIGNMENT_GROUP`
- `comments`: Azure alert identifiers, investigation link, and SRE Agent handoff note

## SRE Agent ServiceNow Configuration

The SRE Agent incident management configuration uses the native `ServiceNow` platform. The portal-compatible Basic Auth shape is:

- `type`: `ServiceNow`
- `connectionName`: `servicenow`
- `connectionUrl`: ServiceNow instance URL
- `connectionKey`: JSON string containing `username` and `password`

Do not combine `apiConnectionName` with `connectionKey`. `apiConnectionName` is for OAuth-style configuration and the resource provider rejects it when Basic Auth is used.

ServiceNow incident indexing must also be configured through the SRE backend at `/api/v2/incidents/indexing/servicenow/configuration`. It requires:

- `providerType`: `servicenow`
- `assignmentGroup`: ServiceNow group sys_id or display value
- `lookbackDays`: default `30`

If `SERVICENOW_ASSIGNMENT_GROUP` is empty, `deploy-sre-agent.sh` tries common groups such as `Software`, `Service Desk`, `Incident Management`, and `Help Desk`.

## Troubleshooting

Check whether ServiceNow routing is enabled locally:

```bash
grep ENABLE_SERVICENOW_HANDLER .env
```

Confirm the Logic App deployment output was saved:

```bash
cat .azure/servicenow-handler-url
```

Confirm the action group Logic App receiver:

```bash
az monitor action-group show \
  --resource-group rg-grubify-sre \
  --name ag-sre-grubify \
  --query "{logicAppReceivers:logicAppReceivers[].{name:name,useCommonAlertSchema:useCommonAlertSchema,resourceId:resourceId},webhookCount:length(webhookReceivers)}" \
  -o table
```

Check recent Logic App runs:

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/<subscription-id>/resourceGroups/rg-grubify-sre/providers/Microsoft.Logic/workflows/la-grubify-servicenow-handler/runs?api-version=2016-06-01&\$top=5" \
  --query "value[].{status:properties.status,startTime:properties.startTime,endTime:properties.endTime}" \
  -o table
```

If no ServiceNow incident is created:

1. Verify `SERVICENOW_INSTANCE` or `SERVICENOW_INSTANCE_URL`, `SERVICENOW_USERNAME`, and `SERVICENOW_PASSWORD` in `.env`.
2. Verify the SRE portal ServiceNow validator reports the connection as valid.
3. Verify ServiceNow incident indexing has a non-empty assignment group.
4. Verify `ag-sre-grubify` has a Logic App receiver. If the alert fired while the action group was empty, Azure Monitor will not replay that old notification; wait for a new alert transition or use an action-group test notification.
5. Rerun `./scripts/deploy-sre-agent.sh` after fixing configuration.
