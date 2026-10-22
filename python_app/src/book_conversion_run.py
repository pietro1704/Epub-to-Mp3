# -*- coding: utf-8 -*-
"""Coordinate book conversion phases and original control flow."""

from __future__ import annotations

from .book_conversion_completion import _book_conversion_completion
from .book_conversion_dispatch import _book_conversion_dispatch
from .book_conversion_preparation import _book_conversion_preparation
from .book_engine_preparation import _book_engine_preparation
from .book_failure_recovery import _book_failure_recovery


async def _book_conversion_run(self, _state):
    _phase_flow = await _book_conversion_preparation(self, _state)
    if _phase_flow is not None:
        return _phase_flow
    _phase_flow = await _book_engine_preparation(self, _state)
    if _phase_flow is not None:
        return _phase_flow
    _phase_flow = await _book_conversion_dispatch(self, _state)
    if _phase_flow is not None:
        return _phase_flow
    _phase_flow = await _book_failure_recovery(self, _state)
    if _phase_flow is not None:
        return _phase_flow
    _phase_flow = await _book_conversion_completion(self, _state)
    if _phase_flow is not None:
        return _phase_flow
