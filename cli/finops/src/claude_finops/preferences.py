from copy import deepcopy
from hashlib import sha256
import json
from pathlib import Path
import re

from .errors import FinOpsError
from .rules import month_window

FILTERS = {"organization_id", "department_id", "user_id", "model_id", "runtime", "tier", "from", "to"}


class Preferences:
    def __init__(self, identity, profile, root=None, *, memory=False):
        key = sha256(f"{profile}\0{identity}".encode()).hexdigest()
        self.path = None if memory else (root or Path.home() / ".aum" / "state") / f"{key}.json"
        self.data = {"version": 1, "views": {}, "toured": False}
        if self.path and self.path.exists():
            try:
                loaded = json.loads(self.path.read_text(encoding="utf-8"))
                if loaded.get("version") == 1 and isinstance(loaded.get("views"), dict):
                    self.data = loaded
            except (OSError, ValueError):
                raise FinOpsError("Cannot read saved views. Back up or repair the AUM state file.", 7) from None

    @property
    def toured(self):
        return self.data.get("toured") is True

    def _save(self):
        if self.path:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            pending = self.path.with_suffix(".new")
            pending.write_text(json.dumps(self.data, indent=2), encoding="utf-8")
            pending.replace(self.path)

    def mark_toured(self):
        self.data["toured"] = True
        self._save()

    def views(self):
        return deepcopy(self.data["views"])

    def save_view(self, name, view):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 _.-]{0,59}", name):
            raise FinOpsError("Use a view name of 1 to 60 letters, numbers, spaces, dots or hyphens.")
        filters = view.get("filters", {})
        if not isinstance(filters, dict) or set(filters) - FILTERS:
            raise FinOpsError("Saved views accept only unit, team, person, model, surface and tier filters.")
        if view.get("month"):
            month_window(view["month"])
        safe = {k: deepcopy(v) for k, v in view.items() if k in {"tab", "month", "filters", "dimension", "interval", "compare"}}
        self.data["views"][name] = safe
        self._save()

    def remove_view(self, name):
        if name not in self.data["views"]:
            raise FinOpsError("Saved view not found.", 5)
        del self.data["views"][name]
        self._save()
