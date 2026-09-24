"""Display-only pseudonyms. Raw authorization, filters and write targets are untouched."""

from hashlib import sha256
import re

EMAIL = re.compile(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
GUID = re.compile(r"\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b")
HOST = re.compile(r"\b[A-Za-z0-9.-]+\.(?:azurewebsites\.net|azure-api\.net)\b", re.I)
URL = re.compile(r"https?://[^\s\"'<>]+", re.I)
PERSON_KEYS = {"email", "user_name", "user_id", "actor", "updated_by", "changed_by", "created_by"}
PRIVATE_TEXT = {"description", "reason", "error_message", "ingest_error"}
PRIVATE_FIELDS = {"tenant", "tenant_id", "app_id", "client_id", "subscription_id", "workspace",
                  "repository", "resource_group", "apim_name", "entra_group", "external_ref"}


def digest(value):
    return sha256(str(value).casefold().encode("utf-8")).hexdigest()[:8]


def privacy_problems(text):
    issues = []
    if any(not item.lower().endswith("@contoso.com") for item in EMAIL.findall(text)):
        issues.append("non-Contoso address")
    if GUID.search(text):
        issues.append("GUID")
    if HOST.search(text):
        issues.append("service hostname")
    return issues


class Redactor:
    def __init__(self, enabled=False):
        self.enabled = enabled
        self.replacements = {}

    def alias(self, value, person=False):
        label = f"person-{digest(value)}@contoso.com" if person else f"contoso-{digest(value)}"
        self.replacements[str(value)] = label
        return label

    def _learn(self, value, key=""):
        if isinstance(value, dict):
            for child_key, child in value.items():
                self._learn(child, child_key)
        elif isinstance(value, list):
            for child in value:
                self._learn(child, key)
        elif isinstance(value, str) and value:
            if key in PERSON_KEYS or key.endswith("_by"):
                self.alias(value, person=True)
            elif key in PRIVATE_FIELDS or key in {"name", "scope_name"} or key.endswith("_name"):
                if key not in {"model_name"}:
                    self.alias(value)
            elif key == "id" or key.endswith("_id"):
                self.alias(value, person=bool(EMAIL.fullmatch(value)))

    def text(self, value):
        if not self.enabled:
            return str(value)
        text = str(value)
        for original, alias in sorted(self.replacements.items(), key=lambda pair: -len(pair[0])):
            text = re.sub(r"(?<![\w-])" + re.escape(original) + r"(?![\w-])", lambda _: alias, text)
        text = EMAIL.sub(lambda match: match[0] if match[0].lower().endswith("@contoso.com")
                         else f"person-{digest(match[0])}@contoso.com", text)
        text = GUID.sub(lambda match: f"id-{digest(match[0])}", text)
        text = HOST.sub(lambda match: f"service-{digest(match[0])}.contoso.com", text)
        return text

    def present(self, value):
        if not self.enabled:
            return value
        self._learn(value)
        return self._render(value)

    def _render(self, value, key=""):
        if isinstance(value, dict):
            return {self.text(k): self._render(v, k) for k, v in value.items()}
        if isinstance(value, list):
            return [self._render(item, key) for item in value]
        if isinstance(value, str):
            if key in PRIVATE_TEXT and value:
                return "[private text hidden]"
            if key == "title" and value:
                return "Usage finding (details hidden)"
            if key in {"url", "scope"} and "://" in value:
                return "https://service.contoso.com" if key == "url" else "api://contoso/AUM.Manage"
            return self.text(value)
        return value
