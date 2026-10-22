# -*- coding: utf-8 -*-
"""Chapter-boundary adaptive Edge segment duration policy."""

from __future__ import annotations

from typing import Any, Dict, Optional


class AdaptiveSegmentDurationPolicy:
    """Chapter-boundary controller for opt-in Edge segment duration changes."""

    def __init__(
        self,
        *,
        enabled: bool,
        initial_seconds: float,
        hard_max_seconds: float,
        promote_after: int = 3,
        promotion_step_seconds: float = 35.0,
        demotion_step_seconds: float = 35.0,
    ) -> None:
        from . import edge_engine as _runtime
        self.enabled = bool(enabled)
        self.hard_max_seconds = max(
            30.0,
            min(float(hard_max_seconds or _runtime.SAFE_ADAPTIVE_SEGMENT_SECONDS), _runtime.MAX_EDGE_SEGMENT_SECONDS),
        )
        self.safe_floor_seconds = min(_runtime.SAFE_ADAPTIVE_SEGMENT_SECONDS, self.hard_max_seconds)
        self.target_seconds = max(
            self.safe_floor_seconds,
            min(float(initial_seconds or _runtime.SAFE_ADAPTIVE_SEGMENT_SECONDS), self.hard_max_seconds),
        )
        self.promote_after = max(1, int(promote_after or 1))
        self.promotion_step_seconds = max(1.0, float(promotion_step_seconds or 1.0))
        self.demotion_step_seconds = max(1.0, float(demotion_step_seconds or 1.0))
        self.success_streak = 0

    def observe_chapter(self, *, success: bool, reason: str = "") -> Optional[Dict[str, Any]]:
        """Apply one completed chapter result; callers invoke this only at boundaries."""
        if not self.enabled:
            return None
        if success:
            self.success_streak += 1
            if self.success_streak < self.promote_after:
                return None
            self.success_streak = 0
            new_target = min(
                self.hard_max_seconds,
                self.target_seconds + self.promotion_step_seconds,
            )
            if new_target <= self.target_seconds:
                return None
            self.target_seconds = new_target
            return {
                "event": "edge_segment_policy",
                "action": "promote",
                "target_seconds": float(self.target_seconds),
                "reason": "stable_success_streak",
            }

        self.success_streak = 0
        new_target = max(
            self.safe_floor_seconds,
            self.target_seconds - self.demotion_step_seconds,
        )
        if new_target >= self.target_seconds:
            return None
        self.target_seconds = new_target
        return {
            "event": "edge_segment_policy",
            "action": "demote",
            "target_seconds": float(self.target_seconds),
            "reason": str(reason or "chapter_failure"),
        }

    def snapshot(self) -> Dict[str, Any]:
        """Return serializable policy state for runtime tuning checkpoints."""
        return {
            "enabled": self.enabled,
            "target_seconds": float(self.target_seconds),
            "hard_max_seconds": float(self.hard_max_seconds),
            "success_streak": int(self.success_streak),
        }

    def restore(self, state: Dict[str, Any]) -> None:
        """Restore only bounded policy state; malformed state is ignored."""
        if not self.enabled or not isinstance(state, dict):
            return
        try:
            target = float(state.get("target_seconds", self.target_seconds))
            self.target_seconds = max(
                self.safe_floor_seconds,
                min(target, self.hard_max_seconds),
            )
            self.success_streak = max(0, int(state.get("success_streak", 0) or 0))
        except (TypeError, ValueError):
            return
