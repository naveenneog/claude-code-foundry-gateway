import asyncio
from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext

import pytest

from claude_finops.errors import FinOpsError
from claude_finops.guarded_publication import guarded_publish, published, enclosing_publication
from test_publication_generation import http_estate, verify_b


def test_async_renderer_cannot_pretend_its_later_writes_are_guarded():
    async def unsafe():
        await asyncio.sleep(0)
        return "private"

    with pytest.raises(TypeError, match="synchronous"):
        published(lambda: nullcontext)(unsafe)


def test_deferred_child_cannot_inherit_an_expired_publication_scope():
    from contextvars import copy_context
    with guarded_publish(nullcontext):
        inherited = copy_context()
    with pytest.raises(FinOpsError, match="unguarded"):
        inherited.run(enclosing_publication)


def test_generator_rechecks_origin_without_holding_identity_lock_between_items(http_estate):
    engine, principal, _ = http_estate
    with engine.backend.read_cycle():
        source = engine.read("trends")
        origin = engine.backend.read_guard()

    @published(lambda: origin)
    def rows():
        yield source["source"]
        yield source["source"]

    iterator = rows()
    try:
        assert next(iterator) == "a-only"

        def can_verify():
            acquired = engine.backend._credential_lock.acquire(timeout=.1)
            if acquired:
                engine.backend._credential_lock.release()
            return acquired

        with ThreadPoolExecutor(max_workers=1) as pool:
            assert pool.submit(can_verify).result(timeout=2), "Publication must not hold a lock while its consumer is suspended."
        verify_b(engine, principal)
        with pytest.raises(FinOpsError, match="sign-in changed"):
            next(iterator)
    finally:
        iterator.close()
