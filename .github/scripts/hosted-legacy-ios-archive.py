"""Hosted ARM archive inspection only. Importing this module performs no work."""

import hashlib as hashlib
from datetime import datetime as datetime, timezone as timezone
import json as json
import os as os
from pathlib import Path as Path, PurePosixPath as PurePosixPath
import platform as platform
import plistlib as plistlib
import re as re
import selectors as selectors
import shutil as shutil
import signal as signal
import stat as stat
import struct as struct
import subprocess as subprocess
import sys as sys
import tempfile as tempfile
import time as time
import urllib.request  # noqa: F401
import xml.etree.ElementTree as ET  # noqa: F401

# Keep direct CLI and importlib fixture loading independent of the caller cwd.
_module_root = str(Path(__file__).resolve().parent)
if _module_root not in sys.path:
    sys.path.insert(0, _module_root)

import hosted_archive_commands as command_runner  # noqa: E402
import hosted_archive_contracts as contracts  # noqa: E402
import hosted_archive_inspector as inspection  # noqa: E402
import hosted_archive_runtime_metadata as runtime_metadata  # noqa: E402
from hosted_archive_contracts import (  # noqa: E402
    APPLE_CA as APPLE_CA,
    Blocked as Blocked,
    BomModes as BomModes,
    CATALOG as CATALOG,
    GIB as GIB,
    LAYOUT_BYTES as LAYOUT_BYTES,
    LAYOUT_DEPTH as LAYOUT_DEPTH,
    LAYOUT_RECORDS as LAYOUT_RECORDS,
    LAYOUT_SCANNED as LAYOUT_SCANNED,
    LAYOUT_SECONDS as LAYOUT_SECONDS,
    MARKER as MARKER,
    MAX_HEADERS as MAX_HEADERS,
    MAX_LISTING_BYTES as MAX_LISTING_BYTES,
    MAX_LISTING_ENTRIES as MAX_LISTING_ENTRIES,
    MAX_LISTING_LINE as MAX_LISTING_LINE,
    MAX_LOG as MAX_LOG,
    MAX_PAYLOAD as MAX_PAYLOAD,
    MAX_SIGNED_BOM_ENTRIES as MAX_SIGNED_BOM_ENTRIES,
    OBSERVED_ARCHIVE_BYTES as OBSERVED_ARCHIVE_BYTES,
    PayloadListing as PayloadListing,
    RESERVE as RESERVE,
    SIZE as SIZE,
    STREAM_CHUNK as STREAM_CHUNK,
    URL as URL,
    cache_metadata as cache_metadata,
    declared_payload as declared_payload,
    diagnostic_kind as diagnostic_kind,
    diagnostic_path as diagnostic_path,
    disk_gate as disk_gate,
    http_headers as http_headers,
    interrupt as interrupt,
    macho_architectures as macho_architectures,
    package_info_metadata as package_info_metadata,
    read_plist as read_plist,
    safe_payload_listing as safe_payload_listing,
    signature_gate as signature_gate,
    within as within,
)
from hosted_archive_inspector import Inspector as Inspector  # noqa: E402


def main():
    # The runner may signal an active step. Raise into command/finally cleanup;
    # hard-kill recovery is separately fail-closed, with no untrusted PID kill.
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    if sys.argv[1:] == ["--cleanup-owned"]:
        reports = Path(os.environ["RUNNER_TEMP"]) / "legacy-ios-archive-report"
        result = {"phase": "owned_cleanup_recovery", "state": "complete_or_already_absent"}
        try:
            Inspector.recover_cleanup(os.environ["RUNNER_TEMP"], reports)
        except Exception as error:
            result.update({"state": "blocked_preserving_owned_tree", "reason": f"{type(error).__name__}: {error}"})
        reports.mkdir(exist_ok=True)
        (reports / "cleanup-recovery.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result))
        return 2 if result["state"].startswith("blocked") else 0
    if sys.argv[1:] not in ([], ["--http-metadata-only"]):
        raise Blocked("Unknown archive inspection arguments")
    inspector = Inspector(os.environ["RUNNER_TEMP"], Path(os.environ["RUNNER_TEMP"]) / "legacy-ios-archive-report")
    try:
        inspector.inspect(http_metadata_only=sys.argv[1:] == ["--http-metadata-only"])
    except Exception as error:
        inspector.report["blockers"].append(f"{type(error).__name__}: {error}")
    finally:
        try:
            inspector.cleanup()
        except Exception as error:
            inspector.report["cleanup"] = "blocked_owned_tree_preserved"
            inspector.report["blockers"].append(f"Cleanup: {type(error).__name__}: {error}")
        if inspector.report["blockers"]:
            inspector.report["state"] = "blocked"
        (inspector.reports / "report.json").write_text(json.dumps(inspector.report, indent=2) + "\n")
        print(json.dumps(inspector.report))
    return 2 if inspector.report["blockers"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
