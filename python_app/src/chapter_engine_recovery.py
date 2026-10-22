# -*- coding: utf-8 -*-
"""Chapter engine recovery."""

from __future__ import annotations


from .conversion_control import ConversionControl as _ConversionControl


async def _chapter_engine_recovery(self, _state):
    if not _state.synthesis_result and _state.is_auto_engine and _state.auto_order:
        if (not _state.slow_engine_triggered) and _state.current_engine_label in {
            "piper",
        }:
            _state.blocked_engines_for_chapter.add("edge")
            _state.forced_auto_engine = _state.current_engine_label
            self._append_runtime_metric(
                {
                    "event": "sticky_offline_after_transcode_failure",
                    "chapter": _state.chapter_num,
                    "engine": _state.current_engine_label,
                },
                output_dir=_state.output_dir,
            )
        if _state.current_engine_label == "edge":
            _state.last_err = str(getattr(_state.tts_engine, "last_error", "") or "")
            if _state._edge_error_reason(_state.last_err) in {"network", "auth"}:
                _state._block_edge_connectivity(_state.last_err)
        _state.preferred_order = [
            name
            for name in (_state.auto_order or [])
            if name not in _state.blocked_engines_for_chapter
        ]
        if not _state.preferred_order:
            # Safety net: if local order is exhausted, rebuild candidates from pool
            # so slow-engine fallback can still switch instead of failing chapter.
            _state.pool_fallback = _state.available_auto_pool()
            _state.preferred_order = [
                name
                for name in self._preferred_auto_engine_order(_state.pool_fallback)
                if name not in _state.blocked_engines_for_chapter
            ]
        _state.next_engine = self._next_auto_engine(_state.preferred_order, _state.attempted_auto)
        if _state.next_engine:
            _state.attempted_auto.add(_state.next_engine)
            _state.forced_auto_engine = _state.next_engine
            _state.engine_tracker["label"] = _state.next_engine
            _state.current_engine_label = _state.next_engine
            if self.verbose:
                print(f"   ⚡ AUTO: switching to {_state.next_engine} and retrying")
            self._append_runtime_metric(
                {
                    "event": "engine_switch",
                    "chapter": _state.chapter_num,
                    "to": _state.next_engine,
                    "blocked": sorted(_state.blocked_engines_for_chapter),
                },
                output_dir=_state.output_dir,
            )
            _state.tts_output_path, _state.needs_mp3_transcode = _state._resolve_tts_output_path(
                _state.output_path, _state.next_engine
            )
            return _ConversionControl("continue")
