"""Internal piped token acquisition for the authorized Windows role-transition capture."""
import base64
import contextlib
import hashlib
import io
import json
import os
import sys
import time

import msal
import msal.broker as broker
from azure.cli.core import get_default_cli


def renew_token(scope):
    cli = get_default_cli()

    def acquire():
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = cli.invoke(["account", "get-access-token", "--scope", scope, "--output", "none"])
        if status:
            raise RuntimeError("Silent token acquisition failed; no interaction attempted")
        return cli.result.result["accessToken"]

    previous = acquire()
    original_acquire = msal.PublicClientApplication.acquire_token_silent_with_error
    original_parameters = broker._build_msal_runtime_auth_params
    renewed = []

    def force_msal(self, scopes, account, **kwargs):
        kwargs["force_refresh"] = True
        return original_acquire(self, scopes, account, **kwargs)

    def renew_broker(*args, **kwargs):
        parameters = original_parameters(*args, **kwargs)
        # MSAL.NET RuntimeBroker.AcquireTokenSilentAsync uses this same runtime option.
        # MSAL Python force_refresh alone bypasses its cache, not the Windows broker's.
        parameters.set_access_token_to_renew(previous)
        renewed.append(True)
        return parameters

    started = time.time()
    try:
        msal.PublicClientApplication.acquire_token_silent_with_error = force_msal
        broker._build_msal_runtime_auth_params = renew_broker
        fresh = acquire()
    finally:
        msal.PublicClientApplication.acquire_token_silent_with_error = original_acquire
        broker._build_msal_runtime_auth_params = original_parameters
    payload = fresh.split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    if not renewed or hashlib.sha256(previous.encode()).digest() == hashlib.sha256(fresh.encode()).digest():
        raise RuntimeError("Broker did not renew the access token")
    if claims.get("iat", 0) < started - 301 or claims.get("exp", 0) <= time.time():
        raise RuntimeError("Renewed token failed issue-time or expiration verification")
    return fresh


if __name__ == "__main__":
    if sys.stdout.isatty() or not os.environ.get("P53_RENEW_SCOPE"):
        raise SystemExit("Use the capture helper with piped output and an explicit scope")
    try:
        token = renew_token(os.environ["P53_RENEW_SCOPE"])
    except Exception as error:
        raise SystemExit(f"Silent Windows broker renewal failed ({type(error).__name__}); no cached fallback") from None
    sys.stdout.write(token)
