#!/usr/bin/env python3
"""Host-only validation for converter-ffi target mapping and artifact names."""

from __future__ import annotations

import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).with_name("build_converter_ffi.py")
spec = importlib.util.spec_from_file_location("build_converter_ffi", SCRIPT)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

EXPECTED = {
    "android-arm64": ("aarch64-linux-android", "libconverter_ffi.so"),
    "android-armv7": ("armv7-linux-androideabi", "libconverter_ffi.so"),
    "android-x64": ("x86_64-linux-android", "libconverter_ffi.so"),
    "android-x86": ("i686-linux-android", "libconverter_ffi.so"),
    "ios-device": ("aarch64-apple-ios", "libconverter_ffi.dylib"),
    "ios-simulator-arm64": ("aarch64-apple-ios-sim", "libconverter_ffi.dylib"),
    "ios-simulator-x64": ("x86_64-apple-ios", "libconverter_ffi.dylib"),
}

root = SCRIPT.parents[1]
assert module.TARGETS == {name: target for name, (target, _library) in EXPECTED.items()}
for name, (target, library) in EXPECTED.items():
    assert module.artifact_path(root, name) == root / "target" / target / "release" / library
    if name.startswith("android-"):
        assert module.android_jni_path(root, name).name == "libconverter_ffi.so"
        assert module.android_jni_path(root, name).parent.name in {"arm64-v8a", "armeabi-v7a", "x86_64", "x86"}
print(f"validated {len(EXPECTED)} converter-ffi target mappings")
