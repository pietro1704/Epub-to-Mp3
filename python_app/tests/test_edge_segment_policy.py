"""Tests for the opt-in adaptive Edge segment-duration policy."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.tts.edge_engine import AdaptiveSegmentDurationPolicy, EdgeTTSEngine


def test_policy_is_disabled_by_default_and_keeps_safe_target():
    policy = AdaptiveSegmentDurationPolicy(enabled=False, initial_seconds=85, hard_max_seconds=180)

    assert policy.target_seconds == 85.0
    assert policy.observe_chapter(success=True) is None
    assert policy.target_seconds == 85.0


def test_stable_chapters_promote_only_after_success_streak():
    policy = AdaptiveSegmentDurationPolicy(
        enabled=True,
        initial_seconds=85,
        hard_max_seconds=180,
        promote_after=2,
        promotion_step_seconds=35,
    )

    assert policy.observe_chapter(success=True) is None
    promotion = policy.observe_chapter(success=True)

    assert promotion == {
        "event": "edge_segment_policy",
        "action": "promote",
        "target_seconds": 120.0,
        "reason": "stable_success_streak",
    }
    assert policy.target_seconds == 120.0


def test_failure_demotes_target_at_boundary_without_losing_state():
    policy = AdaptiveSegmentDurationPolicy(
        enabled=True,
        initial_seconds=120,
        hard_max_seconds=180,
        demotion_step_seconds=35,
    )

    event = policy.observe_chapter(success=False, reason="timeout")

    assert event == {
        "event": "edge_segment_policy",
        "action": "demote",
        "target_seconds": 85.0,
        "reason": "timeout",
    }
    assert policy.target_seconds == 85.0


def test_policy_never_exceeds_hard_maximum_or_safe_floor():
    policy = AdaptiveSegmentDurationPolicy(
        enabled=True,
        initial_seconds=85,
        hard_max_seconds=130,
        promote_after=1,
        promotion_step_seconds=100,
        demotion_step_seconds=100,
    )

    assert policy.observe_chapter(success=True)["target_seconds"] == 130.0
    assert policy.observe_chapter(success=False, reason="no_audio")["target_seconds"] == 85.0


def test_configured_hard_maximum_can_lower_the_adaptive_floor():
    policy = AdaptiveSegmentDurationPolicy(
        enabled=True,
        initial_seconds=75,
        hard_max_seconds=75,
        promote_after=1,
    )

    assert policy.target_seconds == 75.0
    assert policy.observe_chapter(success=False, reason="timeout") is None
    assert policy.target_seconds == 75.0


def test_engine_applies_policy_only_at_next_chapter_boundary():
    engine = EdgeTTSEngine(
        "test-voice",
        enable_parallel=False,
        max_segment_seconds=85,
        adaptive_segment_seconds=True,
        adaptive_segment_max_seconds=120,
    )

    assert engine._active_segment_seconds() == 85.0
    engine._pending_segment_policy_result = (True, "")
    engine._apply_pending_segment_policy()
    assert engine._active_segment_seconds() == 85.0

    engine._pending_segment_policy_result = (True, "")
    engine._apply_pending_segment_policy()
    engine._pending_segment_policy_result = (True, "")
    engine._apply_pending_segment_policy()
    assert engine._active_segment_seconds() == 120.0

    state = engine.get_segment_policy_state()
    restored = EdgeTTSEngine(
        "test-voice",
        enable_parallel=False,
        max_segment_seconds=85,
        adaptive_segment_seconds=True,
        adaptive_segment_max_seconds=120,
    )
    restored.restore_segment_policy_state(state)
    assert restored._active_segment_seconds() == 120.0
