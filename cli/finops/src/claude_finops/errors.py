class FinOpsError(Exception):
    """A safe, actionable message; never include raw transport errors or tokens."""

    def __init__(self, message: str, code: int = 2):
        super().__init__(message)
        self.code = code


def http_error(status: int) -> FinOpsError:
    messages = {
        401: ("Sign-in expired. Run az login in the Turnstile tenant, then retry.", 3),
        403: ("Access refused. Ask an administrator to assign a Turnstile role or confirm your scope.", 4),
        404: ("Not found. Check the identifier, month and assigned scope.", 5),
        405: ("This server lacks this API. Deploy the claude-gateway Turnstile fork.", 5),
        409: ("Conflict. Refresh the parent budget and allocation; preview the change again.", 6),
        422: ("Server rejected the fields. Refresh and check limits, groups and parent allocation.", 2),
        429: ("Service throttled. Wait and retry; no write was automatically repeated.", 7),
    }
    message, code = messages.get(status, ("Service unavailable. Check status and retry; writes are not retried.", 7))
    return FinOpsError(f"HTTP {status}: {message}", code)
