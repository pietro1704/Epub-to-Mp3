# Native third-party notices

The workspace declares MIT for the project's Rust crates in
[`Cargo.toml`](../Cargo.toml). This notice does not change that declaration.
Bundled dependencies retain their own licenses; a wrapper's Cargo license does
not relicense the native source or data that it builds and distributes.

## eSpeak NG

| Component | Source in this repository | License evidence |
| --- | --- | --- |
| eSpeak NG native engine | `vendor/espeak-rs-sys/espeak-ng/src/` | Source headers, including [`speech.c`](vendor/espeak-rs-sys/espeak-ng/src/libespeak-ng/speech.c), grant GPL version 3 or any later version (`GPL-3.0-or-later`). Copyright holders include Jonathan Duddington and Reece H. Dunn. |
| NV Speech Player | `vendor/espeak-rs-sys/espeak-ng/src/speechPlayer/` | [`speechPlayer.h`](vendor/espeak-rs-sys/espeak-ng/src/speechPlayer/src/speechPlayer.h) grants GPL version 3 or later; copyright 2014 NV Access Limited. Its [CMake target](vendor/espeak-rs-sys/espeak-ng/src/speechPlayer/CMakeLists.txt) builds a static library linked by the Rust build script. |
| ucd-tools implementation | `vendor/espeak-rs-sys/espeak-ng/src/ucd-tools/` | [`case.c`](vendor/espeak-rs-sys/espeak-ng/src/ucd-tools/src/case.c) grants GPL version 3 or later; the full GPL text is retained in [`COPYING`](vendor/espeak-rs-sys/espeak-ng/src/ucd-tools/COPYING). Unicode data has its own retained [`COPYING.UCD`](vendor/espeak-rs-sys/espeak-ng/src/ucd-tools/COPYING.UCD); do not replace it with the code license. |
| Local Piper phoneme bridge | `vendor/espeak-rs-sys/espeak-ng/src/libespeak-ng/piper_phonemes.c` | The [source header](vendor/espeak-rs-sys/espeak-ng/src/libespeak-ng/piper_phonemes.c) declares `GPL-3.0-or-later`. [`UPSTREAM.md`](vendor/espeak-rs-sys/UPSTREAM.md) identifies the local modification and upstream reference. It is compiled into the same eSpeak NG library. |
| Phoneme, language and dictionary inputs | `vendor/espeak-rs-sys/espeak-ng/phsource/`, `dictsource/`, `espeak-ng-data/` | Preserve the upstream per-file notices with these inputs and their generated data. They are part of the bundled eSpeak NG source tree, not the Rust wrapper's MIT grant. |
| Rust bindings | `vendor/espeak-rs/`, `vendor/espeak-rs-sys/src/` | The bindings' Cargo manifests declare MIT; [`espeak-rs/LICENSE`](vendor/espeak-rs/LICENSE) contains the retained MIT notice. |
| Sonic fallback | `vendor/espeak-rs-sys/espeak-ng/src/sonic/` | Unmodified C source, header and [Apache 2.0 license](vendor/espeak-rs-sys/espeak-ng/src/sonic/LICENSE) from [Bill Cox's Sonic at `fbf75c3d6d846bad3bb3d456cbc5d07d9fd8c104`](https://github.com/waywardgeek/sonic/tree/fbf75c3d6d846bad3bb3d456cbc5d07d9fd8c104). |

The complete [GNU GPL version 3 text](licenses/espeak-ng-GPL-3.0.txt) is retained
here independently of platform installer sources. It was converted to plain
text from the vendored eSpeak NG Windows installer's `License_GPLv3.rtf`;
the license text and grant were not rewritten. Upstream engine source is
[espeak-ng/espeak-ng](https://github.com/espeak-ng/espeak-ng); this repository's
vendored tree and build scripts are the source used by its builds.

### Source identity

The retained [`VENDORED-ASSETS.md`](vendor/espeak-rs-sys/VENDORED-ASSETS.md)
identifies the published `espeak-rs-sys` 0.2.0 source package, its SHA-256 and
upstream VCS revision `d70b0970a87453f3476b5fd6cf9edf329be8b445`.
The [registry archive](https://static.crates.io/crates/espeak-rs-sys/espeak-rs-sys-0.2.0.crate)
provides a fixed package reference. This is provenance for the imported source,
not a claim that the locally patched tree is byte-identical to that archive.
Distributing a binary built here requires identifying the actual repository
revision and retaining its modifications, including the phoneme bridge and
build scripts, as applicable Corresponding Source.

### Where it enters application artifacts

[`piper-runtime/Cargo.toml`](piper-runtime/Cargo.toml)'s `piper-inference`
feature depends on `piper-rs` and `espeak-rs`. `converter-ffi` enables that path
with its optional [`piper-runtime` feature](../crates/converter-ffi/Cargo.toml).
The [Rust CLI](../crates/converter-cli/Cargo.toml) enables this FFI feature too.
These are feature-dependent artifact paths; they do not establish that every
possible workspace build includes the native engine.
eSpeak NG supplies Piper's phonemization; installed Piper
voice weights are separate artifacts with their own model licenses.

[`espeak-rs-sys/build.rs`](vendor/espeak-rs-sys/build.rs) builds the vendored C
source and defaults to static linking. `ESPEAK_BUILD_SHARED_LIBS=1` selects its
shared-library path. Static linking places eSpeak NG code inside the resulting
native runtime; shipping only `libconverter_ffi` does not remove that code or
its license obligations.

The macOS and iOS package helpers ship `libconverter_ffi.dylib` alongside
`espeak-ng-data`. The Android helper installs `libconverter_ffi.so` and the same
data under the APK's native-library/assets paths. See the actual package
boundaries in [`package_converter_ffi_macos.rb`](../scripts/package_converter_ffi_macos.rb),
[`package_converter_ffi_ios.rb`](../scripts/package_converter_ffi_ios.rb) and
[`package_converter_ffi_android.rb`](../scripts/package_converter_ffi_android.rb).
Linux/Windows builds using the same `piper-inference` feature include this
dependency as well; a system-installed eSpeak executable is a separate runtime
deployment, not evidence that the embedded library excludes eSpeak.

[`package_rust_cli.rb`](../scripts/package_rust_cli.rb) also copies the compiled
CLI and `espeak-ng-data` into `dist/epub-to-mp3-cli/bin/`. This is a binary/data
distribution of the embedded phonemizer even when no stand-alone eSpeak
executable is shipped. The CLI package manifest records payload hashes; it is
not a replacement for the copyright notices, licenses or Corresponding Source.

### Source and binary distribution

Distributions containing the engine must preserve its copyright/license
notices and provide the applicable Corresponding Source and build material
under GPLv3's distribution terms, including local changes. Record the exact
source revision used for the binary; a link to an unrelated latest upstream
revision does not identify its source. Per-file notices remain authoritative
for bundled auxiliary code and data. The MIT declarations of the Rust wrappers
do not establish an MIT-only license for a combined binary containing GPL code.

The [Desktop release workflow](../.github/workflows/release-desktop.yml) stages
notices from the validated source commit in `ThirdPartyNotices` for macOS,
Windows, Linux and Android. The directory includes `SOURCE.md` and links to
the source archive at that specific revision. Verify the contents of each
published artifact, including artifacts made before this step was added. Other
distribution paths require their own checks for notices and source delivery.
