import json
import os
import re
import shutil
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path
from urllib.parse import urlsplit

from .errors import FinOpsError


def az(*args: str) -> str:
    # az is a cmd wrapper on Windows. A list alone does not neutralize cmd metacharacters.
    if any(re.search(r'[&|<>^%!"\r\n]', str(arg)) for arg in args):
        raise FinOpsError("Unsafe Azure CLI argument. Use a simple resource name or a JSON body file.")
    executable = shutil.which("az")
    if not executable:
        raise FinOpsError("Azure CLI is missing. Install Azure CLI, then run az login.", 3)
    try:
        result = subprocess.run([executable, *map(str, args)], capture_output=True, text=True,
                                encoding="utf-8", timeout=120, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise FinOpsError("Azure CLI did not finish. Check az account show and network access.", 7) from None
    if result.returncode:
        if "AADSTS50105" in result.stderr:
            raise FinOpsError("AADSTS50105: your account holds no Turnstile role. Ask an admin to assign Turnstile.Viewer or Turnstile.Admin.", 4)
        raise FinOpsError("Azure CLI refused the operation. Run az login in the correct tenant and check Azure role assignments.", 3)
    return result.stdout.strip()


def token(scope: str) -> str:
    value = az("account", "get-access-token", "--scope", scope, "--query", "accessToken", "-o", "tsv")
    if not value:
        raise FinOpsError("No access token. Run az login in the Turnstile tenant.", 3)
    return value


def parse_integration(value: str) -> dict:
    values = dict(pair.split("=", 1) for pair in value.split(";") if "=" in pair)
    if values.get("version") != "1":
        raise FinOpsError("Unsupported gateway integration version. Configure url and scope explicitly.")
    if not values.get("url") or not values.get("scope"):
        raise FinOpsError("Gateway has no Turnstile address and scope. Ask an admin to run Connect-ClaudeTurnstile.ps1.")
    return values


@dataclass
class Config:
    backend: str = "turnstile"
    url: str = ""
    scope: str = ""
    resource_group: str = ""
    apim_name: str = ""
    repository: str = ""
    workspace: str = ""
    theme: str = "gateway"
    ascii: bool = False

    def validate(self):
        if self.backend not in {"turnstile", "direct", "fake"}:
            raise FinOpsError("Backend must be turnstile, direct or fake.")
        if self.url:
            parsed = urlsplit(self.url)
            if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
                    or parsed.query or parsed.fragment or parsed.path not in {"", "/"}):
                raise FinOpsError("Turnstile URL must be an HTTPS origin without credentials, path or query.")
        if self.scope and not re.fullmatch(r"api://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+", self.scope):
            raise FinOpsError("Scope must be api://<client-id>/Turnstile.Manage.")
        for value in (self.resource_group, self.apim_name):
            if value and not re.fullmatch(r"[A-Za-z0-9._()-]+", value):
                raise FinOpsError("Use a simple Azure resource group and APIM name.")
        return self

    def public(self):
        return asdict(self)


def load_config(path: Path | None = None, **overrides) -> Config:
    path = path or Path(os.environ.get("CLAUDE_FINOPS_CONFIG", Path.home() / ".claude-finops" / "config.json"))
    values = {}
    if path.exists():
        try:
            values = json.loads(path.read_text(encoding="utf-8-sig"))
            if not isinstance(values, dict) or set(values) - set(Config.__dataclass_fields__):
                raise ValueError()
        except (OSError, ValueError):
            raise FinOpsError("Invalid config. Use documented address fields only; never store a token.") from None
    values.update({k: v for k, v in overrides.items() if v is not None})
    config = Config(**values).validate()
    if config.backend == "turnstile" and (not config.url or not config.scope):
        if not config.resource_group or not config.apim_name:
            raise FinOpsError("Set url and scope in ~/.claude-finops/config.json, or pass --url and --scope. For discovery set resource_group and apim_name.")
        raw = az("apim", "nv", "show", "-g", config.resource_group, "--service-name", config.apim_name,
                 "--named-value-id", "turnstile-integration", "--query", "value", "-o", "tsv")
        settings = parse_integration(raw)
        config.url = config.url or settings["url"]
        config.scope = config.scope or settings["scope"]
    return config.validate()
