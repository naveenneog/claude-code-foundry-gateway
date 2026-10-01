from __future__ import annotations

import importlib
import pkgutil
import sys
import builtins
import datetime as _datetime_module
import types
from datetime import datetime as _stdlib_datetime

import pytest

import claude_finops
from aum_clock import PinnedDateTime


def pytest_configure(config):
    config.addinivalue_line("markers", "real_clock: opt out of the AUM pinned UTC clock")


@pytest.fixture(scope="session")
def aum_finops_modules():
    modules = []
    failures = []
    for info in pkgutil.walk_packages(claude_finops.__path__, claude_finops.__name__ + "."):
        try:
            modules.append(importlib.import_module(info.name))
        except Exception as error:
            failures.append(f"{info.name}: {error!r}")
    if failures:
        raise AssertionError("Failed to import claude_finops modules: " + "; ".join(failures))
    return tuple(modules)


@pytest.fixture(autouse=True)
def _pin_aum_clock(request, aum_finops_modules):
    if request.node.get_closest_marker("real_clock"):
        yield
        return

    patch = pytest.MonkeyPatch()
    original_import = builtins.__import__
    datetime_proxy = types.SimpleNamespace(**{
        name: getattr(_datetime_module, name) for name in dir(_datetime_module)
    })
    datetime_proxy.datetime = PinnedDateTime

    def scoped_import(name, globals=None, locals=None, fromlist=(), level=0):
        caller = (globals or {}).get("__name__", "")
        if (name == "datetime" and "datetime" in (fromlist or ())
                and (caller.startswith("claude_finops") or caller.startswith("test_") or caller == "p85_fixtures")):
            return datetime_proxy
        return original_import(name, globals, locals, fromlist, level)

    patch.setattr(builtins, "__import__", scoped_import)
    for module in aum_finops_modules:
        if getattr(module, "datetime", None) is _stdlib_datetime:
            patch.setattr(module, "datetime", PinnedDateTime)

    for name, module in list(sys.modules.items()):
        if module and (name.startswith("test_") or name == "p85_fixtures"):
            if getattr(module, "datetime", None) is _stdlib_datetime:
                patch.setattr(module, "datetime", PinnedDateTime)
    try:
        yield
    finally:
        patch.undo()
