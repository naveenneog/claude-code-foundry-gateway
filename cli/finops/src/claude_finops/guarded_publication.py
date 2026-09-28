"""The only execution boundary for backend-derived presentation and reuse."""

from contextlib import contextmanager
from contextvars import ContextVar
from functools import wraps
import inspect

from .errors import FinOpsError


_publication_depth = ContextVar("aum_publication_depth", default=0)


@contextmanager
def guarded_publish(origin, *, on_rejected=None):
    if not callable(origin):
        raise FinOpsError("No originating guard for this data. Refresh before publishing.", 3)
    try:
        with origin():
            marker = _publication_depth.set(_publication_depth.get() + 1)
            try:
                yield
            finally:
                _publication_depth.reset(marker)
    except FinOpsError as error:
        if on_rejected is not None:
            on_rejected(error)
        raise


def publication_active():
    return _publication_depth.get() > 0


def enclosing_publication():
    if not publication_active():
        raise FinOpsError("Backend data reached an unguarded renderer. Refresh the current view.", 3)
    return _enclosing_guard


@contextmanager
def _enclosing_guard():
    if not publication_active():
        raise FinOpsError("Backend data reached an unguarded renderer. Refresh the current view.", 3)
    yield


def published(origin, *, rejection=None):
    """Route a synchronous renderer or deferred generator through guarded_publish."""
    def decorate(operation):
        if inspect.isgeneratorfunction(operation):
            @wraps(operation)
            def generate(*args, **kwargs):
                failed = rejection(*args, **kwargs) if rejection else None
                with guarded_publish(origin(*args, **kwargs), on_rejected=failed):
                    yield from operation(*args, **kwargs)
            return generate

        @wraps(operation)
        def execute(*args, **kwargs):
            failed = rejection(*args, **kwargs) if rejection else None
            with guarded_publish(origin(*args, **kwargs), on_rejected=failed):
                return operation(*args, **kwargs)
        return execute
    return decorate
