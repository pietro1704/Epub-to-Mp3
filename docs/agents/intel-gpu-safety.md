# Intel GPU safety and GitHub-only validation

Execution override2026-10-16: all tests/CI are GitHub-only. Local inspection
and implementation may continue; the native build procedure below describes
guards and future authorized execution, not permission to run local tests now.
Read GitHub results periodically and repair actionable failures; merge only
exact-head-green PRs, then remove confirmed-merged branches, leaving master.

### Highest-priority recurrent GPU panic: Intel Simulator quarantine

The user supplied recurrent2026-10-15/16 `IGGuC.cpp:2913` workqueue41 panics
in `AppleIntelKBLGraphics` and `SimMetalHost` for iPhone SE1 on MacBookPro15,2,
macOS24H32. Compressor/swap were OK. The excerpt identifies a graphics-driver
failure path, not general RAM/disk exhaustion or proven build concurrency.
Build/Simulator phase separation alone did not establish prevention.

1. Keep Intel Simulator execution quarantined. `native_job.rb simulator`
   refuses before any child, including inherited leases. Direct `simctl boot`,
   GUI launch, existing artifacts, environment flags or another target cannot
   bypass this policy. Re-enabling requires a new explicit user safety decision
   and specialist review; prior campaign authorization is not a safety reset.
2. Close the tested app, shut down already-active devices and quit Simulator.app.
   Confirm all devices Shutdown and both Simulator.app/SimMetalHost absent.
   Preserve books, models, progress and devices; shutdown is not erasure.
3. Continue independent read-only/host work. For authorized native compilation,
   use `native_job.rb build`: the shared lease is acquired before checking all
   device states and both GPU/UI processes. Inspection failure blocks the child.
   Guard the first Swift interpreter/bootstrap as well as the final compiler.
   Use one job. Edit/Stop hooks only notify; they start no native compilation.
4. Keep the required SE1/iOS15.5 acceptance visibly blocked; a host test, physical
   device or different runtime cannot satisfy it. Preserve screenshots/reports
   from earlier runs as historical evidence. Never claim GPU stability from
   host guard tests. Native macOS runtime/physical-device actions retain their
   own task authorization and data-preservation rules.
5. Before any future approved Simulator execution, design a bounded session
   whose owned-app/device cleanup runs on success, failure and cancellation,
   while the shared lease remains held; confirm shutdown and renderer exit.
   Build-for-testing must precede boot, then test-without-building against
   matching artifacts, Xcode16.4 and the exact SE1/iOS15.5 destination.

These are cooperative harness controls, not OS-wide interception or a verified
GPU driver fix. External tools can bypass repository wrappers; agents must not
use those paths. Do not reproduce the panic, stress the GPU, change renderer or
driver defaults, erase devices, restart services or install runtimes as an
implicit workaround. If safety inspection is inconclusive, preserve evidence
and continue independent work rather than retrying native graphics execution.
