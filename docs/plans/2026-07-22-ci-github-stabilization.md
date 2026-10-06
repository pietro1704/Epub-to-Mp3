# CI/GitHub Stabilization Implementation Plan

> For Hermes: execute with specialist subagents, then run the full verification gates.

Goal: restore trustworthy CI and release builds by fixing the localization source-of-truth drift, validating all affected Flutter targets, and separating real failures from noisy automation.

Architecture: keep Flutter localization generated from `flutter_app/lib/l10n/app_*.arb`; never hand-edit generated Dart as the only fix. Add a regression test that exercises the generated localization contract and make the release workflow use the same deterministic generation/build path. Review automation separately so diagnostics and auto-fix jobs do not hide failures.

Evidence gathered live:
- GitHub Release Desktop run 29889790069 failed in Android, Linux Flutter, and Windows Flutter; SwiftUI Apple and Docker passed.
- All three Flutter failures report `lib/screens/root_screen.dart:58:22`: `AppLocalizations` has no getter `convertTitle`.
- The checked-in generated Dart currently contains `convertTitle`, but `app_en.arb`, `app_pt.arb`, and `app_es.arb` do not. `flutter pub get` regenerates localization and removes the manually retained getter, explaining why local source inspection can look healthy while CI fails.
- GitHub CI run 29889426441 passed; this failure is release-only and is caused by the release workflow building Flutter after generation.
- The release run checks out `master` for tag `v0.5.8` (`RELEASE_REF: master`), so rolling release builds can expose current master drift independently of the tag.

## Task 1: Restore localization source of truth

Files:
- Modify: `flutter_app/lib/l10n/app_en.arb`
- Modify: `flutter_app/lib/l10n/app_pt.arb`
- Modify: `flutter_app/lib/l10n/app_es.arb`
- Regenerate: `flutter_app/lib/l10n/app_localizations*.dart`
- Test: `flutter_app/test/root_screen_test.dart` or a focused localization contract test

Steps:
1. Add `convertTitle` to all three ARB files with the existing translations (`Convert`, `Converter`, `Convertir`).
2. Run Flutter localization generation using the repository's pinned Flutter toolchain.
3. Verify the generated abstract class and all locale subclasses expose the getter.
4. Add/update a test proving the RootScreen renders the Convert destination after generation.
5. Run the focused Flutter test and `flutter analyze`.

Acceptance: `flutter pub get` followed by generation/build does not remove `convertTitle`; Android, Linux, and Windows compile past `root_screen.dart:58`.

## Task 2: Add early Flutter coverage to CI

Files:
- Modify: `.github/workflows/ci.yml`

Steps:
1. Add a dedicated Flutter job using the pinned `mise.toml` SDK.
2. Run the complete Flutter test suite and analyzer before release workflows.
3. Keep the job read-only and independent from Python/Web caches.

Acceptance: a missing generated localization getter fails the normal CI workflow instead of being discovered only during release.

## Task 3: Validate release/build matrix

Files:
- Inspect/modify only if needed: `.github/workflows/release-desktop.yml`
- Test/build: Flutter app and relevant workflow YAML

Steps:
1. Run the pinned local Flutter tests and analyzer through `mise exec -- flutter ...`.
2. Run a release-equivalent build where supported locally; do not boot iOS Simulator on this Intel Mac.
3. Ensure generated files are reproducible after `flutter pub get`.
4. Check workflow paths and artifact globs against actual build outputs.
5. Trigger a controlled GitHub workflow only after local gates pass; monitor every job and inspect failures instead of blind reruns.

Acceptance: Flutter tests/analyzer/build-equivalent pass locally; GitHub Release Desktop has green Android, Linux, Windows, SwiftUI, and Docker jobs.

## Task 3: Reduce CI/GitHub noise without masking defects

Files:
- Inspect: `.github/workflows/ci-failure-diagnose.yml`
- Inspect: `.github/workflows/auto-fix.yml`
- Inspect: `.github/workflows/auto-release.yml`
- Inspect: `.github/workflows/sync-hf.yml`

Steps:
1. Confirm which jobs are informational (`continue-on-error`) versus release blockers.
2. Ensure failure diagnostics preserve the actual failing conclusion and include the failing job/step, not only truncated tail output.
3. Ensure auto-fix never commits/pushes an unverified patch and cannot turn a red required check green.
4. Fix only evidence-backed workflow defects; do not weaken required checks.
5. Add workflow validation or shell tests where the repository already has a convention.

Acceptance: red release/build checks remain visible and actionable; automation does not create false green states or duplicate misleading issue noise.

## Specialist prompts

### Flutter localization specialist

Audit the Flutter localization pipeline in this repository. Reproduce the CI error `AppLocalizations.convertTitle` missing after `flutter pub get`. Treat `flutter_app/lib/l10n/app_*.arb` as the source of truth, regenerate generated Dart, add/update a regression test, and run pinned Flutter tests/analyzer/build-equivalent. Modify only needed files, do not change unrelated UI behavior, and return exact paths, commands, and verification results.

### GitHub Actions/release specialist

Audit `.github/workflows/release-desktop.yml` and the latest failed Release Desktop run. Verify every failed job against its log, identify root causes versus symptoms, and inspect checkout refs, localization generation, artifact paths, permissions, and failure masking. After the Flutter source fix is present, make only evidence-backed workflow corrections, add tests/validation if applicable, and report job URLs plus green/red verification. Never weaken required checks or claim success without live GitHub evidence.

### Independent reviewer

Review the complete CI stabilization diff against this plan. First check specification compliance: ARB source files contain every key consumed by RootScreen and generated Dart is reproducible. Then check quality: no generated-source drift, no weakened CI gates, no unrelated changes, tests cover the regression, and release artifacts/paths remain correct. Return PASS or precise blocking changes.

## Final gates

- `mise run test`
- `mise exec -- flutter test` from `flutter_app`
- `mise exec -- flutter analyze` from `flutter_app`
- `git diff --check`
- `git status --short --branch`
- GitHub Actions run status and URLs after push/dispatch, if a remote run is started
