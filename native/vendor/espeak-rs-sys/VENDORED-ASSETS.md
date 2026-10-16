# Vendored phoneme source assets

The 203 WAV source inputs under `espeak-ng/phsource/` (882,146 bytes) are
unmodified files from the published `espeak-rs-sys` 0.2.0 package:

- Package: https://static.crates.io/crates/espeak-rs-sys/espeak-rs-sys-0.2.0.crate
- Official registry metadata: https://index.crates.io/es/pe/espeak-rs-sys
- Package SHA-256: `2d45d148019084e930df6cc3964a58c4c211342451ec5d3c328d8a6cc6b3464d`
- Upstream VCS revision: `d70b0970a87453f3476b5fd6cf9edf329be8b445`
- Upstream package path: `crates/espeak-rs-sys`
- Per-file SHA-256 inventory: `phsource-wav.sha256`, relative to this directory.

The original vendoring omitted these inputs because the repository ignores WAV
output files. The scoped `.gitignore` exception preserves these build inputs.
All 1,118 other phoneme source files match the same published package.
The existing vendored license remains applicable; these are upstream compiler
inputs, not generated speech or replacement runtime data.

The CMake `COMPILE_INTONATIONS` feature also compiles phonemes and requires these
files even when a system `espeak-ng-data` package is installed. Do not disable
that compilation to hide missing inputs. `build.rs` refreshes its copied source
when Cargo reruns it so restored build caches receive newly restored inputs.
