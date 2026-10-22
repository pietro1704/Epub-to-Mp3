# -*- coding: utf-8 -*-
"""Chapter synthesis telemetry."""

from __future__ import annotations


async def _chapter_synthesis_telemetry(self, _state):
    self._append_runtime_metric(
        {
            "event": "pipeline_stage_done",
            "stage": "synthesize",
            "chapter": _state.chapter_num,
            "engine": _state.engine_tracker.get("label")
            or (_state.config.engine or "").lower(),
        },
        output_dir=_state.output_dir,
    )
    _state.file_size = _state.output_path.stat().st_size

    # Validar que o file tem tamanho minimum (not is empty/corrupted)
