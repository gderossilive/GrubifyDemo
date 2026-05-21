#!/usr/bin/env python3
"""
SRE Agent hook bridge to the Grubify AGT governance endpoint.

This file is embedded inline into SRE Agent hook configuration by the deploy
script. Keep it stdlib-only; the SRE hook sandbox does not install packages.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

FUNCTION_URL = "##AGT_FUNCTION_URL##".rstrip("/")
AUTH_MODE = "##AGT_AUTH_MODE##"
CLIENT_ID = "##AGT_CLIENT_ID##"
FUNCTION_KEY = "##AGT_FUNCTION_KEY##"
HOOK_TYPE = "##AGT_HOOK_TYPE##"
TIMEOUT_SECONDS = 20


def _read_context():
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except Exception:
        return {"raw": raw}


def _allow(message):
    return {"allowed": True, "message": message}


def _block(message):
    return {"allowed": False, "message": message}


def _token_from_imds():
    resource = CLIENT_ID or "https://management.azure.com/"
    query = urllib.parse.urlencode({"api-version": "2018-02-01", "resource": resource})
    request = urllib.request.Request(
        "http://169.254.169.254/metadata/identity/oauth2/token?" + query,
        headers={"Metadata": "true"},
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload["access_token"]


def _headers():
    headers = {"Content-Type": "application/json"}
    auth_mode = AUTH_MODE.lower()
    if auth_mode in {"managed_identity", "mi"}:
        headers["Authorization"] = "Bearer " + _token_from_imds()
    elif auth_mode in {"function_key", "key"} and FUNCTION_KEY:
        headers["x-functions-key"] = FUNCTION_KEY
    return headers


def _call_governance(context):
    body = json.dumps({"hook_type": HOOK_TYPE, "context": context}).encode("utf-8")
    request = urllib.request.Request(
        FUNCTION_URL + "/api/hook",
        data=body,
        headers=_headers(),
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return json.loads(response.read().decode("utf-8"))


def main():
    context = _read_context()
    if not FUNCTION_URL or FUNCTION_URL.startswith("##"):
        print(json.dumps(_allow("[AGT] Governance endpoint is not configured.")))
        return

    try:
        decision = _call_governance(context)
    except urllib.error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")[:500]
        if HOOK_TYPE == "pre_tool_policy":
            print(json.dumps(_block("[AGT] Governance service rejected the request: " + details)))
        else:
            print(json.dumps(_allow("[AGT] Governance service error: " + details)))
        return
    except Exception as exc:
        if HOOK_TYPE == "pre_tool_policy":
            print(json.dumps(_block("[AGT] Governance service unavailable: " + str(exc))))
        else:
            print(json.dumps(_allow("[AGT] Governance service unavailable: " + str(exc))))
        return

    print(json.dumps(decision))


if __name__ == "__main__":
    main()
