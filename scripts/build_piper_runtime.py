#!/usr/bin/env python3
"""Validate native Piper runtime prerequisites without fabricating artifacts."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
required = [ROOT / "native" / "piper-runtime" / "Cargo.toml"]
missing = [str(path) for path in required if not path.exists()]
models = list((ROOT / "models" / "piper").glob("*.onnx"))
if not models:
    missing.append(str(ROOT / "models" / "piper" / "<voice>.onnx"))
if missing:
    raise SystemExit(
        "Piper Embedded runtime source is missing; refusing to fabricate "
        "libpiper_runtime.so. Missing: " + ", ".join(missing)
    )
raise SystemExit("Piper Embedded runtime build integration is not implemented")
