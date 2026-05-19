# Grubify Teams Messaging Runbook

This document describes the optional Microsoft Teams notification behavior for Grubify SRE incident handling.

## Purpose

When the Microsoft Teams connector is configured in the SRE Agent portal, the incident handler posts a concise incident summary to the GrubifyOps channel after it completes the initial investigation. Teams notification is helpful for human awareness, but it must not block diagnosis, remediation, ServiceNow updates, or final reporting.

## Required Configuration

The deploy script renders Teams identifiers from local environment variables:

- `ENABLE_TEAMS_CONNECTOR`: set to `true` to require Teams connector verification.
- `TEAMS_TENANT_ID`: Microsoft Entra tenant ID.
- `TEAMS_GROUP_ID`: Microsoft Teams team group ID.
- `TEAMS_CHANNEL_ID`: target channel ID.
- `TEAMS_CLIENT_ID`: optional app registration client ID when connector auth supports automation.
- `TEAMS_CLIENT_SECRET`: optional app registration client secret when connector auth supports automation.

The portal-created connector observed on the reference `rg-grubify-sre` agent appears as service `Microsoft Teams` and exposes `PostTeamsMessage`, `GetTeamsMessages`, and `ReplyToTeamsMessage`. If an app registration is required during connector setup, it should have the Microsoft Graph application permission required to send channel messages, such as `ChannelMessage.Send`, and admin consent must be granted.

## Message Content

A Teams incident message should include:

1. Incident summary and current impact.
2. Root cause or leading hypothesis.
3. Key evidence, including metric values and short log excerpts.
4. Remediation action taken or recommended next action.
5. Links to related GitHub issue, ServiceNow incident, or SRE Agent thread when available.

Keep the message concise. Put large logs, stack traces, and full reports in GitHub or ServiceNow, then link to them.

## Fallback Behavior

If the Teams connector or Teams tool is unavailable:

1. Continue the SRE investigation.
2. Complete remediation or escalation.
3. Include `Teams notification skipped` in the final report with the connector or tool error if available.
4. Do not retry indefinitely.

## Verification

List data connectors:

```bash
curl -s "$AGENT_ENDPOINT/api/v1/extendedAgent/dataconnectors" \
  -H "Authorization: Bearer $AZURESRE_TOKEN"
```

List Teams-related system tools:

```bash
curl -s "$AGENT_ENDPOINT/api/v1/extendedAgent/systemtools" \
  -H "Authorization: Bearer $AZURESRE_TOKEN" | grep -i teams
```

Expected old-agent built-in Teams tools were:

- `GetTeamsMessages`
- `PostTeamsMessage`
- `ReplyToTeamsMessage`

If those built-in tools are not present, verify the Microsoft Teams connector in the SRE Agent portal under Builder > Connectors. The current preview API can list connectors but rejects `kind: DataConnector` YAML with `Unsupported kind: DataConnector`, so this connector must be created or authenticated in the portal.
