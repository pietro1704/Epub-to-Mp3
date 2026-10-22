"""Rank engine samples using speed, reliability, size and connectivity evidence."""

from collections import deque


def calculate_engine_score(
    engine, history_by_engine, connectivity_by_engine, chapter_chars,
    *, size_bucket, classify_error, clock,
):
    """
    Calculate performance score for an engine.

    Score components:
    - Speed (chars/second): Higher is better
    - Reliability: Multiplicative quadratic-ish penalty on failure rate.
      User-cancelled chapters are excluded (not an engine fault).
    - Consistency: Lower variance is better
    - Recency: Recent performance weighted more

    Returns:
        (score, reason) tuple
    """
    history = history_by_engine.get(engine, deque())

    if not history:
        return (50.0, "no history")

    # Wider window (5) so a single transient failure doesn't dominate.
    full_recent = list(history)[-5:]
    if not full_recent:
        return (50.0, "no recent data")

    bucket_note = ""
    recent_items = full_recent
    if chapter_chars and chapter_chars > 0:
        target_bucket = size_bucket(int(chapter_chars))
        bucket_items = [
            item for item in full_recent if size_bucket(item.chars) == target_bucket
        ]
        # Only use bucket-restricted view if it has enough signal (>= 2
        # samples). Otherwise a single lucky success in that bucket would
        # dominate the score.
        if len(bucket_items) >= 2:
            recent_items = bucket_items
            bucket_note = f", {target_bucket} bucket"

    scorable = [
        item for item in recent_items if classify_error(item.error or "") != "cancelled"
    ]
    if not scorable:
        return (50.0, "only user cancellations")

    speeds = [
        item.chars / item.elapsed for item in scorable if item.success and item.elapsed > 0
    ]

    if not speeds:
        return (10.0, "all recent failures")

    avg_speed = sum(speeds) / len(speeds)

    successes = sum(1 for item in scorable if item.success)
    success_rate = successes / len(scorable)
    failure_rate = 1.0 - success_rate

    if len(speeds) >= 2:
        mean = sum(speeds) / len(speeds)
        variance = sum((x - mean) ** 2 for x in speeds) / len(speeds)
        std_dev = variance**0.5
        consistency = 1.0 / (1.0 + std_dev / mean)
    else:
        consistency = 0.5

    speed_score = min(avg_speed / 5, 100)
    consistency_score = consistency * 100

    # Multiplicative reliability: a slower-but-reliable engine should beat
    # a fast-but-flaky one in auto-mode ranking. Power 1.5 keeps the
    # penalty meaningful without zeroing out after a single failure.
    reliability_factor = max(0.25, (1.0 - failure_rate) ** 1.5)

    raw_score = speed_score * 0.7 + consistency_score * 0.3
    final_score = raw_score * reliability_factor

    now = clock()
    window_seconds = 15 * 60
    failures = connectivity_by_engine.get(engine, deque())
    recent = [ts for ts in failures if (now - ts) <= window_seconds]
    if recent:
        penalty = min(70.0, 25.0 * len(recent))
        final_score = max(0.0, final_score - penalty)
        reason = (
            f"{int(avg_speed)} chars/s, {int(success_rate * 100)}% success{bucket_note}, "
            f"connectivity penalty x{len(recent)}"
        )
        return (final_score, reason)

    reason = f"{int(avg_speed)} chars/s, {int(success_rate * 100)}% success{bucket_note}"
    return (final_score, reason)
