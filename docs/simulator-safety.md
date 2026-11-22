# Supervised Intel Simulator sessions

Pietro removed every native host guard on 2026-11-22, including the Intel
Simulator quarantine. `native_job.rb simulator` runs its command under the shared
build lease like any other job, and `mise run ios:simulator:supervised` is the
bounded, report-producing route for the SE1/iOS 15.2 reader target. Resource
readings (memory pressure, reported free memory, swap, CPU idle, free disk) are
recorded as notes in the session report and never refuse, delay or stop a
session. The host had recurrent `SimMetalHost` / `IGGuC.cpp:2913` kernel panics
before; nothing here is a fix or prevention for them, and the lease or the notes
do not make the Simulator safe.

The dedicated route requires installed Xcode 26.3, an available x86_64 iOS 15.2
runtime, a shut-down first-generation iPhone SE UDID, and an existing compatible
EpubToMp3 simulator app. It never downloads runtimes, creates devices, compiles,
closes unrelated apps, or automatically retries. Installation and dependency
preparation remain separate authorized operations. Do not use device arm64 binaries.

Run a bounded launch smoke with:

```sh
mise run ios:simulator:supervised -- \
  --device EXPLICIT-DEVICE-UUID \
  --app /absolute/EpubToMp3.app \
  --report-directory /absolute/new-private-report-directory
```

The report directory must not exist. The route preserves the global Xcode
selection and takes the shared native lease, so a second job on the same output
trees waits for it (`--wait` does not apply here; start it again after the holder
ends). It checks runtime, device, executable architecture/platform, bundle identity,
minimum OS and app content identity before installation.

Local compatibility check on macOS 15.8.2: CoreSimulator reports iOS 15.0 as
unavailable with `The iOS 15.0 simulator runtime is not supported on hosts after
macOS 14.99.0.` The installed framework's `updatedMaxHostVersions` table applies
this override specifically to `iOS-15-0`; it does not list 15.2, 15.4 or 15.5.
The official download index lists 15.2 as the next-smallest available 15.x runtime.
Historical project evidence also records successful SE1/iOS 15.5 execution.
The generic Xcode support matrix and downloadable package availability do not
override this runtime-level restriction. The dedicated route now pins 15.2 and
still requires that CoreSimulator reports it available. Selecting another runtime requires an
explicit scoped update and validation; never patch its availability metadata.

Pietro selected SE1/iOS 15.2 as the required reader target on 2026-11-05.
Keep only the iOS 15.2 and 26.2 runtimes; historical iOS 15.5 evidence does not
change that current requirement.

Resource policy: a single sample is taken before boot and then about every five
seconds; each sample, and every reading outside the reference sizes, goes into
the report (`samples`, and `advisories` without duplicates; `resource_policy` is
`advisory_notes_only`). The reference sizes are the former admission limits:
normal pressure, reported free memory at least 40%, swap at most 1 GiB, CPU idle
at least 70% and 15 GiB free disk. Reported free memory is the
`memory_pressure -Q` metric, not literal unused RAM. Telemetry that fails or is
invalid is also only a note.

Sampling targets a five-second cadence. A full snapshot has a 12-second deadline.
The CPU sampler reads Mach CPU counters over a one-second interval in a subprocess
with an eight-second deadline. What still ends a session is the session itself:
foreground cancellation or death, a lost heartbeat, a failed identity check, a
stage deadline (boot 120 seconds, launch observation 15 seconds, 600 seconds in
all) or an owned process that exited. Cleanup always runs.

For an already-built XCTest artifact, the route accepts
`--test-run /absolute/Products/name.xctestrun` and either one fully qualified
`--test-selector Target/Class/testMethod` or `--test-manifest /absolute/preset.json`.
The manifest must equal one of the closed presets in `SimulatorTestBackend`:
eleven native playback/transport methods, the two embedded PDF/system-MP3
methods, or the closed native Apple experience control/geometry batch. Partial, mixed, duplicate and wildcard selections are rejected. The
runner uses `test-without-building`, one explicit destination, no parallel tests
and a tracked process group. The test command has at most 120 seconds within
the 600-second session. Test-run/manifest identities are
recorded and rechecked. `--seed-book` stages an existing EPUB with a bounded,
exclusive copy, preserving a different existing file and rejecting symlinks.

A detached watchdog owns the native lease, telemetry, subprocesses and cleanup.
After any boot attempt, cleanup shuts down only the explicit device, cancels its
owned command group and terminates its unreaped Simulator UI child. It requires
all devices to be Shutdown and no Simulator/SimMetalHost processes for five
consecutive seconds within the thirty-second cleanup limit. It never stops an
unrelated device or shared CoreSimulator service. A cleanup failure is a failure.

Capture screenshots during the supervised journey or extract them from a copy
of the completed xcresult. A screenshot command after cleanup can recreate
rendering XPC processes even for an already-shutdown device; do not issue it.

`launch_smoke_passed` proves app survival and cleanup, not reading or inference.
`test_command_completed` proves command completion only. After verified cleanup,
query an isolated xcresult copy through `scripts/xcresult_job.rb` and require
the exact selected test count, every test passed, zero failures and zero skips
before declaring functional acceptance. Preserve original failures and identify
passing evidence spread across multiple runs. None of these checks establishes
a GPU-driver fix or long-term stability.

Host regressions (no Simulator or compilation):

```sh
mise run ios:simulator:safety:test
```
