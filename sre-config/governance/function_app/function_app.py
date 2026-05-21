import json
import logging

import azure.functions as func

from governance_service_agt import GovernanceServiceAgt

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)
service = GovernanceServiceAgt()


@app.route(route="ready", methods=["GET"])
def ready(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps({"status": "ready"}),
        mimetype="application/json",
        status_code=200,
    )


@app.route(route="health", methods=["GET"])
def health(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = service.health()
        status_code = 200
    except Exception as exc:
        logging.exception("Governance health check failed")
        body = {"status": "unhealthy", "error": str(exc)}
        status_code = 500
    return func.HttpResponse(
        json.dumps(body),
        mimetype="application/json",
        status_code=status_code,
    )


@app.route(route="hook", methods=["POST"])
def hook(req: func.HttpRequest) -> func.HttpResponse:
    try:
        request_body = req.get_json()
    except ValueError:
        return func.HttpResponse(
            json.dumps({"allowed": False, "message": "Invalid JSON hook payload."}),
            mimetype="application/json",
            status_code=400,
        )

    try:
        decision = service.evaluate_hook(request_body)
        status_code = 200 if decision.get("allowed", False) else 403
    except Exception as exc:
        logging.exception("Governance hook evaluation failed")
        decision = {"allowed": False, "message": f"Governance evaluation failed: {exc}"}
        status_code = 500

    return func.HttpResponse(
        json.dumps(decision),
        mimetype="application/json",
        status_code=status_code,
    )
