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
the authorized scope, preserving resource guards and immutable model artifacts.
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
and Xcode 26.3, as explicitly selected by Pietro on 2026-11-05. Keep only the
iOS 15.2 and 26.2 runtimes. macOS builds may retain Xcode 16.4 through
`DEVELOPER_DIR` and `scripts/xcode_build_paths.rb`; preserve that installed
toolchain without changing the global selection.

The system Command Line Tools selection uses Xcode 26.3 for terminal and
Homebrew compatibility. Preserve that selection. `DEVELOPER_DIR` overrides it
inside a project command; inspect the global selection with
`env -u DEVELOPER_DIR xcode-select -p` when distinguishing the two.

## Native safety

Every Mac compiler invocation, including bootstrap/interpreter compilation, uses
`scripts/native_job.rb build` through its guarded project task with one compiler
job. Mac and Arch use the free-space floor in `config/mac-build-budget.json`
on the volume receiving build outputs (20 GiB by default). Check the
destination with `mise run build:storage -- /path/to/output`. The supervisor
rechecks available space every 10 seconds. A storage refusal requires restoring
free space or selecting a build volume with enough capacity. Keep compatible
caches across worktrees. When cleanup is needed, `mise run clean:build` removes only superseded Mac DerivedData
under the shared lease. Verify changes with `mise run build:storage:test`.

One host lease, `/tmp/epub2mp3.heavy-job.lock`, serializes every heavy class for
all worktrees and sessions: compiler and Simulator jobs, and on macOS the Rails
web suite with its Chromium system tests (`mise run rails:web:test`) and the
complete host suites (`scripts/run_ci_contracts.rb`, and
`scripts/run_host_checks.rb` without `--suite`), which run as
`native_job.rb heavy`. One selected host suite stays outside the lease. Every
job keeps the lease's open file description in its own processes, so the lock
lasts as long as the load does: if a supervisor is killed, the next job is
refused until that orphaned load ends. The cost: a process that leaves the job's
process group with that description (a browser, a daemon) keeps the lease after
the job. Two things bound it. The Rails task starts its test runners through
`scripts/without_native_lease.rb`, so they and the browsers they launch never
hold the lease; there it follows the shell that runs the suite, not each test
process. And a lease refusal and `mise run native:status` list the processes
that keep the lease file open (PID and program name), so a leftover holder is
named and can be stopped.

While held, the file (mode 0600) names its holder: PID, phase, state, program
name, mise task, start, checkout directory name, session and job process group,
never arguments or absolute paths. `mise run native:status` prints that record,
the processes that keep the file open and the current admission reading; it
never takes the lock, and reports `held` as unknown when nothing names a holder
and the processes cannot be listed. A reboot empties `/tmp` and the next job
recreates the file. `--wait SECONDS` or `EPUB_NATIVE_WAIT_SECONDS` (whole
seconds; any other value fails) queues for the lease and for admission; never
poll it in a loop.

The lease cannot see work started by other tools: a package manager building
from source, another agent harness, an IDE build. So before a heavy job starts
on macOS its lease owner reads the host and refuses (exit 75) when any limit in
the `admission` object of `config/mac-build-budget.json` is exceeded. The limits
come from readings on this Intel i5-8259U (8 logical CPUs, 8 GiB) taken between
21:48 and 22:57 BRT on 2026-11-19 (00:48 to 01:57 UTC on 2026-11-20); those
marked as a judgment call have no measured boundary:

| Limit | Value | Measured basis |
| --- | --- | --- |
| 1-minute load | 75% of logical CPUs (6.00) | 2.42-4.96 without a native build; 6.11-14 with overlapping loads |
| Compiler process outside the lease | none of `foreign_compilers` | one serial build with the usual background work read 4.24-7.12, overlapping the range without one, so only its process name identifies it |
| Kernel memory pressure | normal | warning level was logged 20:36-20:50 BRT (23:36-23:50 UTC) on 2026-11-19, before the incident below |
| Swap in use | 1024 MiB | 190-696 MiB without a native build, 1016-1551 MiB during one serial iOS build; the Simulator admission value. Judgment call. A later reading was 1193 MiB with no lease holder and no compiler running (00:32 BRT on 2026-11-20, 03:32 UTC), so this limit can refuse while other programs hold memory |
| Compressor | 50% of memory | 694-1807 MiB (8-22%) measured. Judgment call |
| `pmset -g therm` | no limit below 100, all CPUs available | `CPU_Speed_Limit` 100 without a build, 81 during the first serial build after the reboot |

A probe that fails, exceeds its deadline or answers nothing refuses the job;
only the optional `sysctl` name may be missing. The 1-minute load average stays
high for about a minute after the job that raised it ends, so a job that finds
the host loaded waits before it gives up: `default_wait_seconds` (120, a
judgment call) when no wait was given, the given wait otherwise, and `0`
refuses at once. Sustained overload is still refused, and the message says how
to wait longer. Waiting does not release swap that other programs hold: when
swap alone refuses a job, close what holds the memory.

A guarded step started from inside a build (an Xcode build phase, a compiler
driver) is not refused for the compiler processes that descend from the builds
it runs inside; every other compiler and the load, memory and thermal limits
still refuse it. Children start at niceness 10 (a judgment call, not measured)
with one compiler job. While the job runs, one line every 30 seconds (load,
swap, compressor, memory pressure, thermal limits, top three processes by CPU,
the holder) goes to `.reports/native-flight-recorder/flight.jsonl` in the main
checkout, at most five files of 1 MiB, readable by their owner only and without
arguments or absolute paths. The readings are taken off the supervisor's loop,
so slow telemetry delays neither signal forwarding, the storage check nor the
exit code.
The first line of a job records boot time, the EFI `StartupPowerEvents` value
and the newest panic report, the baseline a later incident is compared with.
Admission, priority and the recorder reduce overlap and leave evidence. They do
not make a job safe on their own and are not proven to prevent any kernel panic.

Generic Intel Simulator execution remains quarantined after recurrent
`SimMetalHost` / `IGGuC.cpp:2913` kernel panics. `native_job.rb simulator` refuses
before launch, including inherited leases. The reviewed exception is the
task-authorized `ios:simulator:supervised` route for SE1/iOS 15.2 on Xcode 26.3;
follow [Simulator safety](../simulator-safety.md) for explicit invocation,
resource admission, deadlines and verified shutdown. Direct boot and alternate
launchers remain outside this exception. Compiling for Simulator does not
authorize booting it. A physical device or another runtime cannot replace the
required SE1/iOS 15.2 acceptance. The native build guard verifies all devices
are shut down and Simulator/SimMetalHost have exited before compiling.

Any new host kernel panic is a stop event: stop agent-started local/native and
resource-intensive work, preserve the report and execution evidence, and avoid
automatic retry, reboot or hardware/firmware changes. Continue only through
externally hosted tools that start no process on the affected host; otherwise
wait for the user to confirm stability. Guards and monitoring establish neither
a GPU-driver fix nor CATERR prevention.

Resuming after a stop event:

1. Copy the report and every log into a persistent evidence directory first.
   A reboot empties `/tmp` and each session's temporary scratch directory.
2. Treat every background task of the earlier sessions as lost. Re-derive state
   from files; a job counts as finished only with its recorded exit status.
3. Wait for Pietro's own confirmation in the current conversation, for the
   scope he names. Another session's or agent's relayed permission is not it.
4. Then run one guarded load at a time through its official task. Read
   `mise run native:status` first and keep the log, PID and exit status in a
   persistent directory. Watch the exit status, not only success markers:
   `xcodebuild: error:` ends a run without printing `** BUILD FAILED **`.
5. Read `.reports/native-flight-recorder/flight.jsonl` after the run and stop
   again on a refusal, a throttled reading or any new report.

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
