"""Regression: ``python_app.src.tts`` must lazy-load ``TTSFactory``.

The iOS embed cannot ``dlopen`` the ``_struct`` C extension outside a
``.framework`` bundle. Importing ``factory.py`` cascades to
``urllib.request`` -> ``base64`` -> ``struct`` -> ``_struct`` and
crashes every chapter synthesis with::

    No module named '_struct'

We side-step this by exposing ``TTSFactory`` through a PEP 562
``__getattr__`` so submodule imports (notably ``_edge_transport`` and
``_piper_transport``, used by ``ios_entrypoints``) do not eagerly pull
in ``factory``.

This test pins three invariants:

1. Importing the package does NOT import ``factory``.
2. Importing the transports does NOT import ``factory``.
3. ``TTSFactory`` is still reachable lazily via attribute access — the
   CLI and server callers (``_retry_mixin``, ``_validation_mixin``,
   ``_edge_throttle_mixin``) must keep working.
"""

from __future__ import annotations

import importlib
import sys


def _purge_tts_modules() -> None:
    for name in list(sys.modules):
        if name == "python_app.src.tts" or name.startswith("python_app.src.tts."):
            del sys.modules[name]


def test_package_import_does_not_pull_factory() -> None:
    _purge_tts_modules()
    pkg = importlib.import_module("python_app.src.tts")
    assert pkg is not None
    assert "python_app.src.tts.factory" not in sys.modules, (
        "Importing python_app.src.tts must not eagerly load "
        "factory.py — that import cascades to urllib.request / "
        "_struct, which crashes the iOS embed."
    )


def test_transport_imports_do_not_pull_factory() -> None:
    _purge_tts_modules()
    edge = importlib.import_module("python_app.src.tts._edge_transport")
    piper = importlib.import_module("python_app.src.tts._piper_transport")
    assert edge is not None and piper is not None
    assert "python_app.src.tts.factory" not in sys.modules, (
        "Importing _edge_transport / _piper_transport must not "
        "transitively load factory.py via the package __init__ — "
        "this is the regression that crashed the iOS chapter "
        "synthesis with `No module named '_struct'`."
    )


def test_factory_still_resolves_via_lazy_attribute() -> None:
    _purge_tts_modules()
    from python_app.src.tts import TTSFactory  # noqa: F401

    # Touching the attribute is the trigger.
    assert "python_app.src.tts.factory" in sys.modules, (
        "Accessing TTSFactory must trigger the lazy import — the CLI "
        "and server callers rely on this name."
    )


def test_ios_entrypoints_imports_without_urllib_request() -> None:
    """ios_entrypoints must import on a system that pretends `_struct`
    is missing. We can't actually unload `_struct` mid-process, but we
    can assert the import doesn't reach `urllib.request`."""
    _purge_tts_modules()
    sys.modules.pop("urllib.request", None)
    sys.modules.pop("python_app.src.ios_entrypoints", None)
    importlib.import_module("python_app.src.ios_entrypoints")
    assert "urllib.request" not in sys.modules, (
        "ios_entrypoints must not transitively import urllib.request "
        "— that's the chain that breaks under the iOS embed."
    )
