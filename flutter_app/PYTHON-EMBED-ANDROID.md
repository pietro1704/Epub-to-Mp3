# Android runtime reference (historical Python-embed path)

Current Flutter startup registers `AndroidEmbeddedConverter`, using
`epub_to_mp3/embedded_converter` and the native Rust/JNI implementation.
`android/app/build.gradle.kts` packages/checks `libconverter_ffi.so` under
`src/main/jniLibs/`. The old Chaquopy diagram, Python bootstrap, APK size estimate
and AGP compatibility diagnosis describe a superseded integration.

Use [the current Flutter guide](README.md) and
[FFI artifacts](../docs/converter-ffi-artifacts.md) for runtime ownership.
Inspect actual Kotlin/JNI callers, Rust feature flags, ABI/phonemizer assets and
packaging scripts before an authorized build; presence of Python bridge source
or assets does not prove the production route uses them. The old HTTP-backend
paragraph was also transitional and is not the current embedded startup contract.

Android/Samsung work is paused until resumed by the user and belongs on Arch
under [execution policy](../docs/agents/execution-policy.md). Do not run old
bootstrap recipes, install dependencies, alter AGP, boot an emulator or infer
runtime success from source registration. Device/audio/conversion acceptance
requires evidence from the exact artifact and platform when authorized.
