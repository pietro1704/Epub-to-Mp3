# Execution policy

This is the current execution and delivery policy. Historical campaign entries
remain in Git history; dates and older permissions are not additional rules.
Current explicit user instructions take precedence. Read the relevant task
before executing it through `mise run`; use managed tools through `mise exec`.

## Scope and platforms

Preserve unrelated edits, app data, books, models, caches and evidence. Record
concrete requests and actual acceptance evidence in local `TODO_APP.md`; keep
session plans, handoffs and private instruction overlays out of published diffs.
Inspect branch/status and the relevant diff before implementation, except when
the user explicitly defers Git until a current app-validation journey ends.

Apple builds and app validation run on this Mac. Android/Samsung and Flutter
Linux builds, tests and generated artifacts belong on Arch. Android work remains
paused until the user resumes it. Separately authorized Mac and Arch work may
run concurrently; shared Rust has one named editing owner. Focused CLI/Web
checks may run on Mac; start Web tests with at most two workers. Python/Ruff
execution remains deferred to CI.

Use the smallest check that proves the requested behavior. Reuse artifacts only
after matching source, toolchain, lockfile, target and build flags. Explain a
necessary dependency rebuild before starting it. A narrow validation request
ends after its visible app journey and focused checks; expand only for a concrete
failure or unresolved acceptance condition.

## Apple toolchain

Use Xcode 16.4 for app development, builds and tests because this project
supports iOS 15.5. On this Mac its developer directory is
`/Applications/Xcode-16.4.0.app/Contents/Developer`; managed tasks select it
through `DEVELOPER_DIR` and `scripts/xcode_build_paths.rb`.

The system Command Line Tools selection uses Xcode 26 for terminal and
Homebrew compatibility. Preserve that selection; it does not select the app's
development toolchain. Use the explicit development environment for Apple work.

## Native safety

Every Mac compiler invocation, including bootstrap/interpreter compilation, uses
`scripts/native_job.rb build` through its guarded project task with one compiler
job. Its shared storage policy is `config/mac-build-budget.json`: at least
20 GiB free, at most 12 GiB of project build caches across linked worktrees,
checked every 10 seconds while running. Inspect `mise run build:storage` before
creating another cache. A refusal cannot be bypassed with direct compilers or
flags. `mise run clean:build` removes only superseded project DerivedData under
the shared lease; preserve usable artifacts and all user/evidence data. Changes
to enforcement require `mise run build:storage:test`.

Intel Simulator execution is quarantined after recurrent `SimMetalHost` /
`IGGuC.cpp:2913` kernel panics. `native_job.rb simulator` refuses before launch,
including inherited leases. Direct `simctl boot`, alternate launchers and
existing artifacts cannot bypass the gate. Re-enabling requires an explicit new
user safety decision and specialist review of the supervised resource/cleanup
harness. Compiling for Simulator does not authorize booting it. Required
SE1/iOS 15.5 acceptance remains blocked; a physical device or another runtime
cannot replace it. The native build guard verifies devices are shut down and
Simulator/SimMetalHost have exited before compiling.

Any new host kernel panic is a stop event: stop agent-started local/native and
resource-intensive work, preserve the report and execution evidence, and avoid
automatic retry, reboot or hardware/firmware changes. Continue only through
externally hosted tools that start no process on the affected host; otherwise
wait for the user to confirm stability. The separately reported ARM64/T8010
`x86 CPU CATERR detected` panic has no established agent-process cause. Guards
and monitoring establish neither a GPU-driver fix nor CATERR prevention.

## Real-app acceptance

Native macOS execution and physical iOS verification are authorized within the
requested task. Keep the shipping macOS GUI open, visible and frontmost during
validation so Pietro can watch normal flows. XCTest supplements the visible
journey. Retain screenshots/logs, source/build identity and observed results;
report runtime acceptance pending when the affected app was not exercised.
Host-tooling or documentation changes require their own focused checks, not an
unrelated app campaign. If the user explicitly chooses manual Xcode validation,
report that handoff as pending until their result is received.

Run one native app target at a time. Stop the previous app before switching;
keep Simulator quarantined. Close the app when active validation ends and verify
shutdown, except when the user requests its window remain open for review;
close it after that review ends. Audible checks show the app and identify any
deliberate non-Edge fixture audio before playback. Model downloads, service
changes and new benchmarks require their own task scope.

## Git and publication

Use one scoped feature branch from current `master` and one PR per coherent
change. Finish the authorized local checks and any requested real-app journey
before commit. Commit/push and PR creation are authorized by default for verified
scoped changes; incomplete work stays local. When the owned branch is behind
`origin/master`, preserve edits, fetch, rebase, resolve conflicts and rerun affected
checks. Publish a rebased branch with an explicit expected-tip `--force-with-lease`
and verify its remote tip; a failed lease requires reassessment.

The required pre-merge check is the exact-head `PR gate`; comprehensive validation
runs after merge and publishers require the integrated, validated SHA. A pending
optional check does not expand the pre-merge gate. All ready PRs targeting
`master`, from any author including forks, have standing user authorization for
automatic merge after successful exact-head CI and its required `PR gate`.
Keep repository auto-merge enabled and the `Merge eligible pull requests`
workflow active. It uses the trusted master merge helper to verify the current
head, up-to-date base and server protection before squash merging. Drafts,
conflicts, requested changes, stale bases and unverified heads remain blocked;
resolve the blocker and validate the new head before merging. Other targets
require task-specific authorization. `--auto` alone is not proof of deferred,
validated merging. Administrative bypass requires explicit approval for that PR.
Release, website/Hugging Face publication and issue closure retain their own
authorization boundaries.

CI monitoring is opt-in. Do not poll unrelated CI or infer monitoring permission
from PR creation. Report pending/unobserved results precisely. After an authorized
merge, verify the merge SHA, fast-forward local `master`, and delete only branches
confirmed integrated, preserving concurrent work and private overlays. When the
requested final state is master-only, verify local and remote branch inventories.
