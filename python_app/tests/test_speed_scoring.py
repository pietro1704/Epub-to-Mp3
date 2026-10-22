"""Exercise score extraction through the original controller facade."""

from collections import deque
from unittest.mock import patch

import pytest

from python_app.src import speed_controller as speed


def _sample(*, success=True, error=None):
    return speed.ChapterPerf(1, "chapter", 3000, 30.0, success, error)


def test_scoring_keeps_history_identity_and_samples_unchanged():
    controller = speed.AdaptiveSpeedController()
    history = deque([_sample() for _ in range(4)], maxlen=6)
    controller._history["edge"] = history
    samples = list(history)
    score, reason = controller._calculate_engine_score("edge")
    assert score == pytest.approx(44.0)
    assert reason == "100 chars/s, 100% success"
    assert controller._history["edge"] is history
    assert list(history) == samples
    assert all(actual is original for actual, original in zip(history, samples))


def test_facade_classifier_remains_replaceable_for_cancellation():
    controller = speed.AdaptiveSpeedController()
    controller._history["edge"].append(_sample(success=False, error="custom cancellation"))
    with patch.object(speed, "classify_error", return_value="cancelled") as classify:
        assert controller._calculate_engine_score("edge") == (50.0, "only user cancellations")
    classify.assert_called_once_with("custom cancellation")


def test_connectivity_failure_uses_facade_clock_and_expires():
    controller = speed.AdaptiveSpeedController()
    controller._history["edge"].extend([_sample() for _ in range(4)])
    with patch.object(speed.time, "time", return_value=1000.0):
        controller.record_connectivity_failure("edge")
        penalized, reason = controller._calculate_engine_score("edge")
    assert penalized == pytest.approx(19.0)
    assert "connectivity penalty x1" in reason
    with patch.object(speed.time, "time", return_value=1901.0):
        restored, reason = controller._calculate_engine_score("edge")
    assert restored == pytest.approx(44.0)
    assert "connectivity penalty" not in reason
