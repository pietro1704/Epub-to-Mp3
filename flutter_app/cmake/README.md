# Native desktop Piper bundles

Both desktop CMake builds compile `converter-ffi` with `piper-runtime` and one
Cargo job. The normal host Flutter tasks are the entry points:

- Linux host: `mise run flutter:build-linux`
- Windows host: `mise run flutter:build-windows`

These are native host builds, not cross-compilation commands. Install the native
Flutter prerequisites, Cargo, CMake, a C/C++ toolchain, and libclang for bindgen.
Windows requires the MSVC Rust target and Visual Studio C++ build tools.
`ORT_LIB_LOCATION` can select a preinstalled compatible ONNX Runtime distribution;
otherwise the pinned Rust dependency resolves its supported host distribution.
No voice weights are downloaded by desktop packaging; models are installed by
explicit user action in the app.

`CONVERTER_CARGO_TARGET_DIR` is an optional CMake cache path. Its default isolates
host artifacts from Apple/Android build outputs. The staging script fails if the
FFI artifact or complete Portuguese phonemizer data is missing. It copies any
shared ONNX Runtime dependencies, preserving versioned library filenames.
Linux installs native libraries under `lib/`; Windows installs them beside the
executable. Both install the full `data/espeak-ng-data` tree. The Dart adapter
loads the packaged library by absolute path and supplies the containing `data`
directory to eSpeak.

The packaging fixture can run without Rust or Flutter compilation:

```sh
mise exec -- cmake -P flutter_app/cmake/stage_converter_runtime_test.cmake
```

The fixture validates staging only. A host build, app launch, model installation,
and audible conversion remain required to verify Linux or Windows behavior.
