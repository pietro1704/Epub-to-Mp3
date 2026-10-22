# -*- coding: utf-8 -*-
"""Coordinate sequential conversion phases and original control flow."""

from __future__ import annotations


from .sequential_session_preparation import _sequential_session_preparation
from .sequential_chapter_pipeline import _sequential_chapter_pipeline
from .sequential_conversion_completion import _sequential_conversion_completion

async def _sequential_conversion_run(self, _state):
    _phase_flow = await _sequential_session_preparation(self, _state)
    if _phase_flow is not None:
        return _phase_flow
    _phase_flow = await _sequential_chapter_pipeline(self, _state)
    if _phase_flow is not None:
        return _phase_flow
    _phase_flow = await _sequential_conversion_completion(self, _state)
    if _phase_flow is not None:
        return _phase_flow
