# Simulator Rust bundling

Scope: one Apple packaging slice on the existing Gitflow fix branch. User authorizes
the otherwise Arch-owned Rust build here solely for the Apple Simulator artifact.
No FFI/API/conversion behavior changes, Flutter execution, device runs or user-data edits.

Route iphoneos to aarch64-apple-ios; route Intel iphonesimulator to x86_64-apple-ios
and Apple Silicon Simulator to aarch64-apple-ios-sim. Validate Mach-O architecture,
platform and required ABI before embedding into app Frameworks; preserve macOS path.
Use Debug Rust for local Debug Simulator iteration and Release for Release packaging.

Risk: known host panics under concurrent load. Keep Simulator stopped during builds,
serialize heavy work with the shared lease, one compiler job. No Xcode GUI.
Acceptance: reject existing device/macOS dylibs as Simulator input, verify real
Simulator library and bundled output, then exercise minimum native app behavior.
Missing runtime/artifact or unsafe resource state means incomplete, not passed.

## Evidence

Debug Rust Simulator target built in 4m43s, with explicit rustup rustc selection
because inherited Homebrew rustc could not find the installed target standard library.
Real packaging regression passed, including a valid Mach-O fixture with incomplete
ABI, wrong-platform rejection, real device/Simulator acceptance and signed copy.
App build-for-testing passed in `simulator-smoke-AFCEF095-4935-4134-815F-1700B702B283`;
the actual bundled dylib passed architecture/platform/ABI and strict signature checks.
Read-only specialist review found no further high-risk packaging defects.

Native XCTest/UI attempt was stopped by load watchdog before usable test results
(`simulator-smoke-F317C627-7D57-4741-A478-17210E8F5920`). Incomplete result directory
is not evidence of a passed test. A queued boot raced initial shutdown; the exact
device was shut down again and no devices remain booted. Explicit boot/wait is now
watched before XCTest. Updated guard refused a retry at load 15.58 without booting.
CleanMyMac HealthMonitor was observed at 165% CPU, but causality is unproven.
App startup/UI remains pending; no conversion, device run or CI monitoring performed.

Authorized CleanMyMac monitor intervention did not remove the boot load spike.
TERM respawned; the replacement monitor was paused (T state), then a retry after
idle load 3.64 reached 14.88 during initial migration. Guard stopped before app/tests;
monitor restored with SIGCONT, no devices left booted. No thermal/performance
warning was reported. The instantaneous load cutoff prevents migration completing;
this is not an app assertion failure or proof of another host crash. Further boot
requires an agreed bounded startup/resource policy, not repeated unchanged attempts.
