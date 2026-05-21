import json
import os
from datetime import datetime, timezone
from pathlib import Path

import yaml

try:
    from agent_os.policies import PolicyEvaluator
    from agent_os.policies.schema import (
        PolicyAction,
        PolicyCondition,
        PolicyDefaults,
        PolicyDocument,
        PolicyOperator,
        PolicyRule,
    )
except ImportError as exc:
    raise ImportError(
        "governance_service_agt.py requires AGT Agent OS policy libraries. "
        "Install agent-os-kernel in the Function App runtime."
    ) from exc


class GovernanceServiceAgt:
    def __init__(self):
        self.mode = os.getenv("AGT_MODE", "agt-policy")
        self.audit_stdout = os.getenv("AGT_AUDIT_STDOUT", "true").lower() in {"1", "true", "yes"}
        policy_path = os.getenv("AGT_POLICY_PATH", "policies/grubify-sre-agent-policy-agt.yaml")
        self.policy_path = Path(policy_path)
        if not self.policy_path.is_absolute():
            self.policy_path = Path(__file__).parent / self.policy_path
        self.policy_config = self._load_policy_config()
        self.policy_document = self._build_policy_document(self.policy_config)
        self.evaluator = PolicyEvaluator(policies=[self.policy_document])

    def _load_policy_config(self):
        with self.policy_path.open(encoding="utf-8") as policy_file:
            return yaml.safe_load(policy_file) or {}

    def _build_policy_document(self, policy_config):
        defaults_config = policy_config.get("defaults") or {}
        default_action = self._policy_action(defaults_config.get("action", "allow"))
        rules = []
        for item in policy_config.get("rules") or []:
            condition_config = item.get("condition") or {}
            rules.append(
                PolicyRule(
                    name=item["name"],
                    condition=PolicyCondition(
                        field=condition_config.get("field", "tool_name"),
                        operator=self._policy_operator(condition_config.get("operator", "equals")),
                        value=condition_config.get("value"),
                    ),
                    action=self._policy_action(item.get("action", "allow")),
                    message=item.get("message", "Governance policy decision."),
                    priority=int(item.get("priority", 0)),
                )
            )
        return PolicyDocument(
            name=policy_config.get("name", "grubify-sre-agent-policy-agt"),
            version=str(policy_config.get("version", "1.0")),
            description=policy_config.get("description", "Grubify SRE Agent governance policy."),
            defaults=PolicyDefaults(action=default_action),
            rules=rules,
        )

    def _policy_action(self, value):
        normalized = str(value or "allow").upper()
        return PolicyAction.DENY if normalized == "DENY" else PolicyAction.ALLOW

    def _policy_operator(self, value):
        normalized = str(value or "equals").lower()
        mapping = {
            "equals": PolicyOperator.EQ,
            "eq": PolicyOperator.EQ,
            "in": PolicyOperator.IN,
            "contains": PolicyOperator.CONTAINS,
            "matches": PolicyOperator.MATCHES,
        }
        return mapping.get(normalized, PolicyOperator.EQ)

    def health(self):
        return {
            "status": "healthy",
            "mode": self.mode,
            "policy": self.policy_document.name,
            "policyVersion": self.policy_document.version,
            "policyPath": str(self.policy_path),
            "ruleCount": len(self.policy_config.get("rules") or []),
            "loadedAtUtc": datetime.now(timezone.utc).isoformat(),
        }

    def evaluate_hook(self, request_body):
        hook_type = request_body.get("hook_type", "")
        context = request_body.get("context") or {}
        if hook_type == "pre_tool_policy":
            decision = self._evaluate_pre_tool(context)
        elif hook_type == "stop_quality":
            decision = self._evaluate_stop_quality(context)
        else:
            decision = self._allow(f"[AGT] {hook_type or 'hook'} accepted.")
        self._audit(hook_type, context, decision)
        return decision

    def _evaluate_pre_tool(self, context):
        tool_name = self._find_value(context, ["tool_name", "toolName", "name"]) or ""
        tool_input = self._find_value(context, ["tool_input", "toolInput", "input", "arguments"]) or ""
        evaluation_context = {
            "agent_id": self._find_value(context, ["agent_id", "agentId", "agentName"]) or "incident-handler-agt",
            "action": "tool_call",
            "tool_name": str(tool_name),
            "input_text": json.dumps(tool_input, default=str) if not isinstance(tool_input, str) else tool_input,
        }
        result = self.evaluator.evaluate(evaluation_context)
        if getattr(result, "allowed", False):
            return self._allow(getattr(result, "reason", "[AGT] Tool call allowed."))
        return self._block(getattr(result, "reason", "[AGT] Tool call blocked by governance policy."))

    def _evaluate_stop_quality(self, context):
        output_text = str(self._find_value(context, ["output_text", "output", "response", "finalResponse"]) or "")
        for rule in self.policy_config.get("rules") or []:
            if rule.get("hook_type") != "stop_quality":
                continue
            condition = rule.get("condition") or {}
            if condition.get("operator") == "missing_any":
                expected_terms = [str(term).lower() for term in condition.get("value") or []]
                lowered = output_text.lower()
                if any(term not in lowered for term in expected_terms):
                    return self._block(rule.get("message", "[AGT] Final response quality check failed."))
        return self._allow("[AGT] Final response quality check passed.")

    def _find_value(self, value, names):
        if isinstance(value, dict):
            for name in names:
                if name in value:
                    return value[name]
            for nested in value.values():
                found = self._find_value(nested, names)
                if found is not None:
                    return found
        elif isinstance(value, list):
            for item in value:
                found = self._find_value(item, names)
                if found is not None:
                    return found
        return None

    def _allow(self, message):
        return {"allowed": True, "message": message}

    def _block(self, message):
        return {"allowed": False, "message": message}

    def _audit(self, hook_type, context, decision):
        if not self.audit_stdout:
            return
        print(json.dumps({
            "event": "agt_governance_decision",
            "hook_type": hook_type,
            "allowed": decision.get("allowed"),
            "message": decision.get("message"),
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "agent": self._find_value(context, ["agent_id", "agentId", "agentName"]),
            "tool": self._find_value(context, ["tool_name", "toolName", "name"]),
        }, default=str))
