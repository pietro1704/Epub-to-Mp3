"""Bounded, local-only observations for progressive playback journeys."""

from __future__ import annotations

from collections.abc import Callable


class ProgressivePlaybackObservationStore:
    """Keep privacy-safe server boundaries until an explicit diagnostic export."""

    def __init__(self, clock: Callable[[], int], capacity: int = 200) -> None:
        self._clock = clock
        self._capacity = max(1, capacity)
        self._started_at: dict[tuple[str, str], int] = {}
        self._last_elapsed: dict[tuple[str, str], int] = {}
        self._journey_ids_by_job: dict[str, set[str]] = {}
        self._records: list[dict[str, int | str]] = []

    def record(self, job_id: str, journey_id: str, transition: str) -> None:
        key = (job_id, journey_id)
        now = self._clock()
        started_at = self._started_at.setdefault(key, now)
        elapsed = max(0, now - started_at)
        elapsed = max(elapsed, self._last_elapsed.get(key, 0))
        self._last_elapsed[key] = elapsed
        self._journey_ids_by_job.setdefault(job_id, set()).add(journey_id)
        self._records.append(
            {
                "jobId": job_id,
                "journeyId": journey_id,
                "transition": transition,
                "elapsedNanoseconds": elapsed,
            }
        )
        if len(self._records) > self._capacity:
            self._records.pop(0)

    def record_for_job(self, job_id: str, transition: str) -> None:
        for journey_id in sorted(self._journey_ids_by_job.get(job_id, ())):
            self.record(job_id, journey_id, transition)

    def snapshot(self) -> list[dict[str, int | str]]:
        return list(self._records)
