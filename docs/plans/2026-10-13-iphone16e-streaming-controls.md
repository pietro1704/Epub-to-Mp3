# iPhone 16e streaming, download and controls verification

## Scope and acceptance

Exercise the actual iPhone 16e app with fresh Edge-first synthesis. Measure time
to playable audio and verify playback starts before conversion completes.
Verify persisted playable download and pause/resume, next/previous controls.
Record observed errors, apply goal-plan-execute to minimal fixes and rerun the
affected real-device checks. Readiness failures are blockers, not app failures.

## Boundaries and risks

Preserve existing working flows, imported books, audio and dirty worktree changes.
No provider/model replacement without comparable runtime evidence; Piper remains
suspended. Use isolated test fixtures and at most two chapters per conversion
benchmark. No whole-book synthesis, repository-wide refactoring or CI monitoring.
Physical readiness and signing may block execution; verify these before builds.

## Execution

1. Inspect contract, UI/state and verification tooling in specialist passes.
2. Check real-device readiness; serialize native work and stop other targets.
3. Run existing actual Edge/player and focused control/download checks; add only
   missing runtime coverage necessary to exercise the user's acceptance.
4. List observed errors with evidence, implement minimal fixes at their seams,
   add regression tests and repeat the affected physical-device checks.
5. Audit final diff and report measurements, executed checks and unresolved limits.

## Evidence and observed errors

Physical-device execution is pending. No app error established yet.

- Initial readiness passed on the actual iPhone 16e, CoreDevice ID
  `44B2CFBD-2193-5086-8E8D-BF7A2876C321`, hardware UDID
  `00008140-001128A022BA801C`, Developer Mode enabled.
- First execution was rejected before device preparation by the host load guard.
  The SE Simulator was terminated and shut down; host load subsequently dropped.
- Second execution found the phone automatically locked (`passcodeRequired=true`)
  and stopped before build/install/test. Evidence:
  `.reports/device/30D81C82-F0E5-4803-BDAD-52FF43F8513B/report.json`.
  User unlock request is pending; no repeated launch/readiness polling.
- Prepared dedicated fresh two-chapter EPUB `/tmp/EpubToMp3DeviceStreaming.epub`;
  ZIP integrity passed, unique identifier `f0eab9c6-f63a-47ff-9d36-3a65ccd3e1ec`.
  It has not been installed on the phone.
- Added focused opt-in native and GUI tests, actual playback-latency attachment,
  retained-download/local-playback checks, and corrected test evidence/state
  preservation found during adversarial review. Scoped whitespace checks passed.
  These additions have not been compiled or executed; they are not runtime proof.

## Current error list

1. Verification blocker: physical phone automatically locked before execution.
2. Verification blocker, resolved locally: host load initially exceeded the guard.
3. App errors: none established because requested physical runtime checks have
   not executed. Do not report unexecuted test coverage as an app repair.
