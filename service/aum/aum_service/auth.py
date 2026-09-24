from dataclasses import dataclass
from uuid import UUID

import jwt

from .errors import AccessDenied


def object_id(value):
    if not isinstance(value, str):
        raise ValueError("Object id must be a string")
    return str(UUID(value))


@dataclass(frozen=True)
class Identity:
    oid: str
    name: str
    email: str
    access: str
    groups: tuple[str, ...] | None
    expires_at: int

    @property
    def is_admin(self):
        return self.access == "admin"

    def require_admin(self):
        if not self.is_admin:
            raise AccessDenied("AUM.Admin is required")

    def require_writer(self):
        if self.access == "viewer":
            raise AccessDenied("AUM.Viewer is read-only")


def resolve_identity(claims):
    roles = claims.get("roles")
    scope = claims.get("scp")
    if (not isinstance(roles, list) or not all(isinstance(x, str) for x in roles)
            or not isinstance(scope, str) or "AUM.Access" not in scope.split()
            or claims.get("ver") != "2.0"):
        raise AccessDenied("A delegated AUM.Access token with an assigned AUM role is required")
    access = next((name.lower() for name in ("Admin", "Viewer", "Manager")
                   if f"AUM.{name}" in roles), None)
    if access is None:
        raise AccessDenied("An assigned AUM role is required")
    try:
        oid = object_id(claims.get("oid"))
    except ValueError as error:
        raise AccessDenied("A person object id is required") from error
    groups = None
    if access == "manager":
        groups = ()
        overage = claims.get("hasgroups") or (
            isinstance(claims.get("_claim_names"), dict) and "groups" in claims["_claim_names"]
        )
        raw = claims.get("groups", [])
        if not overage and isinstance(raw, list) and len(raw) <= 200:
            try:
                groups = tuple(sorted({object_id(g) for g in raw}))
            except ValueError:
                groups = ()
    return Identity(
        oid, str(claims.get("name") or ""),
        str(claims.get("preferred_username") or ""), access, groups, int(claims["exp"]),
    )


class TokenVerifier:
    def __init__(self, tenant_id, app_id, keys=None):
        self.tenant = object_id(tenant_id)
        self.audience = object_id(app_id)
        self.issuer = f"https://login.microsoftonline.com/{self.tenant}/v2.0"
        self.keys = keys or jwt.PyJWKClient(
            f"https://login.microsoftonline.com/{self.tenant}/discovery/v2.0/keys",
            cache_jwk_set=True, lifespan=3600, timeout=10,
        )

    def verify(self, token):
        if not isinstance(token, str) or len(token) > 32768:
            raise AccessDenied("Invalid access token", status=401)
        try:
            header = jwt.get_unverified_header(token)
            if header.get("alg") != "RS256":
                raise jwt.InvalidAlgorithmError()
            key = self.keys.get_signing_key_from_jwt(token).key
            claims = jwt.decode(
                token, key, algorithms=["RS256"], audience=self.audience, issuer=self.issuer,
                leeway=30, options={"require": ["exp", "iat", "nbf", "iss", "aud", "oid", "tid"]},
            )
            if claims["tid"].lower() != self.tenant:
                raise jwt.InvalidIssuerError()
            return resolve_identity(claims)
        except AccessDenied:
            raise
        except (jwt.PyJWTError, ValueError, TypeError, AttributeError) as error:
            raise AccessDenied("Invalid or expired AUM access token", status=401) from error
