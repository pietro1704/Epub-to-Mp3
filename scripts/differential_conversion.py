#!/usr/bin/env python3
"""Migration-only differential harness for Python/Rust conversion outputs.

This script intentionally shells out to the two explicitly supplied commands;
it does not become part of either production runtime. Each command must write a
JSON result to stdout (or use ``--output`` to write one). The input fixture is
provided as the final argument, unless the command contains ``{input}``.

Example:
    mise exec -- python scripts/differential_conversion.py \
      --python-command '.venv/bin/python -m migration_python_harness {input}' \
      --rust-command 'target/release/converter-cli --json {input}'
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any

DEFAULT_CORPUS = Path(__file__).resolve().parents[1] / "tests" / "fixtures" / "rust_parity" / "v1"
_VOLATILE_KEYS = {"attemptId", "jobId", "publicationId", "requestId", "timestamp", "createdAt", "updatedAt", "elapsed", "elapsedMs", "elapsedNs"}
_UUID = re.compile(r"(?i)\b[0-9a-f]{8}-[0-9a-f-]{27,}\b")
_URL_ID = re.compile(r"(https?://[^\s/?#]+(?:/[^\s?#]*)?)[?&](?:job|request|attempt|publication|id)=[^&\s]+", re.I)
_ABSOLUTE = re.compile(r"(?<![A-Za-z0-9_])(?:/|[A-Za-z]:[\\/])(?:[^\s\"']+)")


def normalize(value: Any, key: str = "") -> Any:
    """Normalize volatile transport metadata while preserving structure and text."""
    if key in _VOLATILE_KEYS or key.lower() in {item.lower() for item in _VOLATILE_KEYS}:
        return f"<{key or 'volatile'}>"
    if isinstance(value, dict):
        return {name: normalize(item, name) for name, item in sorted(value.items())}
    if isinstance(value, list):
        return [normalize(item, key) for item in value]
    if isinstance(value, str):
        value = _UUID.sub("<uuid>", value)
        value = _URL_ID.sub(r"\1?<id>", value)
        return _ABSOLUTE.sub("<path>", value)
    return value


def load_json(raw: str, source: str) -> Any:
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{source} did not emit JSON: {exc}") from exc


def run_command(command: str, fixture: Path, label: str) -> Any:
    argv = shlex.split(command)
    if "{input}" in argv:
        argv = [str(fixture) if arg == "{input}" else arg.replace("{input}", str(fixture)) for arg in argv]
    else:
        argv.append(str(fixture))
    completed = subprocess.run(argv, check=False, capture_output=True, text=True)
    if completed.returncode:
        raise RuntimeError(f"{label} command failed ({completed.returncode}): {completed.stderr.strip()}")
    return load_json(completed.stdout, label)


def digest(value: Any) -> str:
    payload = json.dumps(normalize(value), ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-command", required=True, help="Command producing Python JSON output")
    parser.add_argument("--rust-command", required=True, help="Command producing Rust JSON output")
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--fixture", action="append", dest="fixtures", help="Fixture JSON/NDJSON path; repeatable")
    args = parser.parse_args(argv)
    fixtures = [Path(item) for item in args.fixtures] if args.fixtures else sorted(args.corpus.glob("*.json"))
    if not fixtures:
        parser.error(f"no fixtures found under {args.corpus}")
    failures = 0
    for fixture in fixtures:
        python_value = run_command(args.python_command, fixture, "Python")
        rust_value = run_command(args.rust_command, fixture, "Rust")
        python_digest, rust_digest = digest(python_value), digest(rust_value)
        status = "match" if python_digest == rust_digest else "MISMATCH"
        print(json.dumps({"fixture": str(fixture), "status": status, "python": python_digest, "rust": rust_digest}, sort_keys=True))
        failures += status != "match"
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
