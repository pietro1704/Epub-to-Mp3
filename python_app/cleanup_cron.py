#!/usr/bin/env python3
"""
Cron job script to cleanup old files from storage.

Usage:
    python cleanup_cron.py [--max-age-hours HOURS] [--api-url URL]

Setup Railway cron (via GitHub Actions):
    Add to .github/workflows/cleanup.yml:
    
    name: Cleanup old files
    on:
      schedule:
        - cron: '0 */6 * * *'  # Every 6 hours
    jobs:
      cleanup:
        runs-on: ubuntu-latest
        steps:
          - name: Call cleanup API
            run: |
              curl -X POST "${{ secrets.API_URL }}/api/cleanup?max_age_hours=48"
"""

import argparse
import logging
import sys
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))

from src.storage_manager import get_storage_manager

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def cleanup_local_files(output_dir: Path, max_age_hours: int) -> int:
    """Cleanup old local files."""
    import shutil
    import time

    cutoff_time = time.time() - (max_age_hours * 3600)
    deleted_count = 0

    if not output_dir.exists():
        logger.warning(f"Output directory not found: {output_dir}")
        return 0

    for job_dir in output_dir.iterdir():
        if not job_dir.is_dir():
            continue

        dir_mtime = job_dir.stat().st_mtime
        if dir_mtime < cutoff_time:
            try:
                shutil.rmtree(job_dir)
                deleted_count += 1
                logger.info(f"✅ Deleted old job directory: {job_dir.name}")
            except Exception as e:
                logger.error(f"❌ Failed to delete {job_dir.name}: {e}")

    return deleted_count


def main():
    parser = argparse.ArgumentParser(description="Cleanup old audiobook files")
    parser.add_argument(
        "--max-age-hours",
        type=int,
        default=48,
        help="Maximum age of files in hours (default: 48)"
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("output"),
        help="Local output directory (default: output)"
    )
    parser.add_argument(
        "--api-url",
        type=str,
        help="Call API cleanup endpoint instead of running locally"
    )

    args = parser.parse_args()

    if args.api_url:
        # Call API endpoint
        import requests
        try:
            response = requests.post(
                f"{args.api_url}/api/cleanup",
                params={"max_age_hours": args.max_age_hours},
                timeout=30
            )
            response.raise_for_status()
            result = response.json()
            logger.info(f"API cleanup result: {result}")
            return 0
        except Exception as e:
            logger.error(f"API cleanup failed: {e}")
            return 1

    # Run cleanup locally
    logger.info(f"Starting cleanup (max age: {args.max_age_hours} hours)...")

    # Cleanup local files
    local_deleted = cleanup_local_files(args.output_dir, args.max_age_hours)
    logger.info(f"Local files deleted: {local_deleted}")

    # Cleanup R2 files
    storage = get_storage_manager()
    if storage.is_enabled():
        r2_deleted = storage.cleanup_old_files(max_age_hours=args.max_age_hours)
        logger.info(f"R2 files deleted: {r2_deleted}")
    else:
        logger.warning("R2 storage not configured - skipping R2 cleanup")

    logger.info("✅ Cleanup completed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
