"""Thread recovery policy tests with all process/thread effects replaced."""

import io
from contextlib import redirect_stdout
from types import SimpleNamespace
from unittest.mock import Mock, patch

import pytest

from python_app import auto_recovery as recovery
from python_app.recovery_thread_watchdog import ThreadActivity


def _monitor():
    with patch.object(recovery.psutil, "Process", return_value=Mock()):
        monitor = recovery.AutoRecoverySystem()
    monitor._boost_process_priority = Mock()
    monitor._interrupt_thread = Mock(return_value=True)
    monitor._request_process_restart = Mock()
    monitor.thresholds["thread_stuck_cycles"] = 2
    return monitor


def _thread(name="worker", ident=17, daemon=True):
    return SimpleNamespace(name=name, ident=ident, daemon=daemon, is_alive=lambda: True)


def _scan(monitor, thread, stack, cpu=0.0):
    with (
        patch.object(recovery.threading, "enumerate", return_value=[thread]),
        patch.object(monitor, "_get_thread_cpu_times", return_value={thread.ident: cpu}),
        patch.object(recovery.sys, "_current_frames", return_value={thread.ident: object()}),
        patch.object(recovery.traceback, "format_stack", return_value=stack),
        patch.object(recovery.gc, "collect"),
        redirect_stdout(io.StringIO()),
    ):
        monitor._check_deadlocks()


def test_stable_thread_identity_reaches_recovery_threshold():
    monitor = _monitor()
    thread = _thread()
    _scan(monitor, thread, ["blocked"])
    activity = monitor._thread_activities[17]
    assert recovery.ThreadActivity is ThreadActivity
    assert isinstance(activity, recovery.ThreadActivity)
    _scan(monitor, thread, ["blocked"])
    assert activity.stuck_count == 1
    _scan(monitor, thread, ["blocked"])
    assert monitor._thread_activities[17] is activity
    assert activity.stuck_count == 0
    monitor._interrupt_thread.assert_called_once_with(17)
    monitor._request_process_restart.assert_not_called()
    assert monitor.get_recent_actions()[0].action == "interrupt_thread"


@pytest.mark.parametrize("stack", [["Condition.wait"], ["asyncio/base_events.py"]])
def test_idle_and_event_loop_threads_reset_stuck_state(stack):
    monitor = _monitor()
    thread = _thread()
    _scan(monitor, thread, ["blocked"])
    activity = monitor._thread_activities[17]
    activity.stuck_count = 2
    _scan(monitor, thread, stack)
    assert activity.stuck_count == 0
    monitor._interrupt_thread.assert_not_called()


def test_changed_cpu_usage_resets_stuck_state():
    monitor = _monitor()
    thread = _thread()
    _scan(monitor, thread, ["blocked"])
    activity = monitor._thread_activities[17]
    activity.stuck_count = 1
    _scan(monitor, thread, ["blocked"], cpu=1.0)
    assert activity.stuck_count == 0
    assert activity.last_cpu_time == 1.0
    monitor._interrupt_thread.assert_not_called()


def test_failed_interrupt_preserves_existing_gc_recovery_and_restart_policy():
    monitor = _monitor()
    thread = _thread(daemon=False)
    monitor._interrupt_thread.return_value = False
    _scan(monitor, thread, ["blocked"])
    activity = monitor._thread_activities[17]
    with patch.object(recovery.gc, "collect"), redirect_stdout(io.StringIO()):
        monitor._recover_stuck_thread(thread, activity)
        monitor._recover_stuck_thread(thread, activity)
    assert activity.recoveries == 2
    monitor._request_process_restart.assert_called_once_with(
        reason="thread_deadlock", thread_name="worker", thread_id=17
    )
    actions = monitor.get_recent_actions()
    assert all(action.action == "gc_collect" for action in actions)
    assert all(action.details["interrupted"] is False for action in actions)


def test_recovery_cancellation_propagates_before_process_actions():
    monitor = _monitor()
    thread = _thread()
    _scan(monitor, thread, ["blocked"])
    with (
        patch.object(recovery.gc, "collect", side_effect=KeyboardInterrupt),
        redirect_stdout(io.StringIO()),
        pytest.raises(KeyboardInterrupt),
    ):
        monitor._recover_stuck_thread(thread, monitor._thread_activities[17])
    monitor._boost_process_priority.assert_not_called()
    monitor._interrupt_thread.assert_not_called()
    monitor._request_process_restart.assert_not_called()
    assert monitor.get_recent_actions() == []
