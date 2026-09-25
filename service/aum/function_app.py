import json
import logging

import azure.functions as func

from aum_service.bootstrap import application
from aum_service.notifications import record_warnings


app = func.FunctionApp()


@app.route(route="v1/{*route}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
           auth_level=func.AuthLevel.ANONYMOUS)
def http_api(req: func.HttpRequest) -> func.HttpResponse:
    # "Anonymous" is the Functions key setting, not permission to use the API.
    # Every route validates the Entra bearer token in Api.handle; keys grant nothing.
    api = application()
    status, body, headers = api.handle(req.method, "/api/v1/" + req.route_params.get("route", ""),
                                       dict(req.params), req.get_body(), dict(req.headers))
    return func.HttpResponse(json.dumps(body), status_code=status, headers=headers,
                             mimetype="application/json")


@app.timer_trigger(schedule="0 * * * * *", arg_name="timer", run_on_startup=False, use_monitor=True)
def expire_boosts(timer: func.TimerRequest) -> None:
    application().workflows.expire()


@app.timer_trigger(schedule="0 */15 * * * *", arg_name="timer", run_on_startup=False, use_monitor=True)
def warning_thresholds(timer: func.TimerRequest) -> None:
    try:
        record_warnings(application().service)
    except Exception:
        logging.error("AUM warning evaluation failed; next scheduled run will retry")
        raise
