from abc import ABC, abstractmethod
from typing import Any


class Backend(ABC):
    """Bounded reads and explicit writes. The server remains the authorization boundary."""

    name = "unknown"

    @abstractmethod
    def read(self, resource: str, **params: Any) -> dict:
        raise NotImplementedError

    @abstractmethod
    def write(self, resource: str, body: dict | None = None, **params: Any) -> dict:
        raise NotImplementedError

    def close(self):
        pass


def connect(config) -> Backend:
    if config.backend == "fake":
        from .fake import FakeBackend
        return FakeBackend()
    if config.backend == "direct":
        from .direct import DirectBackend
        return DirectBackend(config)
    from .turnstile import TurnstileBackend
    return TurnstileBackend(config)
