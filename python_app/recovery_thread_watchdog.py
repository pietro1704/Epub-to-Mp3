"""Thread liveness inspection and staged recovery policy for the legacy monitor."""

from dataclasses import dataclass
from typing import List


@dataclass
class ThreadActivity:
    """Atividade de uma thread."""

    thread_id: int
    name: str
    alive: bool
    daemon: bool
    last_cpu_time: float
    last_check_time: float
    stack_frames: List[str]
    stuck_count: int = 0
    recoveries: int = 0



def is_idle_worker_thread(stack_frames: List[str]) -> bool:
    """Check if thread is idle waiting for work (normal behaviour)."""
    if not stack_frames:
        return False

    stack_text = "\n".join(stack_frames)

    # Idle thread patterns (expected behaviour)
    idle_patterns = [
        "work_queue.get(block=True)",  # ThreadPoolExecutor esperando trabalho
        "self.work_queue.get(block=True)",
        "_worker\n    work_item = work_queue.get(block=True)",
        "Queue.get",  # asyncio Queue esperando
        "Condition.wait",  # Waiting on condition variable
        "time.sleep(",  # Sleep loops (monitoring threads)
        "_stop_event.wait(",  # Event wait
        "waiter.acquire(",  # Lock/Event acquisition
        "Event.wait",  # Threading event wait
        "self.interval)",  # Sleep com self.interval
    ]

    return any(pattern in stack_text for pattern in idle_patterns)


def is_event_loop_stack(stack_frames: List[str]) -> bool:
    """Detecta stack de event loop/servidor (comportamento normal)."""
    if not stack_frames:
        return False
    stack_text = "\n".join(stack_frames)
    event_loop_markers = [
        "asyncio/base_events.py",
        "asyncio/runners.py",
        "uvicorn/server.py",
        "uvicorn/_subprocess.py",
        "starlette/routing.py",
    ]
    if any(marker in stack_text for marker in event_loop_markers):
        # Loop threads can stay stable for a long time without being stuck.
        return True
    return False


def check_deadlocks(
    current_threads, current_time, cpu_times, activities, ignored_prefixes, thresholds,
    *, current_frames, format_stack, idle_check, event_loop_check, recover_thread,
):
    """Update tracked identities and recover stable, inactive, non-idle threads."""
    for thread in current_threads:
        if not thread.is_alive():
            continue

        if ignored_prefixes:
            name_lower = thread.name.lower()
            if any(name_lower.startswith(prefix) for prefix in ignored_prefixes):
                continue

        thread_id = thread.ident
        if thread_id is None:
            continue

        if thread.name == "AutoRecovery":
            continue

        # Capturar stack frames da thread
        frame = current_frames().get(thread_id)
        stack_frames = []
        if frame:
            stack_frames = format_stack(frame)

        # **NOVO**: Ignorar threads idle esperando por trabalho (comportamento normal)
        if idle_check(stack_frames) or event_loop_check(stack_frames):
            # Reset contador se estava travada antes
            if thread_id in activities:
                activities[thread_id].stuck_count = 0
            continue

        # Check if thread is stuck in the same place
        if thread_id in activities:
            prev_activity = activities[thread_id]
            current_cpu = cpu_times.get(thread_id, prev_activity.last_cpu_time)
            cpu_unchanged = abs(current_cpu - prev_activity.last_cpu_time) < 0.0001

            # Comparar stack frames
            if stack_frames == prev_activity.stack_frames and cpu_unchanged:
                prev_activity.stuck_count += 1

                # Thread travada por muito tempo?
                if prev_activity.stuck_count >= thresholds["thread_stuck_cycles"]:
                    recover_thread(thread, prev_activity)
            else:
                prev_activity.stuck_count = 0
                prev_activity.stack_frames = stack_frames
                prev_activity.last_check_time = current_time
            prev_activity.last_cpu_time = current_cpu
        else:
            # Nova thread
            current_cpu = cpu_times.get(thread_id, 0.0)
            activities[thread_id] = ThreadActivity(
                thread_id=thread_id,
                name=thread.name,
                alive=thread.is_alive(),
                daemon=thread.daemon,
                last_cpu_time=current_cpu,
                last_check_time=current_time,
                stack_frames=stack_frames,
                stuck_count=0,
            )


def recover_stuck_thread(
    thread, activity, thresholds, *, collect_garbage, boost_priority,
    interrupt_thread, request_restart, log_action,
):
    """Apply the existing staged recovery while process effects stay injectable."""
    print(f"🚨 [AutoRecovery] Thread travada detectada: {thread.name}")
    print("   Stack trace:")
    for line in activity.stack_frames[-5:]:  # Last 5 lines
        print(f"   {line.strip()}")

    # Recovery actions
    action_taken = "none"
    success = False
    interrupted = False

    # 1. Try forcing GC (may release locks)
    print("   → Trying forced GC...")
    collect_garbage()
    action_taken = "gc_collect"
    success = True

    # 2. Boost process priority to avoid CPU starvation
    boost_priority()

    # 3. Inject exception into thread to release locks
    interrupted = interrupt_thread(activity.thread_id)
    if interrupted:
        action_taken = "interrupt_thread"
        success = True
        print(f"   ✅ Interrupt requested for thread {thread.name}")
    else:
        print(f"   ⚠️ Could not interrupt thread {thread.name}")

    # 2. If thread is not a daemon and is stuck, alert
    if not thread.daemon:
        activity.recoveries += 1
        print(f"   ⚠️ Non-daemon thread stuck: {thread.name}")
        threshold = thresholds.get("thread_hard_restart_cycles", 2)
        if activity.recoveries >= threshold:
            print("   ⏱️ Recovery failed more than once — requesting soft restart")
            request_restart(
                reason="thread_deadlock",
                thread_name=thread.name,
                thread_id=activity.thread_id,
            )
        else:
            print("   → Automatic retry soon")

    # Record action
    log_action(
        problem="thread_deadlock",
        action=action_taken,
        success=success,
        details={
            "thread_name": thread.name,
            "thread_id": activity.thread_id,
            "stuck_cycles": activity.stuck_count,
            "stack_sample": activity.stack_frames[-1] if activity.stack_frames else None,
            "recoveries": activity.recoveries,
            "interrupted": interrupted,
        },
    )

    # Reset counter
    activity.stuck_count = 0
