from abc import ABC, abstractmethod
from typing import Any


class Backend(ABC):
    """Bounded reads and explicit writes. The server remains the authorization boundary."""

    name = "unknown"
    immediate_writes = False
    native_modes = False
    requires_reason = False
    person_budget_period = "month"
    budget_warning_threshold = True
    unit_direct_departments = True
    native_user_budget_records = False
    maximum_boost_days = None

    @abstractmethod
    def read(self, resource: str, **params: Any) -> dict:
        raise NotImplementedError

    @abstractmethod
    def write(self, resource: str, body: dict | None = None, **params: Any) -> dict:
        raise NotImplementedError

    def close(self):
        pass

    def people_filter(self, scope_id):
        return {"department_id": scope_id}


def connect(config) -> Backend:
    if config.backend == "fake":
        from .fake import FakeBackend
        return FakeBackend()
    if config.backend == "direct":
        from .direct import DirectBackend
        return DirectBackend(config)
    if config.backend == "aum-service":
        from .aum_service import AumServiceBackend
        return AumServiceBackend(config)
    from .turnstile import TurnstileBackend
    return TurnstileBackend(config)
