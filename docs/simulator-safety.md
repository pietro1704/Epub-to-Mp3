# Supervised Intel Simulator sessions

The legacy `native_job.rb simulator` route remains quarantined. Only an explicitly
risk-acknowledged session uses `mise run ios:simulator:supervised`. Monitoring does
not prevent the Intel GPU-driver kernel panics previously observed on this host.

The dedicated route requires installed Xcode 16.4, an available x86_64 iOS 15.0
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

A 60-second admission baseline requires normal memory pressure, at least 40%
reported free memory, at most 1 GiB swap, unchanged swapout count, at least 70%
aggregate CPU idle, and 20 GiB free disk. The existing 12 GiB build-cache ceiling
is checked before boot. The memory percentage is the `memory_pressure -Q` metric,
not literal unused RAM. Missing telemetry refuses execution.

During boot and the 15-second launch smoke, resources are sampled every five
seconds, with a four-second collection deadline. Critical pressure or low disk
aborts immediately. Warning pressure, reported free memory below 25%, or swap
growth of 256 MiB abort after ten seconds; CPU idle below 10% aborts after thirty.
Boot has a 120-second budget and the whole session a ten-minute budget.

A detached watchdog owns the native lease, subprocesses and cleanup. The foreground
sends heartbeats; cancellation, foreground death, stale heartbeat, failed commands,
resource refusal and timeouts all lead to cleanup after any boot attempt. Cleanup
shuts down only the explicit device and terminates only the unreaped Simulator UI
child it owns. It verifies Shutdown and absence of Simulator/SimMetalHost processes
within thirty seconds. Failure is retained in the report and is never success.

The smoke proves only that install/launch commands completed and cleanup was
verified. It is not reader, playback, GPU stability or iOS 15.5 acceptance.

Host regressions (no Simulator or compilation):

```sh
mise run ios:simulator:safety:test
```
