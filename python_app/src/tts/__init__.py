# -*- coding: utf-8 -*-
"""TTS Engine module exports.

`TTSFactory` is exposed lazily via ``__getattr__`` (PEP 562) so
``from python_app.src.tts import _edge_transport`` does NOT eagerly
import ``factory.py``. The factory pulls in ``urllib.request`` ->
``base64`` -> ``struct`` -> ``_struct``, and the iOS embed cannot
``dlopen`` the ``_struct`` C extension outside a ``.framework`` bundle.
Without this laziness every iOS chapter synthesis crashed with::

    No module named '_struct'

…before reaching the transport seam.  The CLI / server still get the
same surface — `TTSFactory` resolves on first access (which is always
on macOS/Linux, where ``_struct`` is registered as a built-in).
"""

from .base import TTSEngine

__all__ = [
    "TTSEngine",
    "TTSFactory",
]


def __getattr__(name):  # pragma: no cover - exercised by integration
    if name == "TTSFactory":
        from .factory import TTSFactory as _TTSFactory

        return _TTSFactory
    raise AttributeError(f"module 'python_app.src.tts' has no attribute {name!r}")
