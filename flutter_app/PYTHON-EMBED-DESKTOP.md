# Desktop runtime reference (historical Python-embed path)

Flutter Linux/Windows startup registers `DesktopEmbeddedConverter`, which loads
`converter-ffi` directly. `desktop_tts_model_adapter.dart` exposes the shared Rust
catalog/store, and current desktop build scripts own native-library packaging.
System Python is not the production conversion prerequisite described by the old
subprocess design.

`lib/services/python_bridge.dart` and retained Python assets remain compatibility
material. Inspect actual callers and packaging before removing them; a retained
file, source comment or asset declaration does not identify the active production
path. The historical subprocess probing/extraction contract and timing estimates
are archived, not instructions to install or embed another Python runtime.

Read [the Flutter guide](README.md),
[FFI artifacts](../docs/converter-ffi-artifacts.md) and
[execution policy](../docs/agents/execution-policy.md). Flutter Linux work belongs
on Arch; Windows needs a compatible Windows toolchain. Apple platforms use the
native application, not a new Flutter scaffold.

Verify actual dynamic-library identity, architecture/dependencies and model/
phonemizer assets at the packaging seam. Missing artifacts remain explicit
failures. Source wiring cannot establish successful desktop conversion, playback
or release acceptance, and old bootstrap recipes are not an execution path.
