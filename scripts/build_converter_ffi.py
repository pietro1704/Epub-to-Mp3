#!/usr/bin/env python3
"""Build converter-ffi for explicitly requested native Rust targets.

This script never installs Rust toolchains or targets. It validates the target
mapping first, checks that each target is already installed, then invokes
`cargo build --release --target <target> -p converter-ffi`.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
from pathlib import Path

TARGETS = {
    "android-arm64": "aarch64-linux-android",
    "android-armv7": "armv7-linux-androideabi",
    "android-x64": "x86_64-linux-android",
    "android-x86": "i686-linux-android",
    "ios-device": "aarch64-apple-ios",
    "ios-simulator-arm64": "aarch64-apple-ios-sim",
    "ios-simulator-x64": "x86_64-apple-ios",
}

ANDROID_JNI_ABIS = {
    "android-arm64": "arm64-v8a",
    "android-armv7": "armeabi-v7a",
    "android-x64": "x86_64",
    "android-x86": "x86",
}


def artifact_path(repo_root: Path, name: str) -> Path:
    target = TARGETS[name]
    library = "converter_ffi.dll" if target.endswith("windows-msvc") else "libconverter_ffi.dylib" if "apple" in target else "libconverter_ffi.so"
    return repo_root / "target" / target / "release" / library


def android_jni_path(repo_root: Path, name: str) -> Path:
    if name not in ANDROID_JNI_ABIS:
        raise ValueError(f"{name} is not an Android target")
    return repo_root / "flutter_app" / "android" / "app" / "src" / "main" / "jniLibs" / ANDROID_JNI_ABIS[name] / "libconverter_ffi.so"


def validate_targets(names: list[str]) -> None:
    unknown = [name for name in names if name not in TARGETS]
    if unknown:
        known = ", ".join(TARGETS)
        raise SystemExit(f"error: unknown target name(s): {', '.join(unknown)}; choose from: {known}")


def installed_targets() -> set[str]:
    result = subprocess.run(["rustup", "target", "list", "--installed"], text=True, capture_output=True, check=False)
    if result.returncode != 0:
        raise SystemExit("error: rustup is required to inspect installed targets; install it, then add targets manually")
    return set(result.stdout.split())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("targets", nargs="*", choices=sorted(TARGETS), help="logical target names; defaults to all supported targets")
    parser.add_argument("--list", action="store_true", help="list logical names, Rust targets, and exact output paths")
    parser.add_argument("--dry-run", action="store_true", help="validate prerequisites and print cargo commands without building")
    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    names = args.targets or list(TARGETS)

    if args.list:
        for name, target in TARGETS.items():
            destination = f" -> {android_jni_path(repo_root, name)}" if name in ANDROID_JNI_ABIS else ""
            print(f"{name}: {target} -> {artifact_path(repo_root, name)}{destination}")
        return 0

    validate_targets(names)
    if shutil.which("cargo") is None:
        raise SystemExit("error: cargo is unavailable; install Rust via mise, then retry (this task does not install it)")
    installed = installed_targets()
    missing = [f"{name} ({TARGETS[name]})" for name in names if TARGETS[name] not in installed]
    if missing:
        raise SystemExit("error: required Rust target(s) are not installed: " + ", ".join(missing) + ". Add them explicitly with `rustup target add <target>`; this task will not download toolchains.")

    for name in names:
        target = TARGETS[name]
        command = ["cargo", "build", "--release", "--target", target, "-p", "converter-ffi"]
        print("+", " ".join(command))
        if not args.dry_run:
            completed = subprocess.run(command, cwd=repo_root, check=False)
            if completed.returncode != 0:
                raise SystemExit(f"error: cargo failed for {name} ({target}); install the target/toolchain manually and retry")
            output = artifact_path(repo_root, name)
            if not output.is_file():
                raise SystemExit(f"error: cargo reported success but artifact is missing: {output}")
        print(f"output: {artifact_path(repo_root, name)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
