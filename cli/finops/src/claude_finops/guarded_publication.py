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


@dataclass(frozen=True)
class _EnclosingOrigin:
    scope: _PublicationScope

    @contextmanager
    def __call__(self):
        if not self.scope.active:
            raise FinOpsError("Backend data reached an unguarded renderer. Refresh the current view.", 3)
        with self.scope.origin():
            yield


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
    return _EnclosingOrigin(_publication_scope.get())


def publication_origin():
    """Retain provenance, not permission to write outside the active scope."""
    source = enclosing_publication()
    while isinstance(source, _EnclosingOrigin):
        source = source.scope.origin
    return source


def publication_sink(operation):
    """Enforce the active, current origin at the actual synchronous write."""
    if (inspect.iscoroutinefunction(operation) or inspect.isgeneratorfunction(operation)
            or inspect.isasyncgenfunction(operation)):
        raise TypeError("Publication sinks must perform synchronous writes, not create deferred bodies.")

    @wraps(operation)
    def write(*args, **kwargs):
        try:
            with guarded_publish(enclosing_publication()):
                return operation(*args, **kwargs)
        except FinOpsError as error:
            owner = args[0] if args else None
            rejected = getattr(owner, "_publication_rejected", None)
            if rejected is not None:
                rejected(error)
            raise
    return write


def guarded_deferred(origin, operation):
    """Re-enter a retained origin when scheduled work actually runs."""
    if inspect.iscoroutinefunction(operation):
        @wraps(operation)
        async def run_async(*args, **kwargs):
            with guarded_publish(origin):
                pass
            # Awaiting work owns a lifetime, not an identity lock. Each sink
            # reacquires the origin lock and checks it at the synchronous write.
            scope = _PublicationScope(origin)
            marker = _publication_scope.set(scope)
            try:
                return await operation(*args, **kwargs)
            except FinOpsError as error:
                if isinstance(origin, PublicationOrigin):
                    origin.on_rejected(error)
                raise
            finally:
                scope.active = False
                _publication_scope.reset(marker)
        return run_async

    @wraps(operation)
    def run(*args, **kwargs):
        with guarded_publish(origin):
            return operation(*args, **kwargs)
    return run


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
