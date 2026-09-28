"""The only execution boundary for backend-derived presentation and reuse."""

from contextlib import contextmanager
from contextvars import ContextVar
from functools import wraps
from dataclasses import dataclass
import inspect
from collections.abc import Callable
from contextlib import AbstractContextManager

from .errors import FinOpsError


@dataclass
class _PublicationScope:
    origin: Callable[[], AbstractContextManager]
    active: bool = True


_publication_scope = ContextVar("aum_publication_scope", default=None)


@dataclass(frozen=True)
class PublicationOrigin:
    guard: Callable[[], AbstractContextManager]
    on_rejected: Callable[[FinOpsError], None]

    def __call__(self):
        return self.guard()


@contextmanager
def guarded_publish(origin, *, on_rejected=None):
    if not callable(origin):
        raise FinOpsError("No originating guard for this data. Refresh before publishing.", 3)
    try:
        with origin():
            scope = _PublicationScope(origin)
            marker = _publication_scope.set(scope)
            try:
                yield
            finally:
                scope.active = False
                _publication_scope.reset(marker)
    except FinOpsError as error:
        if on_rejected is None and isinstance(origin, PublicationOrigin):
            on_rejected = origin.on_rejected
        if on_rejected is not None:
            on_rejected(error)
        raise


def publication_active():
    scope = _publication_scope.get()
    return scope is not None and scope.active


def enclosing_publication():
    if not publication_active():
        raise FinOpsError("Backend data reached an unguarded renderer. Refresh the current view.", 3)
    scope = _publication_scope.get()
    @contextmanager
    def guard():
        if not scope.active:
            raise FinOpsError("Backend data reached an unguarded renderer. Refresh the current view.", 3)
        with scope.origin():
            yield
    return guard


def published(origin, *, rejection=None):
    """Route a synchronous renderer or deferred generator through guarded_publish."""
    def decorate(operation):
        if inspect.iscoroutinefunction(operation) or inspect.isasyncgenfunction(operation):
            raise TypeError("Use guarded_publish around each synchronous write, not an async renderer.")
        if inspect.isgeneratorfunction(operation):
            @wraps(operation)
            def generate(*args, **kwargs):
                failed = rejection(*args, **kwargs) if rejection else None
                source = origin(*args, **kwargs)
                iterator = operation(*args, **kwargs)
                try:
                    while True:
                        with guarded_publish(source, on_rejected=failed):
                            try:
                                item = next(iterator)
                            except StopIteration:
                                return
                        yield item
                finally:
                    iterator.close()
            return generate

        @wraps(operation)
        def execute(*args, **kwargs):
            failed = rejection(*args, **kwargs) if rejection else None
            with guarded_publish(origin(*args, **kwargs), on_rejected=failed):
                return operation(*args, **kwargs)
        return execute
    return decorate
