# Supervised Intel Simulator sessions

The legacy `native_job.rb simulator` route remains quarantined. Only an explicitly
risk-acknowledged session uses `mise run ios:simulator:supervised`. Monitoring does
not prevent the Intel GPU-driver kernel panics previously observed on this host.

The dedicated route requires installed Xcode 26.3, an available x86_64 iOS 15.2
runtime, a shut-down first-generation iPhone SE UDID, and an existing compatible
EpubToMp3 simulator app. It never downloads runtimes, creates devices, compiles,
closes unrelated apps, or automatically retries. Installation and dependency
preparation remain separate authorized operations. Do not use device arm64 binaries.

Inspect resources without booting:

```sh
mise run ios:simulator:resources -- --report /absolute/new-report.json
```

After explicit task authorization, run a bounded launch smoke with:

```sh
mise run ios:simulator:supervised -- \
  --device EXPLICIT-DEVICE-UUID \
  --app /absolute/EpubToMp3.app \
  --report-directory /absolute/new-private-report-directory \
  --acknowledge-intel-panic-risk
```

The report directory must not exist. The acknowledgment records an intentional
invocation; it is not a replacement for user authorization or specialist review.
The route preserves the global Xcode selection and refuses simultaneous native
jobs. It checks runtime, device, executable architecture/platform, bundle identity,
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

Admission policies are explicit:

| Policy | Baseline | Admission | Session limit |
| --- | --- | --- | --- |
| Default | 60 seconds | Normal pressure, reported free memory at least 40%, swap at most 1 GiB, unchanged swapouts, CPU idle at least 70% | 600 seconds |
| `--allow-stable-existing-swap` | 60 seconds | Normal pressure, reported free memory at least 50%, no swap allocation growth or new swapouts, CPU idle at least 70% | 600 seconds |
| `--observe-resources` | 5 seconds | Normal pressure; CPU, memory percentage and existing swap are measured for the authorized observation | 180 seconds |

All policies require at least 20 GiB free disk, valid identity and telemetry,
the exclusive native lease and the existing 12 GiB build-cache ceiling before
boot. Reported free memory is the `memory_pressure -Q` metric, not literal
unused RAM. Observation and stable-swap flags are mutually exclusive.

Sampling targets a five-second cadence. A full snapshot has a 12-second deadline,
including an eight-second limit for `top`; under load that cadence is not
guaranteed. Critical OS memory pressure or low disk aborts immediately. Warning
pressure sustained for ten seconds also aborts. Default/stable policies additionally
abort after ten seconds below 25% reported free memory or 256 MiB swap growth,
or thirty seconds below 10% CPU idle. Observation records these numeric load
changes instead of treating them as established thresholds. Missing telemetry,
foreground cancellation/death or lost heartbeats still aborts. Boot is limited
to 120 seconds; the launch observation lasts 15 seconds.

For an already-built XCTest artifact, observation mode additionally accepts
`--test-run /absolute/Products/name.xctestrun` and either one fully qualified
`--test-selector Target/Class/testMethod` or `--test-manifest /absolute/preset.json`.
The manifest must equal one of the closed presets in `SimulatorTestBackend`:
eleven native playback/transport methods or the two embedded PDF/system-MP3
methods. Partial, mixed, duplicate and wildcard selections are rejected. The
runner uses `test-without-building`, one explicit destination, no parallel tests
and a tracked process group. The test command has at most 120 seconds within
the unchanged 180-second observation session. Test-run/manifest identities are
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
