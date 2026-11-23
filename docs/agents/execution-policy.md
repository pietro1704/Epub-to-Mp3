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

This Mac is for the Apple ecosystem only (macOS, iOS, iPadOS and their tooling):
Apple builds and app validation run here. Everything Flutter (Windows, Linux and
Android/Samsung) builds, tests and generates artifacts on Arch or in GitHub CI,
never on this Mac: do not install or run the Flutter/Dart SDK, Gradle/Android
tooling or a Windows toolchain here. A Flutter edit made on this Mac is validated
by Arch or CI, and reading a CI log is not running that platform locally.
Android work remains paused until the user resumes it. Separately authorized Mac
and Arch work may run concurrently; shared Rust has one named editing owner. Focused CLI/Web
checks may run on Mac; start Web tests with at most two workers. Host scripts are
Ruby; their fixture-only host tests may run on Mac.

Use the smallest check that proves the requested behavior. Reuse artifacts only
after matching source, toolchain, lockfile, target and build flags. Explain a
necessary dependency rebuild before starting it. First audit verified retained
packages in linked worktrees and trusted producer artifacts on GitHub. Retain
the complete authenticated package and receipt outside disposable download
staging; revalidate source/build identity and payload on every reuse. Swift or
documentation changes alone do not require rebuilding an unchanged Rust runtime.
For dependencies, runtimes, libraries and tools, including Piper, first reuse
verified local artifacts or find compatible binaries from trusted publishers.
Verify source, platform and architecture. Pietro does not supply these binaries;
do not ask him whether one exists or request confirmation to compile when no
suitable artifact is available. Build through the guarded project tasks within
the authorized scope, preserving immutable model artifacts.
Final application targets such as EpubToMp3 may also be built within that scope.
A narrow validation request ends after its visible app journey
and focused checks; expand only for a concrete failure or unresolved acceptance
condition.

## Apple toolchain

Use Xcode 26.3 for the physical iPhone 16e by default, as explicitly requested
by Pietro. Set `IOS_DEVICE_ID=44B2CFBD-2193-5086-8E8D-BF7A2876C321` before
invoking managed device build, run or test commands; `scripts/xcode_build_paths.rb`
then selects `/Applications/Xcode-26.3.0.app/Contents/Developer`. This is a
persistent device-specific choice. Reuse the verified iOS Rust package when its
source/build inputs match; selecting the app toolchain does not authorize a
dependency rebuild, runtime download or Simulator execution.

Required reader Simulator acceptance uses iPhone SE (1st generation), iOS 15.2
and Xcode 26.3, as explicitly selected by Pietro on 2026-11-05. Since 2026-11-23,
any SE1 run (boot, install or test) needs Pietro's explicit permission for that
run and happens only while he is actively using the Mac, because it can crash
the host. Without it, record the SE1 part as a question for Pietro and accept
on macOS meanwhile. The Arch host, the Galaxy A8 and the Galaxy tablet (SM_X620)
stay powered with the Mac. Use them freely for Android, tablet, Linux and
Windows checks; adb reaches them from the Arch host outside ai-jail. Keep only the
iOS 15.2 and 26.2 runtimes. macOS builds may retain Xcode 16.4 through
`DEVELOPER_DIR` and `scripts/xcode_build_paths.rb`; preserve that installed
toolchain without changing the global selection.

The system Command Line Tools selection uses Xcode 26.3 for terminal and
Homebrew compatibility. Preserve that selection. `DEVELOPER_DIR` overrides it
inside a project command; inspect the global selection with
`env -u DEVELOPER_DIR xcode-select -p` when distinguishing the two.

## Native safety

Pietro ordered on 2026-11-22 ("remova todos os guards. pode deixar isso
definitivo") that every native host guard on this Mac (Intel i5-8259U, 8 GiB) be
removed, permanently. Host load, memory pressure, thermal limits, foreign
compilers, swap, the compressor, free-space floors and Simulator/SimMetalHost
state no longer refuse, delay or stop any native job, and the former Intel
Simulator quarantine no longer exists. They remain readings: they are written to
the job's log and to the flight recorder as notes ("advisory, not a refusal"),
and never change an exit status.

What remains is correctness, not host protection:

- Every Mac compiler invocation still goes through `scripts/native_job.rb build`
  (or the task wrapper that calls it) with one compiler job by default
  (`CARGO_BUILD_JOBS` and `CMAKE_BUILD_PARALLEL_LEVEL` are set to 1 off GitHub-hosted
  runners). The default is not enforced: an explicit `-j`/`--jobs` flag is not
  refused.
- One host lease, `/tmp/epub2mp3.heavy-job.lock`, serializes jobs that write the
  same DerivedData, Cargo target, `.build` and ONNX Runtime trees for all
  worktrees and sessions: compiler, Simulator and heavy host-suite jobs. It stays
  because two writers in one output tree corrupt or lock each other (Xcode's build
  database, CMake trees, packaging output), not to protect the host. A busy lease
  is the only refusal left (exit 75); `--wait SECONDS` or
  `EPUB_NATIVE_WAIT_SECONDS` (whole seconds; any other value fails) queues for it,
  and never poll it in a loop. Every job keeps the lease's open file description,
  so the lock lasts as long as the load does. `mise run native:status` prints the
  holder record (PID, phase, state, program, task, start, checkout, session, job
  process group; never arguments or paths), the processes that keep the file open
  and one host reading with its notes; it never takes the lock. A reboot empties
  `/tmp` and the next job recreates the file.
- `config/mac-build-budget.json` holds the advisory thresholds and the readings
  behind them (`advisory`), and `warn_free_gib` (5). `mise run build:storage --
  /path/to/output` prints the free-space note for a destination. `mise run
  clean:build` still removes only superseded Mac DerivedData and still refuses
  while a job holds the lease or a compiler runs, because deleting a cache under a
  running build corrupts it. Keep compatible caches across worktrees. Verify with
  `mise run build:storage:test`.
- Children start at niceness 10 (a judgment call, not measured). While a job
  runs, one line every 30 seconds (load, swap, compressor, memory pressure,
  thermal limits, notes, top three processes by CPU, the holder) goes to
  `.reports/native-flight-recorder/flight.jsonl` in the main checkout, at most
  five files of 1 MiB, readable by their owner only and without arguments or
  absolute paths. The first line of a job records boot time, the EFI
  `StartupPowerEvents` value and the newest panic report, the baseline a later
  incident is compared with.
- Simulator work runs through `native_job.rb simulator` or the
  `ios:simulator:supervised` session in [Simulator safety](../simulator-safety.md).
  The session keeps its own bounds (identity checks, heartbeat, stage and session
  deadlines, verified shutdown) and records resource readings as notes.

The host had an x86 CPU CATERR on 2026-11-19 (history below) and recurrent
`SimMetalHost` / `IGGuC.cpp:2913` kernel panics before that. The removed guards
were never proven to prevent either, and removing them is not proven to cause
more. Neutrally: that risk is now accepted by Pietro. After any new host kernel
panic, report it, preserve the Apple report and execution evidence (copy them out
of `/tmp` first) and say which jobs ran before it. Stopping other work is
recommended, not enforced; the flight log and `mise run native:status` give the
state.

Operational pitfalls observed in the November 2026 campaign:

- Run supervisors and host tools with the managed Ruby from mise. macOS system
  Ruby 2.6 lacks `filter_map` and fails before boot.
- Keep queue variables such as `EPUB_NATIVE_WAIT_SECONDS` on the outer guard
  only; fixtures that inherit them time out.
- After a second identical lease refusal, diagnose the holder with
  `mise run native:status` instead of queueing the same attempt again.
- Report disk from `df` or `diskutil`. Finder counts purgeable space. A
  supervised SE1 run consumed about 3 GiB.
- When storage is low, the agent may prune only reproducible caches under the
  lease and must verify retained artifact hashes before and after.
- A locked 16e never aborts a device run. The workflow polls `lockState` every
  5 s (at preflight and again before the test step) for up to
  `DEVICE_UNLOCK_WAIT_SECONDS` (default 1800), prints one
  `WAITING_FOR_UNLOCK device=<id> since=<UTC>` line to stderr, reports
  `waiting_for_unlock`, and continues by itself once the device unlocks; only
  the timeout marks the run `blocked`. When that line appears, alert Pietro once;
  do not relaunch. Run the command in the background, not under `nohup` or `&`.
  The device unified log requires root (exit 77); record it as unobservable.

### Host incident of 2026-11-19 21:35 BRT (2026-11-20 00:35 UTC): x86 CPU CATERR

Each time below is BRT (UTC-3) on 2026-11-19 followed by UTC; from 21:00 BRT on,
the UTC date is 2026-11-20. Established from the Apple report, the unified log
and session transcripts (retained in the local incident evidence directory, not
in Git):

- The Apple report is stamped 21:35:04 BRT (00:35:04 UTC). The T2's own clock in
  it reads 21:34:29 BRT (00:34:29 UTC) for `x86 CPU CATERR detected`. There is
  no macOS panic log; the report describes bridgeOS only and names no macOS
  process.
- The last persisted macOS activity is 21:33:34 BRT (00:33:34 UTC). No
  thermal-pressure change was logged after 21:12:14 BRT (00:12:14 UTC) and no
  memory-pressure event after 20:53 BRT (23:53 UTC); the kernel log of the last
  seven minutes shows no storage or driver error.
- No native build was running. The last guarded job, a full Mac test suite,
  ended at 21:10:31 BRT (00:10:31 UTC); an iOS build started at 21:11:14 BRT
  (00:11:14 UTC) exited with an error after 1.7 seconds and its watcher did not
  notice. OS thermal pressure was Nominal from 21:12:14 BRT (00:12:14 UTC) on.
  Its only Heavy reading after 20:30 BRT (23:30 UTC), at 21:00:06 BRT (00:00:06
  UTC), fell while a complete host contract suite from another session
  overlapped the Rust step of a guarded Mac test run.
- The next boot, at 21:36:22 BRT (00:36:22 UTC), logged
  `Previous shutdown cause: -63` and EFI `StartupPowerEvents 0x4f` (PWROK,
  SYS_PWROK, THRMTRIP#, SYS_RESET#, general reset). No earlier boot is retained
  for comparison, so the THRMTRIP# flag is not attributed.
- The T2 report of 2026-11-18 20:03 BRT (23:03 UTC) was a forced power-off after
  a stalled shutdown, not a CATERR.
- A report with the same panic string was supplied on 2026-10-16. It is no
  longer retained on this host; the two reports were not compared, so a
  recurrence is unconfirmed. `ARM64/T8010` in such a report is the T2 chip that
  writes it on an Intel Mac, not a second machine.

Not established: any cause. Hardware or firmware (logic board, CPU, power
delivery, battery), a thermal trip and a driver fault all remain open; the load
of the campaign is not shown to be the cause, and no guard is shown to prevent
another CATERR.

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
use the reviewed route for authorized Simulator work. Close the app when active
validation ends and verify shutdown, except when the user requests its window remain open for review;
close it after that review ends. Audible checks show the app and identify any
deliberate non-Edge fixture audio before playback. Model downloads, service
changes and new benchmarks require their own task scope.

Evidence captured in the real app uses isolated test data: settings, library,
imported books, caches and reading state. It never imports into or changes the
real installation. Several running copies of the app, or a copy left open after
the check, count as a policy failure: check with `pgrep` after each use.

Code that runs only on iOS (UIKit presentation, `#if os(iOS)` paths, alerts and
action sheets) needs an iOS execution before its PR is opened ready. macOS tests
plus an iOS compile do not cover it. On 2026-11-23, #1353 passed that evidence
and crashed on the iPhone 16e at the first tap, because UIKit rejects two cancel
actions. Until a CI simulator job exists, keep such changes on a branch and add
them to the device plan.

Attach the visual evidence for a visible change before opening its PR ready,
because ready PRs merge automatically.

Every bug Pietro reports gets a regression test written first. Run it and show
it failing while the bug is present; then fix the code and show the same,
unchanged test passing. Record both runs in the PR.

Before each push, run the checks CI will run:
- Rust: `cargo fmt --all -- --check`, `cargo test --workspace --locked`, and
  `cargo check -p converter-core --target wasm32-unknown-unknown` when the core
  changes.
- Swift: add each new production or test file to the explicit lists in
  `ios/EpubToMp3/Package.swift`, then run the package build.

## Git and publication

Use one feature branch and one PR per coherent change. Start independent changes
from current `master` and continue them while earlier PRs are open.

Never open or leave a PR in draft. Open every PR ready, with squash auto-merge
enabled; work that is not ready to merge stays local on its branch. A draft is
never the way to mark a dependent or unfinished change.

For a dependent change, use GitHub's native Stacked PRs (preview) through the
official `gh stack` extension (`gh extension install github/gh-stack`; update
with `gh extension upgrade stack`; requires `gh` 2.0+ and Git 2.36+). The bottom
PR targets `master` and each PR above it targets the branch below, so a reviewer
sees only that layer's diff. Typical loop: `gh stack init` (or `init <branches>`
to adopt existing branches), commit, `gh stack add <branch>` for the next layer,
`gh stack submit --open` to push every branch atomically and create the PRs as
ready (`submit --auto` creates drafts unless `--open` is passed, and the editor's
default for new PRs is ready, so never toggle draft). After editing a lower
layer run `gh stack rebase`, then `gh stack push`. After a lower PR merges,
`gh stack sync --prune` fetches, fast-forwards the trunk, rebases the remaining
layers (it switches to `--onto` mode for a merged PR, which handles the squash
merge) and pushes with `--force-with-lease`. `gh stack merge [<pr-number>]`
merges everything up to a PR atomically; it checks only that the PRs are open
and not draft, GitHub still enforces branch protection, and a merge queue takes
over the merge method. Record in each description the prerequisite PR and its
exact head SHA and keep that SHA current when restacking.

Observed on this repository (first real use, 2026-11-18): `gh stack init
<branches>` adopts existing branches locally, and `gh stack submit --auto --open`
pushes atomically and creates ready PRs with the right base; the stack was
created as a PR on `master`. Two things to know. `submit` is rejected as a stale
atomic push if a branch of the stack changed on the remote after your last
fetch (for example a merge-refresh of the PR), so fetch first. `gh stack sync`
after the bottom PR was squash-merged tried to rebase the merged bottom branch
onto `master` and conflicted (the stack had never been submitted, so it did not
know the PR had merged); the branches were restored unchanged. When that
happens, run `gh stack unstack --local`, transplant the remaining layers with
`git rebase --onto origin/master <merged-bottom-branch> <top-branch>`, then
`gh stack init` and `gh stack submit --auto --open` again. Still unverified: a
stack of two or more open PRs submitted together, whether the required `PR gate`
and the `Merge eligible pull requests` workflow merge a layer whose base is not
`master`, and `gh stack sync` after a bottom PR of a submitted stack merges. The
standing automatic-merge authorization covers ready PRs that target `master`;
any other target needs task-specific authorization. Update this paragraph after
each of those is observed. If `gh stack` is unavailable, keep the dependent
change local until its prerequisite merges, then branch from current `master`
(transplant the child-only commits using the recorded base SHA when the work
already exists), review the resulting diff, rerun affected checks and open the
PR ready. The updated head must pass its own required CI before merging. A hold
or explicit acceptance requirement still applies to the change it covers.

Finish the authorized local checks and any requested real-app journey before
commit. Commit/push and PR creation are authorized by default for verified
scoped changes; incomplete work stays local. When the owned branch is behind
`origin/master`, preserve edits, fetch, rebase, resolve conflicts and rerun affected
checks. Publish a rebased branch with an explicit expected-tip `--force-with-lease`
and verify its remote tip; a failed lease requires reassessment.

The required pre-merge check is the exact-head `PR gate`; comprehensive validation
runs after merge and publishers require the integrated, validated SHA. A pending
optional check does not expand the pre-merge gate. All ready PRs targeting
`master`, from any author including forks, have standing user authorization for
automatic merge after successful exact-head CI and its required `PR gate`.
Enable squash auto-merge on every ready PR targeting `master` when opening it
or marking it ready, regardless of author or task. Keep it enabled while the
required checks run; any user request to hold a particular PR takes precedence.
Branch protection on `master` does not require an up-to-date base: the owner
turned the `strict` setting off on 2026-11-19, because every merge sent the next
PR back through the 10-18 minute Apple job. A PR merges as soon as its own
exact-head `PR gate` passes. Two PRs that pass separately can still break the
integrated result; post-merge validation is the check for that, and publishers
require its validated SHA. So post-merge validation must stay reliable: a red or
stale validation blocks publication and is fixed before new work piles up on it.
The merge workflow's refresh of behind PRs only applies if the setting is turned
back on.
Keep repository auto-merge enabled and the `Merge eligible pull requests`
workflow active. It uses the trusted master merge helper to verify the current
head, mergeability and server protection before squash merging. Drafts,
conflicts, requested changes and unverified heads remain blocked;
resolve the blocker and validate the new head before merging. Other targets
require task-specific authorization. `--auto` alone is not proof of deferred,
validated merging. Administrative bypass requires explicit approval for that PR.
Release, website/Hugging Face publication and issue closure retain their own
authorization boundaries.
The merge workflow merges any ready PR whose gate passed, even with auto-merge
off; to hold work, keep it on a pushed branch without a PR. The PR gate builds
the macOS app only, so a change to `#if os(iOS)` code needs a guarded local iOS
`build-for-testing` before its PR. After a rebase, earlier test results carry
over without a rerun only when `git patch-id --stable` or the tested subtree
bytes are unchanged; record that identity with the evidence.

Continue available work while GitHub CI and merges run. Inspect relevant PR
state and CI in one bounded pass in response to a new message from Pietro, then
defer further status queries until his next message.
A push, PR creation, elapsed time, local task completion or CI notification does
not authorize another query. Keep protected automatic merge active and report
pending/unobserved results precisely. When a user-triggered inspection confirms
an authorized merge, verify its SHA and ancestry, fast-forward local `master`,
and delete only branches confirmed integrated, preserving concurrent work and
private overlays. When the requested final state is master-only, verify local
and remote branch inventories during that user-triggered inspection.
