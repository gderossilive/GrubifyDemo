#!/usr/bin/env python3
"""Assemble Grubify SRE Agent v2 deployment artifacts."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
DEFAULT_OUTPUT_DIR = PROJECT_DIR / "build"
ENV_PLACEHOLDER_PATTERN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")


def expand_env_placeholders(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: expand_env_placeholders(item) for key, item in value.items()}
    if isinstance(value, list):
        return [expand_env_placeholders(item) for item in value]
    if not isinstance(value, str):
        return value

    def replace(match: re.Match[str]) -> str:
        env_name, default = match.groups()
        return os.environ.get(env_name, default or "")

    return ENV_PLACEHOLDER_PATTERN.sub(replace, value)


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return expand_env_placeholders(json.load(handle))


def load_yaml(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        loaded = yaml.safe_load(handle)
    return expand_env_placeholders(loaded or {})


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def env_or_config(env_name: str, value: str, default: str = "") -> str:
    return os.environ.get(env_name) or value or default


def resolve_governance(agent_config: dict[str, Any]) -> dict[str, str]:
    governance = agent_config.get("governance") or {}
    return {
        "functionUrl": env_or_config("AGT_FUNCTION_URL", governance.get("functionUrl", "")),
        "authMode": env_or_config("AGT_AUTH_MODE", governance.get("authMode", "none"), "none"),
        "clientId": env_or_config("AGT_CLIENT_ID", governance.get("clientId", "")),
        "functionKey": env_or_config("AGT_FUNCTION_KEY", governance.get("functionKey", "")),
    }


def connector_values(connectors_config: dict[str, Any]) -> dict[str, str]:
    github = connectors_config.get("github") or {}
    teams = connectors_config.get("teams") or {}
    return {
        "GITHUB_REPO_PLACEHOLDER": os.environ.get("GITHUB_REPO") or f"{github.get('owner', 'gderossilive')}/{github.get('name', 'GrubifyDemo')}",
        "TEAMS_TENANT_ID_PLACEHOLDER": os.environ.get("TEAMS_TENANT_ID") or teams.get("tenantId", ""),
        "TEAMS_GROUP_ID_PLACEHOLDER": os.environ.get("TEAMS_GROUP_ID") or teams.get("groupId", ""),
        "TEAMS_CHANNEL_ID_PLACEHOLDER": os.environ.get("TEAMS_CHANNEL_ID") or teams.get("channelId", ""),
        "AZURESRE_AGENT_ENDPOINT_PLACEHOLDER": os.environ.get("AGENT_ENDPOINT", ""),
    }


def resolve_hooks(raw_hooks: dict[str, Any], yaml_path: Path, governance: dict[str, str]) -> dict[str, Any]:
    if not raw_hooks:
        return {}

    placeholders = {
        "##AGT_FUNCTION_URL##": governance["functionUrl"],
        "##AGT_AUTH_MODE##": governance["authMode"],
        "##AGT_CLIENT_ID##": governance["clientId"],
        "##AGT_FUNCTION_KEY##": governance["functionKey"],
    }

    resolved_hooks: dict[str, Any] = {}
    for event_name, hook_list in raw_hooks.items():
        if not isinstance(hook_list, list):
            raise ValueError(f"hooks.{event_name} in {yaml_path.name} must be a list")

        resolved_hooks[event_name] = []
        for hook in hook_list:
            if not isinstance(hook, dict):
                raise ValueError(f"hooks.{event_name} entries in {yaml_path.name} must be objects")

            resolved_hook = dict(hook)
            script_file = resolved_hook.pop("script_file", None)
            hook_type = resolved_hook.pop("hook_type", resolved_hook.pop("hookType", event_name))
            if script_file:
                script_path = (yaml_path.parent / script_file).resolve()
                if not script_path.exists():
                    raise FileNotFoundError(f"Missing hook script for {yaml_path.name}: {script_path}")
                script = script_path.read_text(encoding="utf-8")
                for old, new in {**placeholders, "##AGT_HOOK_TYPE##": str(hook_type)}.items():
                    script = script.replace(old, new)
                resolved_hook["script"] = script
            resolved_hooks[event_name].append(resolved_hook)
    return resolved_hooks


def render_agent_yaml(yaml_path: Path, replacements: dict[str, str], governance: dict[str, str]) -> str:
    raw = yaml_path.read_text(encoding="utf-8")
    for old, new in replacements.items():
        raw = raw.replace(old, new)

    data = yaml.safe_load(raw) or {}
    spec = data.get("spec", data)
    prompt_file = spec.pop("system_prompt_file", None)
    if prompt_file:
        prompt_path = (yaml_path.parent / prompt_file).resolve()
        if not prompt_path.exists():
            raise FileNotFoundError(f"Missing system prompt file for {yaml_path.name}: {prompt_path}")
        prompt = prompt_path.read_text(encoding="utf-8")
        for old, new in replacements.items():
            prompt = prompt.replace(old, new)
        spec["system_prompt"] = prompt.rstrip("\n")

    hooks = resolve_hooks(spec.get("hooks") or {}, yaml_path, governance)
    if hooks:
        spec["hooks"] = hooks
    return yaml.safe_dump(data, sort_keys=False)


def build_subagent_entry(yaml_path: Path, rendered_yaml: str) -> dict[str, Any]:
    data = yaml.safe_load(rendered_yaml) or {}
    spec = data.get("spec", data)
    return {
        "name": spec["name"],
        "type": "ExtendedAgent",
        "source": str(yaml_path.relative_to(PROJECT_DIR)),
        "yaml": rendered_yaml,
        "metadata": {
            "description": spec.get("handoff_description", ""),
            "agentType": spec.get("agent_type", "Autonomous"),
        },
    }


def build_knowledge_entries(knowledge_dir: Path) -> list[dict[str, Any]]:
    if not knowledge_dir.exists():
        return []
    return [
        {
            "name": path.name,
            "source": str(path.relative_to(PROJECT_DIR)),
            "contentType": "text/markdown",
        }
        for path in sorted(knowledge_dir.glob("*.md"))
    ]


def build_knowledge_connector_entries(knowledge_dir: Path) -> list[dict[str, Any]]:
    if not knowledge_dir.exists():
        return []
    entries = []
    for path in sorted(knowledge_dir.glob("*.md")):
        connector_name = f"knowledge-{path.stem}".lower().replace("_", "-")
        entries.append({
            "name": connector_name,
            "properties": {
                "dataConnectorType": "KnowledgeText",
                "dataSource": connector_name,
                "extendedProperties": {
                    "displayName": path.name,
                    "content": path.read_text(encoding="utf-8"),
                    "contentType": "text/markdown",
                    "metadata.originalName": path.name,
                },
                "identity": "system",
            },
        })
    return entries


def build_incident_platform_entries(incident_platforms_dir: Path) -> list[dict[str, Any]]:
    if not incident_platforms_dir.exists():
        return []
    entries = []
    for path in sorted(incident_platforms_dir.glob("*.yaml")):
        data = load_yaml(path)
        metadata = data.get("metadata") or {}
        spec = data.get("spec") or {}
        if isinstance(spec.get("lookbackDays"), str) and spec["lookbackDays"].isdigit():
            spec["lookbackDays"] = int(spec["lookbackDays"])
        name = metadata.get("name") or spec.get("name") or path.stem
        entries.append({
            "name": name,
            "source": str(path.relative_to(PROJECT_DIR)),
            "spec": spec,
        })
    return entries


def build_repo_entries(connectors_config: dict[str, Any]) -> list[dict[str, Any]]:
    github = connectors_config.get("github") or {}
    repo = os.environ.get("GITHUB_REPO")
    if repo and "/" in repo:
        owner, name = repo.split("/", 1)
    else:
        owner = os.environ.get("GITHUB_USER") or github.get("owner", "gderossilive")
        name = github.get("name", "GrubifyDemo")
    if not owner or not name:
        return []
    return [{
        "name": name,
        "spec": {
            "url": f"https://github.com/{owner}/{name}",
            "type": "github",
            "branch": github.get("branch", "main"),
        },
    }]


def load_expected_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    return load_json(path)


def build_parameters(agent_config: dict[str, Any], connectors_config: dict[str, Any]) -> dict[str, Any]:
    identity = agent_config.get("identity") or {}
    access = agent_config.get("access") or {}
    content = agent_config.get("content") or {}
    knowledge_dir = PROJECT_DIR / content.get("knowledgePath", "knowledge")
    toggles = connectors_config.get("toggles") or {}
    connectors = connectors_config.get("connectors", []) + build_knowledge_connector_entries(knowledge_dir)
    return {
        "metadata": {
            "schema": "grubify-sre-agent-v2.parameters/v1",
            "generatedBy": "bin/assemble-agent.py",
        },
        "parameters": {
            "sreAgentName": identity.get("agentName", "sre-agent-grubify"),
            "sreResourceGroupName": identity.get("resourceGroup", ""),
            "location": identity.get("location", "swedencentral"),
            "sreTargetResourceIds": identity.get("targetResourceGroups", []),
            "sreAccessLevel": access.get("accessLevel", "High"),
            "sreActionMode": access.get("actionMode", "autonomous"),
            "sreConnectors": connectors,
            "sreConnectorToggles": toggles,
            "sreAppInsightsResourceId": connectors_config.get("appInsightsResourceId", ""),
            "sreAppInsightsAppId": connectors_config.get("appInsightsAppId", ""),
            "sreLogAnalyticsWorkspaceId": connectors_config.get("lawResourceId", ""),
            "sreAzureMonitorScope": connectors_config.get("azureMonitorScope", ""),
        },
    }


def build_extras(agent_config: dict[str, Any], connectors_config: dict[str, Any]) -> dict[str, Any]:
    content = agent_config.get("content") or {}
    agents_dir = PROJECT_DIR / content.get("agentsPath", "sre-config/agents")
    knowledge_dir = PROJECT_DIR / content.get("knowledgePath", "knowledge")
    incident_platforms_dir = PROJECT_DIR / content.get("incidentPlatformsPath", "sre-config/incident-platforms")
    expected_config_path = PROJECT_DIR / content.get("expectedConfigPath", "sre-config/expected-config.json")
    requested_agents = content.get("agents") or []
    governance = resolve_governance(agent_config)
    replacements = connector_values(connectors_config)
    repos = build_repo_entries(connectors_config)
    expected_config = load_expected_config(expected_config_path)
    if repos:
        expected_config["repos"] = [repo["name"] for repo in repos]

    subagents = []
    for agent_name in requested_agents:
        yaml_path = agents_dir / f"{agent_name}.yaml"
        if not yaml_path.exists():
            raise FileNotFoundError(f"Configured agent YAML does not exist: {yaml_path}")
        rendered_yaml = render_agent_yaml(yaml_path, replacements, governance)
        subagents.append(build_subagent_entry(yaml_path, rendered_yaml))

    return {
        "metadata": {
            "schema": "grubify-sre-agent-v2.extras/v1",
            "generatedBy": "bin/assemble-agent.py",
        },
        "agent": agent_config,
        "connectors": connectors_config.get("connectors", []),
        "connectorToggles": connectors_config.get("toggles") or {},
        "repos": repos,
        "knowledge": build_knowledge_entries(knowledge_dir),
        "incidentPlatforms": build_incident_platform_entries(incident_platforms_dir),
        "expectedConfig": expected_config,
        "skills": [],
        "subagents": subagents,
        "tools": [],
        "hooks": [],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Assemble Grubify SRE Agent v2 artifacts.")
    parser.add_argument("--agent-config", default="agent.json")
    parser.add_argument("--connectors-config", default="connectors.json")
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_DIR))
    parser.add_argument("--dry-run", action="store_true", help="Validate and print a summary without writing files.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    agent_config = load_json(PROJECT_DIR / args.agent_config)
    connectors_config = load_json(PROJECT_DIR / args.connectors_config)
    parameters = build_parameters(agent_config, connectors_config)
    extras = build_extras(agent_config, connectors_config)

    print("Grubify SRE Agent v2 assembly")
    print(f"  Agent     : {parameters['parameters']['sreAgentName']}")
    print(f"  Knowledge : {len(extras['knowledge'])} files")
    print(f"  Subagents : {len(extras['subagents'])}")
    print(f"  Dry run   : {args.dry_run}")

    if not args.dry_run:
        output_dir = Path(args.output_dir)
        if not output_dir.is_absolute():
            output_dir = PROJECT_DIR / output_dir
        write_json(output_dir / "agent.parameters.json", parameters)
        write_json(output_dir / "agent.extras.json", extras)
        print(f"  Wrote     : {output_dir / 'agent.parameters.json'}")
        print(f"  Wrote     : {output_dir / 'agent.extras.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())