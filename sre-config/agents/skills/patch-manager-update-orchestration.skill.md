# Patch Manager Skill: Update Orchestration

Use this skill as the execution contract for assessing and scheduling Grubify
container image refreshes and Azure VM guest patch maintenance.

## Scope

- Container scope: Azure Container Apps in the approved Grubify target resource
  group(s), normally `ca-grubify-api-*` and `ca-grubify-frontend-*`.
- VM scope: Azure virtual machines discovered in the approved target resource
  group(s) or explicit operator-provided VM resource IDs.
- Container update authority is the configured Grubify deployment workflow.
- VM update authority is Azure Update Manager or Azure-supported VM guest
  patching and maintenance assignment APIs.

## Runtime Parameters

Resolve parameters in this order: operator input -> environment/config ->
defaults.

- `environment_name` (default: `${AZURE_ENV_NAME}` or `e2e01`)
- `resource_token` (default: `${GRUBIFY_RESOURCE_TOKEN}` or
  `environment_name`)
- `target_resource_groups` (default: `${AZURE_RESOURCE_GROUP}` or
  `rg-grubify-app-${resource_token}`)
- `subscription_id` (default: `${AZURE_SUBSCRIPTION_ID}`)
- `maintenance_window` (required before scheduling)
- `timezone` (default: `UTC`)
- `duration` (default: `PT2H` for VM maintenance windows)
- `reboot_policy` (default: `IfRequired`)
- `classification_filter` (default: security and critical updates)
- `vm_scope` (optional VM resource IDs, names, tags, or resource groups)
- `container_update_mode` (default: `deployment-manager-handoff`)
- `release_profile` (default: `cart-leak-baseline` unless operator chooses a
  supported profile)
- `deploy_mode` (default: `deploy`)

If scheduling parameters are missing, run assessment and ask for the missing
values. Do not invent a maintenance window.

## Evidence Directory

Create one directory per attempt:

```text
/tmp/patch-manager-${resource_token}-${YYYYMMDDHHMMSS}
```

Store these artifacts when available:

- `inputs.json`
- `container-apps.json`
- `container-images.json`
- `acr-tags.json`
- `container-security-findings.json`
- `vms.json`
- `vm-patch-assessment.json`
- `maintenance-plan.json`
- `confirmation.txt`
- `schedule-result.json`

Never write secret values to evidence files.

## Assessment Workflow

1. Resolve subscription, resource groups, environment name, and resource token.
2. Verify resource groups exist before scanning.
3. Inventory Container Apps in scope.
4. Inventory VMs in scope.
5. Assess container image freshness.
6. Assess container security signals where available.
7. Assess VM patch state where VMs exist.
8. Produce a proposed action plan grouped by resource status.
9. Stop and wait for confirmation before scheduling or dispatching.

## Container Inventory

Use read-only Azure commands. Examples:

```bash
az containerapp list -g "$RG" -o json
az containerapp show -g "$RG" -n "$APP" -o json
az containerapp revision list -g "$RG" -n "$APP" -o json
```

Capture for each app:

- resource ID
- resource group
- active revision name
- container names
- current image repository, tag, and digest when available
- ingress FQDN
- latest revision health/status
- `azd-service-name` tag when present

If the image is the placeholder
`mcr.microsoft.com/azuredocs/containerapps-helloworld:latest`, classify the app
as `updates needed` with reason `placeholder image deployed`.

## Container Freshness Signals

Resolve ACR registry from app configuration, environment, or resource group
inventory. Use read-only commands such as:

```bash
az acr repository list -n "$ACR_NAME" -o json
az acr repository show-tags -n "$ACR_NAME" --repository "$REPOSITORY" --orderby time_desc -o json
az acr repository show-manifests -n "$ACR_NAME" --repository "$REPOSITORY" --orderby time_desc -o json
```

Compare the deployed image to available tags/manifests. Classify freshness:

- `updates needed`: a newer approved release tag/digest exists for the same
  repository and service.
- `no updates needed`: deployed tag/digest matches the latest approved release.
- `unable to determine`: image source cannot be mapped to an approved registry,
  tags are missing, or tag ordering is ambiguous.

Do not treat arbitrary `latest` tags as safe evidence unless the digest and build
metadata are available.

## Container Security Signals

Prefer Defender for Cloud, Azure Resource Graph, or Azure security assessment
evidence when available. Use read-only queries only. Useful evidence may include:

- container registry image vulnerability recommendations
- running container image vulnerability recommendations
- severity, CVE/package list, affected digest, and remediation availability
- recommendation status and timestamp

If Defender or security assessment data is unavailable, classify the security
signal as `unable to determine` and continue with freshness checks. Do not make
up vulnerability findings.

## VM Discovery

Discover VMs only in approved scope:

```bash
az vm list -g "$RG" -o json
az vm get-instance-view -g "$RG" -n "$VM" -o json
```

Capture for each VM:

- resource ID
- resource group and location
- OS type and image reference
- power state
- VM agent status
- patch mode and assessment mode
- tags relevant to maintenance scope

If no VMs are found, report `no VMs found` and do not create VM maintenance
resources.

## VM Patch Assessment

Use Azure-supported assessment paths. Prefer commands and APIs available in the
current Azure CLI context; call `GetAzCliHelp` before using unfamiliar commands.
Examples include:

```bash
az vm assess-patches -g "$RG" -n "$VM"
az vm install-patches --help
az maintenance configuration --help
az maintenance assignment --help
```

For each VM, classify:

- `updates needed`: missing security/critical updates or assessment reports a
  required patch install.
- `no updates needed`: assessment succeeds and reports no applicable updates.
- `unable to determine`: assessment unsupported, VM agent unhealthy, VM stopped
  when assessment requires it, permissions missing, or API unavailable.
- `out of scope or unsupported`: VM is outside approved scope or OS/platform is
  unsupported by the chosen patch path.

Record reboot requirement when reported.

## Confirmation Contract

Before any write operation, present the plan and wait for explicit confirmation.
The plan must include:

- selected resources
- action type (`container workflow dispatch`, `VM maintenance assignment`, or
  `assessment only`)
- proposed maintenance window and timezone
- VM reboot policy and update classifications
- container workflow inputs if a container refresh is proposed
- limitations and unresolved signals

If the operator changes scope or timing, repeat the plan and ask for
confirmation again.

## Container Scheduling

For normal Grubify container updates, do not directly mutate Container Apps.
After confirmation:

1. Build a deployment-manager handoff payload with:
   - `environment_name`
   - `resource_token`
   - `release_version`
   - `release_profile`
   - `deploy_mode`
   - patch evidence summary
2. Hand off to deployment-manager.
3. If handoff is unavailable and the operator approved immediate execution, use
   the deployment-manager skill's same GitHub MCP or Key Vault `GH-PAT` fallback
   dispatch path for `.github/workflows/deploy-grubify.yml`.
4. Track the workflow run and report run URL/status when dispatched directly.

For future-dated container updates, create a concrete maintenance plan. Do not
claim a schedule was created unless a real GitHub schedule, Azure schedule, or
SRE data-plane scheduled task was created. If no scheduling API is available,
report `future container scheduling unavailable in current platform path` and
provide the exact workflow inputs to run during the approved window.

## VM Scheduling

After confirmation, use Azure Update Manager or Azure maintenance assignments.
A typical flow is:

1. Create or reuse a maintenance configuration for guest patching in the target
   location and approved window.
2. Configure duration, timezone, recur-every schedule when requested,
   classifications, and reboot policy.
3. Assign the configuration to approved VM resource IDs or an approved dynamic
   scope.
4. Verify the assignment exists.
5. Report next scheduled run, assignment IDs, and resources included.

Use the current Azure CLI help output to choose exact flags because extension and
API syntax can vary. If the CLI/API cannot create the assignment, report the
failed command, status, and next action instead of trying an unsupported package
manager fallback.

## Direct VM Patch Install

Only run an immediate VM patch install when the operator explicitly approves
`install now` or an equivalent immediate action. Prefer a maintenance assignment
for scheduled work. Never broaden from one VM to all VMs without renewed
confirmation.

## Reporting Contract

Final assessment reports must include:

- assessment timestamp and evidence directory
- target subscription/resource groups
- container inventory and findings
- VM inventory and findings
- `updates needed`, `no updates needed`, `unable to determine`, and
  `out of scope or unsupported` sections
- proposed next action per resource
- confirmation status
- schedule/dispatch result when a confirmed action ran

## Handoff Payloads

Container update handoff to deployment-manager:

```json
{
  "source_agent": "patch-manager",
  "intent": "container_update",
  "environment_name": "...",
  "resource_token": "...",
  "release_version": "...",
  "release_profile": "...",
  "deploy_mode": "deploy",
  "evidence_directory": "/tmp/patch-manager-...",
  "summary": "..."
}
```

Scheduling failure handoff to incident-handler-core:

```json
{
  "source_agent": "patch-manager",
  "intent": "patch_schedule_failure",
  "resource_ids": ["..."],
  "evidence_directory": "/tmp/patch-manager-...",
  "failure_status": "...",
  "recommended_next_action": "..."
}
```

## Guardrails

- Never schedule or dispatch without explicit confirmation.
- Never print or persist secrets.
- Never use direct `az containerapp update` for normal refreshes.
- Never SSH into VMs or use ad hoc OS package commands.
- Never claim vulnerability status without a security assessment source.
- Never claim future-dated container scheduling succeeded unless a real schedule
  was created and verified.
- Keep production and broad-scope VM actions opt-in and explicit.
