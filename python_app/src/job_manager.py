# -*- coding: utf-8 -*-
"""Job manager for persisting conversion job state across server restarts."""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Dict, Optional, List
from datetime import datetime, timedelta

logger = logging.getLogger(__name__)


class JobManager:
    """Manage conversion job persistence to disk."""

    def __init__(self, jobs_dir: Path):
        """
        Initialize job manager.

        Args:
            jobs_dir: Directory to store job state files
        """
        self.jobs_dir = Path(jobs_dir)
        self.jobs_dir.mkdir(exist_ok=True, parents=True)
        self._memory_cache: Dict[str, dict] = {}

    def _get_job_file(self, job_id: str) -> Path:
        """Get path to job state file."""
        return self.jobs_dir / f"{job_id}.json"

    def save_job(self, job_id: str, job_data: dict) -> bool:
        """
        Save job state to disk.

        Args:
            job_id: Job ID
            job_data: Job data dictionary

        Returns:
            True if successful, False otherwise
        """
        try:
            job_file = self._get_job_file(job_id)

            # Add timestamp for cleanup purposes
            job_data_with_meta = {
                **job_data,
                "_saved_at": datetime.utcnow().isoformat(),
            }

            with open(job_file, 'w', encoding='utf-8') as f:
                json.dump(job_data_with_meta, f, ensure_ascii=False, indent=2)

            # Update memory cache
            self._memory_cache[job_id] = job_data

            return True
        except Exception as e:
            logger.error(f"Failed to save job {job_id}: {e}", exc_info=True)
            return False

    def load_job(self, job_id: str) -> Optional[dict]:
        """
        Load job state from disk.

        Args:
            job_id: Job ID

        Returns:
            Job data dictionary or None if not found
        """
        # Check memory cache first
        if job_id in self._memory_cache:
            return self._memory_cache[job_id]

        try:
            job_file = self._get_job_file(job_id)

            if not job_file.exists():
                return None

            with open(job_file, 'r', encoding='utf-8') as f:
                job_data = json.load(f)

            # Remove metadata
            job_data.pop("_saved_at", None)

            # Update memory cache
            self._memory_cache[job_id] = job_data

            return job_data
        except Exception as e:
            logger.error(f"Failed to load job {job_id}: {e}", exc_info=True)
            return None

    def delete_job(self, job_id: str) -> bool:
        """
        Delete job state from disk.

        Args:
            job_id: Job ID

        Returns:
            True if successful, False otherwise
        """
        try:
            job_file = self._get_job_file(job_id)

            if job_file.exists():
                job_file.unlink()

            # Remove from memory cache
            self._memory_cache.pop(job_id, None)

            return True
        except Exception as e:
            logger.error(f"Failed to delete job {job_id}: {e}", exc_info=True)
            return False

    def list_all_jobs(self) -> List[str]:
        """
        List all job IDs.

        Returns:
            List of job IDs
        """
        try:
            return [f.stem for f in self.jobs_dir.glob("*.json")]
        except Exception as e:
            logger.error(f"Failed to list jobs: {e}", exc_info=True)
            return []

    def load_all_jobs(self) -> Dict[str, dict]:
        """
        Load all jobs from disk.

        Returns:
            Dictionary mapping job IDs to job data
        """
        jobs = {}
        for job_id in self.list_all_jobs():
            job_data = self.load_job(job_id)
            if job_data:
                jobs[job_id] = job_data
        return jobs

    def cleanup_old_jobs(self, max_age_hours: int = 48) -> int:
        """
        Cleanup old job files.

        Args:
            max_age_hours: Maximum age in hours

        Returns:
            Number of jobs deleted
        """
        try:
            cutoff_time = datetime.utcnow() - timedelta(hours=max_age_hours)
            deleted_count = 0

            for job_file in self.jobs_dir.glob("*.json"):
                try:
                    # Check file modification time
                    mtime = datetime.utcfromtimestamp(job_file.stat().st_mtime)

                    if mtime < cutoff_time:
                        job_id = job_file.stem
                        self.delete_job(job_id)
                        deleted_count += 1
                        logger.info(f"Deleted old job: {job_id}")
                except Exception as e:
                    logger.warning(f"Failed to check/delete job file {job_file}: {e}")
                    continue

            logger.info(f"Job cleanup: deleted {deleted_count} jobs older than {max_age_hours}h")
            return deleted_count

        except Exception as e:
            logger.error(f"Failed to cleanup jobs: {e}", exc_info=True)
            return 0

    def get_resumable_jobs(self) -> List[dict]:
        """
        Get list of jobs that can be resumed (queued or running state).

        Returns:
            List of resumable job summaries with jobId, state, bookTitle, timestamp
        """
        resumable_jobs = []

        for job_id in self.list_all_jobs():
            job_file = self._get_job_file(job_id)
            if not job_file.exists():
                continue

            try:
                with open(job_file, 'r', encoding='utf-8') as handle:
                    raw_data = json.load(handle)
            except Exception:
                continue

            saved_at = raw_data.get("_saved_at", "")
            raw_data.pop("_saved_at", None)
            self._memory_cache[job_id] = raw_data
            job_data = raw_data

            if not job_data:
                continue

            state = job_data.get("state", "")

            # Only include jobs that are still in progress
            if state in ("queued", "running"):
                resumable_jobs.append({
                    "jobId": job_id,
                    "state": state,
                    "bookTitle": job_data.get("bookTitle", "Livro Desconhecido"),
                    "fileName": Path(job_data.get("file_path", "")).name if job_data.get("file_path") else "unknown",
                    "savedAt": saved_at,
                    "chaptersCompleted": job_data.get("chaptersCompleted", 0),
                    "chaptersTotal": job_data.get("chaptersTotal"),
                    "engine": job_data.get("engine"),
                    "voice": job_data.get("voice"),
                    "language": job_data.get("detectedLanguage") or job_data.get("language"),
                    "formattingCues": job_data.get("formattingCues"),
                    "uiLanguage": job_data.get("uiLanguage"),
                })

        # Sort by saved timestamp (newest first)
        resumable_jobs.sort(key=lambda x: x.get("savedAt", ""), reverse=True)

        return resumable_jobs
