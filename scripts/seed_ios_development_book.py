#!/usr/bin/env python3
"""Stage the local development EPUB in a newly installed iOS app container."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

BUNDLE_ID = "com.pietrocode.epubtomp3"
STAGED_FILENAME = "EpubToMp3DevelopmentSeed.epub"
MISSING_SOURCE_EXIT = 3


def development_book_source() -> Path | None:
    configured = os.environ.get("IOS_DEVELOPMENT_SEED_BOOK", "").strip()
    candidates = (
        [Path(configured).expanduser()]
        if configured
        else [
            Path.home()
            / "Downloads"
            / "Ebooks"
            / "The Lord of the Rings (J.R.R. Tolkien) (z-library.sk, 1lib.sk, z-lib.sk).epub",
            Path.home()
            / "Downloads"
            / "ebook"
            / "The Lord of the Rings (J.R.R. Tolkien) (z-library.sk, 1lib.sk, z-lib.sk).epub",
        ]
    )
    return next((path for path in candidates if path.is_file()), None)


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=True, text=True, capture_output=True)


def stage_for_simulator(source: Path, identifier: str) -> Path:
    container = Path(
        run(
            [
                "xcrun",
                "simctl",
                "get_app_container",
                identifier,
                BUNDLE_ID,
                "data",
            ]
        ).stdout.strip()
    )
    target = container / "Documents" / STAGED_FILENAME
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.is_file() or source.stat().st_size != target.stat().st_size:
        shutil.copy2(source, target)
    return target


def stage_for_device(source: Path, identifier: str) -> str:
    destination = f"Documents/{STAGED_FILENAME}"
    run(
        [
            "xcrun",
            "devicectl",
            "device",
            "copy",
            "to",
            "--device",
            identifier,
            "--source",
            str(source),
            "--destination",
            destination,
            "--domain-type",
            "appDataContainer",
            "--domain-identifier",
            BUNDLE_ID,
        ]
    )
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=("simulator", "device"), required=True)
    parser.add_argument("--identifier", required=True)
    args = parser.parse_args()

    source = development_book_source()
    if source is None:
        print("ios development seed skipped: source EPUB is unavailable", file=sys.stderr)
        return MISSING_SOURCE_EXIT

    try:
        destination = (
            stage_for_simulator(source, args.identifier)
            if args.target == "simulator"
            else stage_for_device(source, args.identifier)
        )
    except subprocess.CalledProcessError as error:
        print(error.stderr.strip() or str(error), file=sys.stderr)
        return 1

    print(f"ios development seed → {source.name} → {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
