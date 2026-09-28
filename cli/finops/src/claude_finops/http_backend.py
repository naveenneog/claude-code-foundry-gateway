"""Same-origin delegated HTTP transport shared by the optional server backends."""

import httpx
from threading import RLock

from .backend import Backend
from .config import token, token_needs_refresh
from .errors import FinOpsError, http_error


class HttpBackend(Backend):
    identity_path = ""

    def __init__(self, config, token_provider=None, transport=None):
        config.validate()
        self.config = config
        self._token_provider = token_provider or (lambda: token(
            config.scope, config.subscription, config.tenant_id, timeout=self._token_timeout()))
        self._token = None
        self._credential_lock = RLock()
        self._credential_generation = 0
        self._features = None
        self._etags = {}
        self._client = httpx.Client(base_url=config.url.rstrip("/"), timeout=60,
                                    follow_redirects=False, transport=transport)

    def _request(self, method, path, params=None, body=None, extra_headers=None, optional=False):
        for attempt in range(2 if method == "GET" else 1):
            with self._credential_lock:
                if method == "GET" and path == self.identity_path and attempt == 0:
                    self._token = None
                if token_needs_refresh(self._token):
                    try:
                        self._token = self._token_provider()
                    except FinOpsError as error:
                        if error.code != 7:
                            raise
                        raise self._unavailable_error(method, path) from None
                generation, access = self._credential_generation, self._token
            try:
                response = self._client.request(method, path, params=params, json=body,
                    timeout=self._request_timeout(method, path),
                    headers={"Authorization": "Bearer " + access, **(extra_headers or {})})
            except httpx.TimeoutException:
                raise self._unavailable_error(method, path) from None
            except httpx.HTTPError:
                raise FinOpsError(f"{self.name} is unreachable. Check the HTTPS URL, VPN and network; writes are not retried.", 7) from None
            if generation != self._credential_generation:
                raise FinOpsError("The sign-in changed during this request. Refresh the current identity before reading data.", 3)
            if response.status_code == 401 and method == "GET" and attempt == 0:
                self._token = None
                continue
            if not 200 <= response.status_code < 300:
                if optional and response.status_code in {403, 404, 405}:
                    return None
                if response.status_code >= 500:
                    raise self._unavailable_error(method, path, response.status_code)
                raise http_error(response.status_code)
            if response.status_code == 204:
                return {"deleted": True}
            if response.headers.get("ETag"):
                self._etags[path] = response.headers["ETag"]
            try:
                payload = response.json()
                if not isinstance(payload, dict):
                    raise ValueError()
                return payload
            except ValueError:
                if optional and "text/html" in response.headers.get("content-type", ""):
                    return None
                raise FinOpsError("Unexpected server response. Check the API URL and compatible contract version.", 7) from None
        raise http_error(401)

    def _request_timeout(self, method, path):
        return 60

    def _token_timeout(self):
        return 120

    def _unavailable_error(self, method, path, status=None):
        if status:
            return http_error(status)
        return FinOpsError(f"{self.name} is unreachable. Check the HTTPS URL, VPN and network; writes are not retried.", 7)

    def close(self):
        self._token = None
        self._client.close()

    def invalidate_credentials(self):
        with self._credential_lock:
            self._credential_generation += 1
            self._token = None
            self._features = None
            self._etags.clear()
