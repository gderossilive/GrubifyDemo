#!/usr/bin/env python3
"""Apply Grubify SRE Agent v2 generated data-plane extras."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
DEFAULT_EXTRAS_PATH = PROJECT_DIR / "build" / "agent.extras.json"
DEFAULT_TOKEN_RESOURCES = ("https://azuresre.dev", "https://azuresre.ai")
SRE_AGENT_API_VERSION = "2025-05-01-preview"


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def az(*args: str) -> str:
    result = subprocess.run(["az", *args], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"az {' '.join(args[:3])} ... failed:\n{result.stderr.strip()}")
    return result.stdout.strip()


def get_token() -> str:
    resources = [os.environ["SRE_AGENT_TOKEN_RESOURCE"]] if os.environ.get("SRE_AGENT_TOKEN_RESOURCE") else list(DEFAULT_TOKEN_RESOURCES)
    errors = []
    for token_resource in resources:
        try:
            return az("account", "get-access-token", "--resource", token_resource, "--query", "accessToken", "-o", "tsv")
        except RuntimeError as exc:
            errors.append(str(exc))
    raise RuntimeError("Could not get SRE data-plane token:\n" + "\n".join(errors))

def resolve_endpoint(resource_group: str, agent_name: str, subscription: str | None) -> str:
    args = [
        "resource",
        "show",
        "--resource-group",
        resource_group,
        "--resource-type",
        "Microsoft.App/agents",
        "--name",
        agent_name,
        "--api-version",
        SRE_AGENT_API_VERSION,
        "--query",
        "properties.agentEndpoint",
        "-o",
        "tsv",
    ]
    if subscription:
        args.extend(["--subscription", subscription])
    endpoint = az(*args)
    if not endpoint:
        raise RuntimeError(f"Could not resolve SRE Agent endpoint for {agent_name} in {resource_group}")
    return endpoint.rstrip("/")


def resolve_agent_identity(resource_group: str, agent_name: str, subscription: str | None) -> str:
    args = [
        "resource",
        "show",
        "--resource-group",
        resource_group,
        "--resource-type",
        "Microsoft.App/agents",
        "--name",
        agent_name,
        "--api-version",
        SRE_AGENT_API_VERSION,
        "--query",
        "identity.userAssignedIdentities | keys(@)[0]",
        "-o",
        "tsv",
    ]
    if subscription:
        args.extend(["--subscription", subscription])
    try:
        identity = az(*args)
    except RuntimeError:
        identity = ""
    return identity or "SystemAssigned"


def resolve_resource_group(args_resource_group: str | None, identity: dict[str, Any]) -> str | None:
    explicit = args_resource_group or os.environ.get("SRE_AGENT_RESOURCE_GROUP") or identity.get("resourceGroup")
    if explicit:
        return explicit

    resource_token = os.environ.get("GRUBIFY_RESOURCE_TOKEN") or os.environ.get("RESOURCE_TOKEN")
    if resource_token:
        return f"rg-grubify-sre-{resource_token}"

    app_resource_group = os.environ.get("AZURE_RESOURCE_GROUP")
    if app_resource_group and app_resource_group.startswith("rg-grubify-app-"):
        return app_resource_group.replace("rg-grubify-app-", "rg-grubify-sre-", 1)

    return app_resource_group


def http_call(method: str, url: str, token: str, body: bytes | None = None, content_type: str = "application/json") -> tuple[int, bytes]:
    request = urllib.request.Request(url, data=body, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    if body is not None:
        request.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()

def build_multipart(field_name: str, file_name: str, content: bytes, content_type: str) -> tuple[bytes, str]:
    boundary = f"----grubify-sre-{uuid.uuid4().hex}"
    chunks = [
        f"--{boundary}\r\n".encode(),
        f'Content-Disposition: form-data; name="{field_name}"; filename="{file_name}"\r\n'.encode(),
        f"Content-Type: {content_type}\r\n\r\n".encode(),
        content,
        b"\r\n",
        f"--{boundary}--\r\n".encode(),
    ]
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


def upload_knowledge(endpoint: str, token: str, entries: list[dict[str, Any]], dry_run: bool) -> None:
    if not entries:
        print("  Knowledge : none")
        return
    print(f"  Knowledge : {len(entries)} file(s)")
    for entry in entries:
        source = PROJECT_DIR / entry["source"]
        if dry_run:
            print(f"    would upload {entry['source']}")
            continue
        body, content_type = build_multipart("files", source.name, source.read_bytes(), entry.get("contentType", "text/markdown"))
        status, response = http_call("POST", f"{endpoint}/api/v1/agentmemory/upload", token, body, content_type)
        if status not in {200, 201, 202, 204}:
            raise RuntimeError(f"Knowledge upload failed for {source.name} (HTTP {status}): {response.decode(errors='replace')[:500]}")
        print(f"    uploaded {source.name}")


def apply_subagents(endpoint: str, token: str, entries: list[dict[str, Any]], dry_run: bool) -> None:
    if not entries:
        print("  Subagents : none")
        return
    print(f"  Subagents : {len(entries)} agent(s)")
    for entry in entries:
        if dry_run:
            print(f"    would apply {entry['name']} from {entry['source']}")
            continue
        status, response = http_call(
            "PUT",
            f"{endpoint}/api/v1/extendedAgent/apply",
            token,
            entry["yaml"].encode("utf-8"),
            "application/x-yaml",
        )
        if status not in {200, 201, 202, 204}:
            raise RuntimeError(f"Subagent apply failed for {entry['name']} (HTTP {status}): {response.decode(errors='replace')[:500]}")
        print(f"    applied {entry['name']}")


def install_github_pat(endpoint: str, token: str, dry_run: bool) -> None:
    github_pat = os.environ.get("GITHUB_PAT")
    if not github_pat:
        print("  GitHub auth: no GITHUB_PAT set")
        return
    if dry_run:
        print("  GitHub auth: would install PAT")
        return
    body = json.dumps({"accessToken": github_pat}).encode("utf-8")
    status, response = http_call("POST", f"{endpoint}/api/v1/Github/auth/pat", token, body)
    if status in {200, 201, 202, 204}:
        print("  GitHub auth: PAT installed")
        return
    if status == 405:
        print("  GitHub auth: PAT endpoint is not enabled on this backend; OAuth sign-in may still be required")
        return
    raise RuntimeError(f"GitHub PAT install failed (HTTP {status}): {response.decode(errors='replace')[:500]}")


def apply_github_pat_connector(endpoint: str, token: str, github_repos: list[dict[str, Any]], dry_run: bool) -> None:
    github_pat = os.environ.get("GITHUB_PAT")
    if not github_pat:
        print("    GitHub auth: no GITHUB_PAT set; cannot apply PAT connector")
        return
    repo_spec = (github_repos[0].get("spec") or {}) if github_repos else {}
    repo_url = (repo_spec.get("url") or "gderossilive/GrubifyDemo").rstrip("/")
    if repo_url.startswith("https://github.com/"):
        repo_path = repo_url.removeprefix("https://github.com/")
    else:
        repo_path = repo_url
    owner, _, repo_name = repo_path.partition("/")
    owner = owner or os.environ.get("GITHUB_REPO_OWNER") or "gderossilive"
    repo_name = repo_name or os.environ.get("GITHUB_REPO_NAME") or "GrubifyDemo"

    if dry_run:
        print("    GitHub auth: would apply PAT-backed connector/github")
        return

    connector_body = json.dumps({
        "name": "github",
        "type": "AgentConnector",
        "properties": {
            "dataConnectorType": "GitHubPat",
            "dataSource": "github-pat",
            "extendedProperties": {
                "owner": owner,
                "repository": repo_name,
                "accessToken": github_pat,
            },
        },
    }).encode("utf-8")
    status, response = http_call("PUT", f"{endpoint}/api/v2/extendedAgent/connectors/github", token, connector_body)
    if status not in {200, 201, 202, 204}:
        raise RuntimeError(f"GitHub PAT connector apply failed (HTTP {status}): {response.decode(errors='replace')[:500]}")
    print("    applied connector/github (GitHubPat)")


def apply_github_repos(
    endpoint: str,
    token: str,
    repos: list[dict[str, Any]],
    identity: str,
    dry_run: bool,
) -> None:
    github_repos = [repo for repo in repos if (repo.get("spec") or {}).get("type", "github").lower() == "github"]
    if not github_repos:
        print("  Code repos : none")
        return
    print(f"  Code repos : {len(github_repos)} GitHub repo(s)")
    # The OAuth-based 'github' connector shows as Disconnected in the SRE portal when
    # PAT install is unavailable, so skip it by default. Set
    # ENABLE_GITHUB_AUTH_CONNECTOR=true to opt back in (e.g. when OAuth sign-in is
    # configured manually in the portal).
    enable_github_auth = os.environ.get("ENABLE_GITHUB_AUTH_CONNECTOR", "false").lower() in {"1", "true", "yes"}
    if enable_github_auth:
        if os.environ.get("GITHUB_PAT"):
            apply_github_pat_connector(endpoint, token, github_repos, dry_run)
        elif not dry_run:
            connector_body = json.dumps({
                "name": "github",
                "type": "AgentConnector",
                "properties": {
                    "dataConnectorType": "GitHubOAuth",
                    "dataSource": "github-oauth",
                    "identity": identity,
                },
            }).encode("utf-8")
            status, response = http_call("PUT", f"{endpoint}/api/v2/extendedAgent/connectors/github", token, connector_body)
            if status not in {200, 201, 202, 204}:
                raise RuntimeError(f"GitHub connector apply failed (HTTP {status}): {response.decode(errors='replace')[:500]}")
            print("    applied connector/github (GitHubOAuth)")
        else:
            print("    GitHub auth: would apply connector/github")
    elif not dry_run:
        print("    skipped connector/github (set ENABLE_GITHUB_AUTH_CONNECTOR=true to enable)")
    for repo in github_repos:
        spec = repo.get("spec") or {}
        name = repo.get("name") or Path(spec.get("url", "").rstrip("/")).name
        url = spec.get("url") or ""
        if url and not url.startswith(("http://", "https://")) and "/" in url:
            url = f"https://github.com/{url}"
        if not name or not url:
            raise RuntimeError(f"Invalid GitHub repo entry: {repo}")
        if dry_run:
            print(f"    would apply repo/{name} ({url})")
            continue
        body = json.dumps({
            "name": name,
            "type": "CodeRepo",
            "properties": {
                "url": url,
                "type": "GitHub",
                "authConnectorName": "github",
            },
        }).encode("utf-8")
        status, response = http_call("PUT", f"{endpoint}/api/v2/repos/{name}", token, body)
        if status not in {200, 201, 202, 204}:
            raise RuntimeError(f"GitHub repo apply failed for {name} (HTTP {status}): {response.decode(errors='replace')[:500]}")
        print(f"    applied repo/{name}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Apply Grubify SRE Agent v2 data-plane extras.")
    parser.add_argument("--extras", default=str(DEFAULT_EXTRAS_PATH))
    parser.add_argument("--agent-name", default=None)
    parser.add_argument("--resource-group", "-g", default=None)
    parser.add_argument("--subscription", "-s", default=None)
    parser.add_argument("--endpoint", default=None)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--skip-knowledge", action="store_true")
    parser.add_argument("--skip-subagents", action="store_true")
    parser.add_argument("--skip-repos", action="store_true")
    parser.add_argument("--skip-verify", action="store_true", help="Reserved for parity with the PI-Buddy v2 workflow.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    extras_path = Path(args.extras)
    if not extras_path.is_absolute():
        extras_path = PROJECT_DIR / extras_path
    extras = load_json(extras_path)
    identity = (extras.get("agent") or {}).get("identity") or {}

    agent_name = args.agent_name or os.environ.get("SRE_AGENT_NAME") or identity.get("agentName")
    resource_group = resolve_resource_group(args.resource_group, identity)
    subscription = args.subscription or os.environ.get("AZURE_SUBSCRIPTION_ID")
    endpoint = (args.endpoint or os.environ.get("SRE_AGENT_ENDPOINT") or os.environ.get("AGENT_ENDPOINT") or "").rstrip("/")

    print("Grubify SRE Agent v2 apply")
    print(f"  Agent        : {agent_name or '<not set>'}")
    print(f"  Resource RG  : {resource_group or '<not set>'}")
    print(f"  Dry run      : {args.dry_run}")

    if not args.dry_run:
        if not endpoint:
            if not agent_name or not resource_group:
                raise RuntimeError("Provide --endpoint or set/provide SRE_AGENT_NAME and SRE_AGENT_RESOURCE_GROUP.")
            endpoint = resolve_endpoint(resource_group, agent_name, subscription)
        token = get_token()
        identity = resolve_agent_identity(resource_group, agent_name, subscription) if agent_name and resource_group else "SystemAssigned"
        print(f"  Endpoint     : {endpoint}")
    else:
        token = ""
        identity = "SystemAssigned"

    if not args.skip_knowledge:
        upload_knowledge(endpoint, token, extras.get("knowledge") or [], args.dry_run)
    if not args.skip_subagents:
        apply_subagents(endpoint, token, extras.get("subagents") or [], args.dry_run)
    if not args.skip_repos:
        apply_github_repos(endpoint, token, extras.get("repos") or [], identity, args.dry_run)

    if args.skip_verify:
        print("  Verify       : skipped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())