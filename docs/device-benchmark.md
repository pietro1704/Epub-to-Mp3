# Physical-device benchmark

Use this for a requested Apple conversion benchmark. The product uses embedded
Rust; the native Swift host tool orchestrates Apple tooling and never synthesizes.
Local execution uses Swift and shell only. Python/Ruff checks belong in CI.

## Explicit scope

Run one command with each EPUB and zero-based inclusive range:

```sh
mise run ios:device:benchmark -- --device DEVICE_ID \
  --case '/absolute/path/first.epub' 8 9 \
  --case '/absolute/path/second.epub' 6 7
```

Each book may select one or two chapters. An omitted book/range, duplicate book
(including hard links and copies with the same SHA-256),
negative/mixed sentinel, reversed range or more than two chapters is rejected
before any device query. `--preview` validates/displays scope without device
actions. Whole-book synthesis requires both `--whole-book` and explicit `-1 -1`
bounds for that case; the flag does not permit arbitrary oversized ranges.
Native XCTest validates every case and metadata bound before the first TTS call.

## One execution path

The benchmark shares the `ios:device:test` orchestration. It checks connection,
unlocked state, Developer Mode and hardware UDID before preparation. A locked
device returns an actionable terminal report immediately, with no build/test.
Readiness is checked again after preparation because the device may auto-lock.
It never queues indefinite launch retries or silently falls back to Simulator.

Builds reuse `ios/EpubToMp3/.build`; heavy build/test work uses the existing
native resource guard and holds the shared exclusive-job lock through preparation,
transfer, testing, collection and cleanup. `--skip-build` explicitly reuses an existing
compatible artifact. Signing identity, provisioning and embedded Rust ABI/
architecture/platform are verified before installation or test execution.
The previous app process is terminated by its exact executable/PID.

Each run stages copies of the requested inputs in a UUID-owned device directory
and selects one test in a generated `.xctestrun`. Its environment carries the
JSON specification. Checked-in schemes/plans are never edited. XCTest checks
terminal completion, exact source indices, AVFoundation playability and positive
audio duration. XCTest removes its app-owned input copies and fresh output
directories; the host empties its exact UUID staging directory using CoreDevice.
The report identifies whether the service retained an empty staging directory.
JSON evidence, imported books and existing audio stay intact.

## Evidence and resumption

```sh
mise run ios:device:preflight -- --device DEVICE_ID
mise run ios:device:status
mise run ios:device:workflow:test
mise run preflight -- --scope device-workflow
```

Reports live in `.reports/device/RUN_ID/`; `latest.json` is the checkpoint.
Atomic checkpoints synchronize the file and parent directory before returning.
The compact status reads that checkpoint and checks the recorded local process
identity once; it does not query the phone. A lease prevents overlapping device
workflows. A live process is observed rather than restarted. A missing handle
requires inspecting its log/xcresult before an explicit retry. Recheck external
readiness after user input or changed evidence, not on automatic continuations
with unchanged state. No CI or PR monitoring is part of these commands.

`report.json` records total wall time, preflight, build, transfer, test wall time,
collection, synthesis and verification separately. Device wait is zero because
readiness fails immediately. Native synthesis/verification are intervals inside
test wall time, so do not add them to total wall time. The build interval includes
resource-guard overhead; other preparation steps retain their own durations.

`native-report.json` and a permanent XCTest attachment contain per-book requested/
completed chapters, characters, audio duration, per-chunk chars/s and adaptive
profile metrics, retry/pressure events, explicit throttles and cache state.
If device retrieval fails after a run, the host recovers the report from local
XCTest attachments without requiring another unlock or synthesis attempt.
Fresh job IDs prove no audio reuse; parsed-text cache reuse is reported as
`not_measured`, not falsely claimed absent. A skipped test, reused audio, different
range/provider, or missing report is not evidence of synthesis speed.
Only a passed xcresult with exactly one executed benchmark and matching native
evidence establishes success. Report failures and partial evidence as such.

SwiftPM host regression tests execute scope, process, reporting, and mocked Apple-tool
routing. Native scope/telemetry unit tests run offline in
`DeviceConversionBenchmarkTests`; the opt-in test alone performs synthesis.
Keep these beside their runtimes; no Python test reads Swift source.
Retain meaningful reports and at most one useful build cache; remove inactive
build trees with the existing cleanup task after verification when appropriate.
