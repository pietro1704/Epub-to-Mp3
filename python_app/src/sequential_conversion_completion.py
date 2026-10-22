# -*- coding: utf-8 -*-
"""Sequential conversion completion."""

from __future__ import annotations

from .conversion_control import ConversionControl as _ConversionControl


async def _sequential_conversion_completion(self, _state):
    from . import converter as _runtime
    if (_state.config.engine or "").lower() == "edge" and (
        _state.edge_failure_count > 0 or _state.edge_switched_to_piper
    ):
        print("\n" + "─" * 60)
        print("📊 Edge-TTS Failure Statistics")
        print("─" * 60)
        print(f"   Total failures: {_state.edge_failure_count}")
        print(f"   Final consecutive failures: {_state.edge_consecutive_failures}")
        if _state.edge_switched_to_piper:
            print("   ✅ Successfully switched to Piper fallback")
        elif _state.edge_consecutive_failures >= _runtime.EDGE_FAILURE_THRESHOLD:
            print(
                f"   ⚠️  Reached failure threshold ({_runtime.EDGE_FAILURE_THRESHOLD}) but Piper unavailable"
            )
        print("─" * 60 + "\n")

    self._save_adaptive_state_checkpoint(_state.output_dir)

    return _ConversionControl("return", _runtime.ConversionResult(
        success=_state.success,
        total_chapters=_state.original_total,
        converted_chapters=len(_state.converted_files),
        output_files=_state.converted_files,
        errors=_state.errors,
    ))
