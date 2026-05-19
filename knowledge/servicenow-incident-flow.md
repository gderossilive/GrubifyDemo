# Grubify ServiceNow Incident Flow

This document describes the optional ServiceNow Azure Resource Handler path for Grubify HTTP 5xx incidents.

## Purpose

When ServiceNow integration is enabled, Azure Monitor alerts do not call the SRE Agent trigger directly. They call a Logic App first. The Logic App creates a ServiceNow incident, then forwards the original Azure Monitor alert plus ServiceNow incident metadata to the SRE Agent HTTP trigger.

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
- `commonAlertSchema`: original Azure Monitor common alert schema payload
- `serviceNow.sysId`: ServiceNow incident sys_id
- `serviceNow.number`: ServiceNow incident number, for example `INC0012345`
- `serviceNow.state`: ServiceNow incident state returned by the create call
- `serviceNow.url`: direct ServiceNow incident URL

## Agent Behavior

When a `serviceNow` object is present, treat that incident as the system-of-record ticket.

Expected lifecycle:

1. Acknowledge the ServiceNow incident if `AcknowledgeServiceNowIncident` is available.
2. Run the normal Grubify HTTP 5xx diagnostic workflow.
3. Add a ServiceNow discussion entry containing root cause, key evidence, remediation steps, and links to any GitHub issue or Teams summary.
4. Resolve the ServiceNow incident after impact clears if `ResolveServiceNowIncident` is available.
5. If ServiceNow tools are unavailable, complete the SRE investigation and include the ServiceNow incident number and URL in the final report.

## ServiceNow Fields

The Logic App creates incidents with these default fields:

- `short_description`: Grubify Azure alert name
- `description`: alert rule, severity, fired time, and affected resource
- `category`: value from `SERVICENOW_CATEGORY`, default `software`
- `urgency`: `2`
- `impact`: `2`
- `contact_type`: `integration`
- `assignment_group`: optional value from `SERVICENOW_ASSIGNMENT_GROUP`
- `comments`: serialized Azure Monitor alert payload

## Troubleshooting

Check whether ServiceNow is enabled locally:

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

If no ServiceNow incident is created, verify `SERVICENOW_INSTANCE_URL`, `SERVICENOW_USERNAME`, and `SERVICENOW_PASSWORD` in `.env`, then rerun `./scripts/deploy-sre-agent.sh`.
