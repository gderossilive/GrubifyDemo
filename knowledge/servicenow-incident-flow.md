# Grubify ServiceNow Incident Flow

This document describes the primary ServiceNow incident-routing path for Grubify HTTP 5xx incidents.

## Purpose

Azure Monitor remains the metric signal source for HTTP 5xx detection, but ServiceNow is the incident system of record. Azure Monitor alerts call a Logic App first. The Logic App creates a ServiceNow incident, then forwards the original Azure Monitor alert plus ServiceNow incident metadata to the SRE Agent HTTP trigger.

## Flow

1. Grubify API returns HTTP 5xx responses.
2. Azure Monitor metric alert `alert-http-5xx-grubify` fires.
3. Action group `ag-sre-grubify` calls Logic App `la-grubify-servicenow-handler`.
4. The Logic App creates a ServiceNow incident through the Table API.
5. The Logic App posts an enriched payload to the SRE Agent HTTP trigger.
6. The `incident-handler` sub-agent diagnoses the alert, remediates the application, and updates ServiceNow when ServiceNow tools are available.

## Enriched Payload

The SRE Agent receives a JSON body with these top-level fields:

- `source`: `servicenow-azure-resource-handler`
- `workflow`: Logic App workflow name
- `correlationId`: stable alert correlation value derived from the Azure alert payload
- `commonAlertSchema`: original Azure Monitor common alert schema payload
- `serviceNow.sysId`: ServiceNow incident sys_id
- `serviceNow.number`: ServiceNow incident number, for example `INC0012345`
- `serviceNow.state`: ServiceNow incident state returned by the create call
- `serviceNow.url`: direct ServiceNow incident URL

## Agent Behavior

The `serviceNow` object is expected in the normal Grubify incident path. Treat that incident as the system-of-record ticket.

Expected lifecycle:

1. Acknowledge the ServiceNow incident if `AcknowledgeServiceNowIncident` is available.
2. Fetch the current ServiceNow incident state with `GetServiceNowIncident` when available.
3. Add a ServiceNow discussion entry that autonomous investigation has started, including correlation ID, affected resource, and investigation window when available.
4. Run the normal Grubify HTTP 5xx diagnostic workflow.
5. Add a ServiceNow discussion entry with key evidence, suspected or confirmed root cause, and the planned remediation.
6. Before remediation, post the planned action. After remediation, post what changed and any resource or command evidence.
7. After verification, post final impact status and links to any GitHub issue or Teams summary.
8. Resolve the ServiceNow incident after impact clears if `ResolveServiceNowIncident` is available.
9. If ServiceNow tools are unavailable, complete the SRE investigation and include the ServiceNow incident number and URL in the final report.

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

## Troubleshooting

Check whether ServiceNow routing is enabled locally:

```bash
grep ENABLE_SERVICENOW_HANDLER .env
```

Confirm the Logic App deployment output was saved:

```bash
cat .azure/servicenow-handler-url
cat .azure/sre-trigger-url
```

Confirm the action group webhook route:

```bash
az monitor action-group show \
  --resource-group rg-grubify-sre \
  --name ag-sre-grubify \
  --query "properties.webhookReceivers[].{name:name,useCommonAlertSchema:useCommonAlertSchema}" \
  -o table
```

Check recent Logic App runs:

```bash
az logic workflow run list \
  --resource-group rg-grubify-sre \
  --name la-grubify-servicenow-handler \
  --query "[0:5].{status:status,startTime:startTime,endTime:endTime}" \
  -o table
```

If no ServiceNow incident is created, verify `SERVICENOW_INSTANCE` or `SERVICENOW_INSTANCE_URL`, `SERVICENOW_USERNAME`, and `SERVICENOW_PASSWORD` in `.env`, then rerun `./scripts/deploy-sre-agent.sh`.
