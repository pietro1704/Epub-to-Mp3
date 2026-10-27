# Vendored Piper Rust runtime

Source: piper-rs 0.2.0 from the crates.io registry, upstream commit
`d70b0970a87453f3476b5fd6cf9edf329be8b445`.
Repository: https://github.com/thewh1teagle/piper-rs

Upstream Cargo package metadata declares the MIT license. The published crate
and upstream repository contain no separate license file; the declaration is
preserved in Cargo.toml.

Local change: pin `ort` to `=2.0.0-rc.11` (ONNX Runtime API 23), whose bindings
still support Intel macOS. Product macOS builds use the checksum-pinned
prebuilt ONNX Runtime 1.28.2 from the Sherpa maintainer's runtime releases,
whose Intel artifact declares macOS 10.15. This preserves the product's macOS
12 target without compiling ONNX. Actual inference must verify the API 23 /
runtime combination. iOS uses its separately built platform artifact.
The upstream inference and phonemization source in this crate is unchanged.
The patched `espeak-rs` dependency restores clause punctuation before this
crate joins phoneme sentences; see [phonemization](../../../docs/piper-phonemization.md).
All used Session,
Tensor construction and extraction APIs have matching rc.11 signatures.
Removed example manifest entries whose sample files are not vendored.

Native build and synthesis tests must establish runtime compatibility; source
comparison alone does not prove it. Android and iOS use their actual target
artifacts and the same API level, without pretending host libraries are portable.
