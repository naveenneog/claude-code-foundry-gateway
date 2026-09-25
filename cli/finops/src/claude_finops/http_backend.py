"""Same-origin delegated HTTP transport shared by the optional server backends."""

import httpx

from .backend import Backend
from .config import token
from .errors import FinOpsError, http_error


class HttpBackend(Backend):
    def __init__(self, config, token_provider=None, transport=None):
        config.validate()
        self.config = config
        self._token_provider = token_provider or (lambda: token(config.scope, config.subscription, config.tenant_id))
        self._token = None
        self._features = None
        self._etags = {}
        self._client = httpx.Client(base_url=config.url.rstrip("/"), timeout=60,
                                    follow_redirects=False, transport=transport)

    def _request(self, method, path, params=None, body=None, extra_headers=None, optional=False):
        for attempt in range(2 if method == "GET" else 1):
            if not self._token:
                self._token = self._token_provider()
            try:
                response = self._client.request(method, path, params=params, json=body,
                    headers={"Authorization": "Bearer " + self._token, **(extra_headers or {})})
            except httpx.HTTPError:
                raise FinOpsError(f"{self.name} is unreachable. Check the HTTPS URL, VPN and network; writes are not retried.", 7) from None
            if response.status_code == 401 and method == "GET" and attempt == 0:
                self._token = None
                continue
            if not 200 <= response.status_code < 300:
                if optional and response.status_code in {403, 404, 405}:
                    return None
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

    def close(self):
        self._token = None
        self._client.close()
