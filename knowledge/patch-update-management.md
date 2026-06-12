# Patch And Update Management Runbook

This runbook documents how the `patch-manager` SRE Agent subagent assesses and
schedules Grubify container updates and Azure VM patch maintenance.

## Scope

`patch-manager` covers two resource families:

- Grubify Azure Container Apps in the target application resource group.
- Azure VMs discovered in approved target resource groups or explicit VM scope.

Current Grubify infrastructure provisions Container Apps and does not define VMs.
When no VMs are found, the correct result is `no VMs found`.

## Operating Model

The subagent runs in two phases:

1. Assessment: inventory resources, collect freshness/security/patch evidence,
   and propose a maintenance plan.
2. Scheduling: after explicit operator confirmation, schedule or dispatch the
   approved update path.

Assessment-only and dry-run requests never mutate resources.

## Container Update Model

Container updates use the existing Grubify deployment authority:

- Workflow: `.github/workflows/deploy-grubify.yml`
- Primary subagent handoff: `deployment-manager`
- Normal deploy mode: `deploy`

`patch-manager` should not directly call `az containerapp update` for normal
refreshes. It should assess deployed images and hand off the approved refresh to
`deployment-manager` with workflow inputs:

- `environment_name`
- `resource_token`
- `release_version`
- `release_profile`
- `deploy_mode`

Direct Container App mutation is a break-glass path only and requires explicit
operator approval that names the resource and action.

## Container Assessment Signals

Freshness signals:

- Deployed Container App image tag and digest.
- ACR repository tags/manifests ordered by push time.
- Release tag or workflow release metadata when available.

Security signals:

- Defender for Cloud container image vulnerability recommendations.
- Azure Resource Graph security assessment records.
- Recommendation severity, affected digest, and remediation state.

If Defender or security data is not enabled, report security signal as
`unable to determine` and continue with freshness checks.

## VM Patch Model

VM updates use Azure-supported patching primitives:

- Azure Update Manager.
- Maintenance configurations and assignments.
- VM guest patch assessment/install commands where supported.

Do not SSH into VMs or run package-manager commands manually.

## VM Assessment Signals

For each VM, collect:

- Resource ID, OS type, location, and power state.
- VM agent state.
- Patch mode and assessment mode.
- Patch assessment result.
- Missing security or critical update count.
- Reboot requirement when reported.

Classify each VM as:

- `updates needed`
- `no updates needed`
- `unable to determine`
- `out of scope or unsupported`

## Confirmation Requirements

Before scheduling, `patch-manager` must show:

- Target environment and resource groups.
- Resources selected for update.
- Proposed container workflow inputs or VM maintenance configuration details.
- Maintenance window, timezone, duration, and reboot policy.
- Known gaps, including unavailable security data or unsupported VMs.

Only proceed after explicit operator confirmation.

## Scheduling Behavior

For confirmed immediate container refreshes, hand off to `deployment-manager` or
use its documented GitHub MCP/Key Vault dispatch path if direct handoff is not
available.

For future-dated container refreshes, create a concrete maintenance plan. Do not
claim a schedule exists unless a real GitHub schedule, Azure schedule, or SRE
data-plane scheduled task was created and verified.

For confirmed VM maintenance, create or reuse an Azure maintenance configuration
and assign it to the approved VMs or dynamic scope. Verify assignments and report
the next scheduled run.

## Evidence

Use one evidence directory per run:

```text
/tmp/patch-manager-${resource_token}-${YYYYMMDDHHMMSS}
```

Store inputs, inventories, security findings, patch assessments, proposed plans,
confirmation, and scheduling results. Do not store secrets.

## Escalation

Hand off to `incident-handler-core` when:

- patch scheduling fails because of Azure permission or platform errors,
- an update attempt leaves resources unhealthy,
- required security evidence indicates active exploit risk,
- the operator requests incident handling.
