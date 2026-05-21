---
name: grubify-issue-triage
description: >
  Run the Grubify Issue Triage demo (Act 3: Workflow Automation). Seeds sample customer issues
  in a GitHub repo and verifies the SRE Agent's issue-triager subagent can classify, label, and
  comment on them. USE FOR: triage grubify issues, create sample issues, run issue triage demo,
  verify issue-triager subagent, Demo6. DO NOT USE FOR: incident remediation (use grubify-incident),
  deploying grubify (use azd up).
---

# Grubify Issue Triage — Demo Skill

Run **Act 3: Workflow Automation** for the GrubifyIncidentLab demo. This skill seeds sample
customer issues in a GitHub repo and lets the `issue-triager` subagent classify, label, and
comment on each one.

## Working directory

Run commands from this repository root:

```bash
cd /workspaces/GrubifyDemo
```

## Step 1: Verify prerequisites

### 1a) GitHub PAT and user are configured

```bash
azd env get-value GITHUB_PAT 2>/dev/null | head -c 10 && echo "... (PAT set)"
azd env get-value GITHUB_USER 2>/dev/null
```

Both must return values. The PAT needs `repo` scope.

### 1b) Verify the issue-triager subagent exists on the SRE Agent

```bash
AGENT_ENDPOINT=<sre-agent-endpoint>
TOKEN=$(az account get-access-token --resource https://azuresre.ai --query accessToken -o tsv)
curl -s "${AGENT_ENDPOINT}/api/v2/extendedAgent/agents/issue-triager" \
  -H "Authorization: Bearer ${TOKEN}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Name: {d[\"name\"]}')"
```

Should print `Name: issue-triager`.

### 1c) Verify the scheduled task is active

```bash
curl -s "${AGENT_ENDPOINT}/api/v1/scheduledtasks" \
  -H "Authorization: Bearer ${TOKEN}" | python3 -c "
import sys,json
for t in json.load(sys.stdin):
    print(f'{t[\"name\"]} ({t[\"cronExpression\"]}) -> {t.get(\"agent\",\"(none)\")} [{t.get(\"status\",\"?\")}]')
"
```

Look for `triage-grubify-issues` (cron `0 */12 * * *` → `issue-triager`).

## Step 2: Create sample customer issues

The user must provide the target GitHub repo in `owner/repo` format. If not provided, ask for it.

```bash
export GITHUB_PAT=<github-pat>
repo=<owner/repo>
for title in \
  "App crashes when adding items to cart" \
  "Menu page loading slowly" \
  "Can't place an order - 500 error" \
  "Feature request - add restaurant search" \
  "How do I clear my cart?"; do
  curl -s -X POST "https://api.github.com/repos/${repo}/issues" \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "$(printf '{"title":"[Customer Issue] %s","body":"Sample customer issue for Grubify SRE triage demo."}' "$title")"
done
```

This creates 5 customer-reported issues prefixed with `[Customer Issue]`:

| # | Title | Expected classification |
|---|-------|------------------------|
| 1 | App crashes when adding items to cart | api-bug / memory-leak |
| 2 | Menu page loading slowly | performance |
| 3 | Can't place an order — 500 error | api-bug |
| 4 | Feature request — add restaurant search | feature-request |
| 5 | How do I clear my cart? | question |

## Step 3: Trigger or wait for triage

The `issue-triager` runs on a 12-hour cron schedule. Options to trigger it sooner:

- **SRE Agent portal**: Open https://sre.azure.com → find the `triage-grubify-issues` scheduled task → Run Now
- **Wait**: The cron will fire on the next 12-hour boundary

## Step 4: Verify triage results

After the triager runs, check GitHub issues in the target repo. Each `[Customer Issue]` should have:

1. **Classification labels** applied (e.g., `api-bug`, `memory-leak`, `feature-request`, `question`)
2. **A triage comment** starting with `🤖 **Grubify SRE Agent Bot**` containing:
   - Classification and sub-category
   - Brief analysis
   - Next steps or questions for the reporter
   - Status indicator

## Success criteria

- [ ] 5 sample issues created in the GitHub repo
- [ ] Scheduled task `triage-grubify-issues` is active
- [ ] After triage: issues have labels applied and triage comments posted
- [ ] Classifications are reasonable (cart crash → api-bug/memory-leak, search request → feature-request, etc.)

## Constraints

- Requires `GITHUB_PAT` with `repo` scope
- The GitHub MCP connector must be active on the SRE Agent
- Issue titles must contain `[Customer Issue]` to be picked up by the triager
- Do not manually label or comment on the issues — let the agent do it
