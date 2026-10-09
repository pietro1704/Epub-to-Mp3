#!/usr/bin/env python3
"""Host-only validation for converter-ffi target mapping and artifact names."""

from __future__ import annotations

import importlib.util
import io
import shlex
from contextlib import redirect_stdout
from unittest.mock import patch
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

# Exercise the actual command generation without invoking cross-platform builds.
commands = io.StringIO()
with patch("sys.argv", [str(SCRIPT), *EXPECTED, "--dry-run"]), \
        patch.object(module.shutil, "which", return_value="cargo"), \
        patch.object(module, "installed_targets", return_value=set(module.TARGETS.values())), \
        redirect_stdout(commands):
    assert module.main() == 0
for line in commands.getvalue().splitlines():
    if not line.startswith("+ "):
        continue
    command = shlex.split(line[2:])
    target = command[command.index("--target") + 1]
    if "android" in target:
        assert "--features" in command, f"Missing JNI feature for {target}"
        assert command[command.index("--features") + 1] == "android-jni"
    else:
        assert "--features" not in command, f"Android JNI enabled for {target}"
print("validated Android JNI features and unchanged Apple build commands")
