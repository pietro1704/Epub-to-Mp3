"""The public speed API preserves shared identities and the global tuner lifecycle."""

import asyncio
from unittest.mock import Mock

import pytest
from src import speed_monitor as facade
from src.adaptive_edge_tuner import AdaptiveEdgeTuner
from src.speed_sample_monitor import SpeedMonitor
from src.speed_tuning_contracts import SpeedSample, TuningConfig


def test_public_types_and_recorded_samples_share_identity():
    assert facade.SpeedMonitor is SpeedMonitor
    assert facade.AdaptiveEdgeTuner is AdaptiveEdgeTuner
    assert facade.SpeedSample is SpeedSample
    assert facade.TuningConfig is TuningConfig
    monitor = facade.SpeedMonitor(log_callback=lambda _: None)
    config = {"chunk_size": 4000, "concurrency": 8, "max_segment_seconds": 65}
    monitor.record_sample(4000, 2.0, config=config)
    sample = monitor._samples[0]
    assert isinstance(sample, facade.SpeedSample)
    assert sample.config_snapshot is config
    assert sample.chars_per_second == 2000.0
    assert monitor.get_average_speed() == 2000.0


def test_tuner_uses_replaceable_public_monitor_factory(monkeypatch):
    factory = Mock()
    monkeypatch.setattr(facade, "SpeedMonitor", factory)
    callback = Mock()
    facade.AdaptiveEdgeTuner(log_callback=callback, aggressive=True)
    factory.assert_called_once_with(target_speed=220.0, min_speed=80.0, log_callback=callback)


def test_global_tuner_reuse_reset_and_factory_identity(monkeypatch):
    monkeypatch.setattr(facade, "_global_edge_tuner", None)
    factory = Mock(side_effect=[object(), object()])
    monkeypatch.setattr(facade, "AdaptiveEdgeTuner", factory)
    first = facade.get_edge_tuner()
    assert facade.get_edge_tuner() is first
    second = facade.get_edge_tuner(reset=True)
    assert second is not first
    facade.reset_edge_tuner()
    assert facade._global_edge_tuner is None
    assert factory.call_count == 2


def test_failed_segment_reduces_existing_tuner_concurrency():
    tuner = facade.AdaptiveEdgeTuner()
    result = tuner.record_segment(4000, 20.0, success=False)
    assert result == {"chunk_size": 4000, "concurrency": 6, "max_segment_seconds": 65}
    assert tuner._segments_since_last_tune == 0


def test_invalid_sample_is_ignored_and_callback_cancellation_propagates():
    callback = Mock(side_effect=asyncio.CancelledError)
    monitor = facade.SpeedMonitor(log_callback=callback)
    assert monitor.record_sample(0, 1.0) is None
    assert monitor.record_sample(4000, 0.0) is None
    assert not monitor._samples
    with pytest.raises(asyncio.CancelledError):
        monitor.record_sample(4000, 2.0)
