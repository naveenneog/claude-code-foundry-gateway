from abc import ABC, abstractmethod
from contextlib import nullcontext
from functools import wraps
from typing import Any


def in_read_cycle(operation):
    @wraps(operation)
    def read(self, *args, **kwargs):
        with self.backend.read_cycle():
            return operation(self, *args, **kwargs)
    return read


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
    identity_independent_reads = frozenset()

    @abstractmethod
    def read(self, resource: str, **params: Any) -> dict:
        raise NotImplementedError

    @abstractmethod
    def write(self, resource: str, body: dict | None = None, **params: Any) -> dict:
        raise NotImplementedError

    def close(self):
        pass

    def read_cycle(self):
        return nullcontext()

    def read_guard(self):
        """Capture the current cycle's validation/serialization boundary for publication."""
        return nullcontext

    def identity_update(self):
        return nullcontext()

    def prepare_read(self, resource):
        """Resolve address metadata needed before an identity-independent read."""

    def invalidate_credentials(self):
        """Discard credentials when the engine verifies a different identity."""

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
