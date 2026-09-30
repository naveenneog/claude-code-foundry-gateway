import httpx


class FinOpsError(Exception):
    """A safe, actionable message; never include raw transport errors or tokens."""

    def __init__(self, message: str, code: int = 2, *, details: dict[str, str] | None = None):
        super().__init__(message)
        self.code = code
        self.details = details or {}


READ_FAILURES = (FinOpsError, OSError, httpx.HTTPError)
LOCATION_CHALLENGE = (
    "IP variation can trigger CAE. Stay fully on/off VPN; check IPv6. "
    "Ask the admin about a named location or exclusion."
)


def is_location_challenge(text: str) -> bool:
    folded = text.casefold()
    return "interactionrequired" in folded and "locationconditionevaluationsatisfied" in folded


def read_error(error: FinOpsError | OSError | httpx.HTTPError) -> FinOpsError:
    if isinstance(error, FinOpsError):
        return FinOpsError(LOCATION_CHALLENGE, 3) if is_location_challenge(str(error)) else error
    if isinstance(error, httpx.HTTPStatusError):
        return http_error(error.response.status_code)
    if isinstance(error, httpx.HTTPError):
        return FinOpsError("Network read failed. Check the connection, VPN and endpoint access; r retries.", 7)
    if isinstance(error, OSError):
        return FinOpsError("Backend I/O failed. Check the connection and local tool installation; r retries.", 7)
    raise TypeError("Only expected backend read failures can be normalized.")


def http_error(status: int) -> FinOpsError:
    messages = {
        401: ("Sign-in expired. Run az login in the selected backend's tenant, then retry.", 3),
        403: ("Not in your scope / not permitted for this sign-in. Choose a managed unit or team, or ask an administrator to confirm your role and assignments.", 4),
        404: ("Not found. Check the identifier, month and assigned scope.", 5),
        405: ("This server lacks this API. Check the selected backend's advertised capabilities and compatible API version.", 5),
        409: ("Conflict. Refresh the parent budget and allocation; preview the change again.", 6),
        412: ("State changed since preview. Refresh the collection and preview again; nothing was overwritten.", 6),
        422: ("Server rejected the fields. Refresh and check limits, groups and parent allocation.", 2),
        429: ("Service throttled. Wait and retry; no write was automatically repeated.", 7),
    }
    message, code = messages.get(status, ("Service unavailable. Check status and retry; writes are not retried.", 7))
    return FinOpsError(f"HTTP {status}: {message}", code)
