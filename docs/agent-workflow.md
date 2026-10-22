# Delivery workflow

Read [execution policy](agents/execution-policy.md) for current platform,
resource, safety and authorization rules. This document describes the work
sequence; historical campaign permissions are not execution authorization.

## Focused implementation

1. Recover the requested outcome, affected runtime and acceptance. Inspect the
   current implementation and relevant diff while preserving unrelated edits.
   Use an existing task definition and compatible artifacts before adding tools.
2. For a reported failure, use the project diagnosing-bugs skill: reproduce with
   the real tool/app, apply the smallest fix, exercise a meaningful regression,
   and rerun the original journey. Expand investigation only when evidence
   leaves the cause or acceptance unresolved.
3. Keep one coherent change on its feature branch. Write a short dependency and
   acceptance list only when multiple steps need coordination. Keep private task
   plans and progress evidence local, outside the published diff.
4. Run focused checks, inspect the complete owned diff and obtain review against
   [coding standards](../CODING_STANDARDS.md). Documentation-only changes need
   content/link checks; host fixtures do not prove native runtime behavior.
5. Commit/push the verified scope and create/update its PR. Apply the merge and
   monitoring boundaries in execution policy, then report exact evidence and
   any pending acceptance without implying completion from a plan or percentage.

For macOS packaging/build/GUI work, use the
[macOS validation path](agents/macos-validation.md) and the existing DerivedData.
A focused `-only-testing` selection can still compile its entire test target;
choose packaging or an incremental app build when that is the actual seam.
For native reader changes, use the reader instructions and skill. Their required
SE1 acceptance stays pending while Simulator execution is quarantined.

Use the active model configuration rather than pinning model names/prices in
workflow prose. Discover skills by their actual descriptions; a focused fix
needs the matching skill, not every available role. For external-project
research, retain sources, revisions, license boundaries and adoption evidence
under an indexed `docs/research/<date>-<topic>/` reference.

## Acceptance oracle

Before implementation, name the observable outcome, affected runtime and an
independent reference for the expected result: a fixture with known output,
a specification, a working implementation or a measurable app invariant.
Select the existing focused task or real-app journey that can detect a wrong
result. For regressions, demonstrate failure before the fix when feasible.

Verify success and the relevant failure, cancellation and identity cases at
the owning runtime. Record source/build identity, actual results and evidence
locations in the task's local working notes. Report unavailable runtime checks
as pending. A green build, mock or agent report cannot replace the affected
runtime's acceptance evidence. When delegating authorized work, provide bounded
context and disjoint editing ownership; keep dependent work sequential.
Use the platform ownership and safety limits in
[execution policy](agents/execution-policy.md); select only the relevant branch
of [runtime navigation](agents/runtime-navigation.md).

## Operational guardrails

Use the repository-owned host tools below for command sequences, scoped index
changes and instruction patches. Their public CLI regressions run through
`mise run host:workflow:test`, the local `mise run preflight`, `hooks-test` and
main CI. They do not launch native apps or Simulators. Inspect exact logs on
failure; a successful wrapper is not evidence that an unexecuted step passed.

- `mise exec -- ruby scripts/run_steps.rb PLAN.json NEW_OUTPUT_DIRECTORY`
  executes a JSON plan with an existing `cwd` and ordered `steps`, each containing
  a literal `argv` array and optional `timeout_seconds` (default 120). It stops
  on the first failure, preserves status, supervises its process group, and
  saves exact stdout/stderr plus duration/status in `report.json`. Console
  previews are bounded; existing evidence directories are never overwritten.
- `mise exec -- ruby scripts/scoped_git_index.rb capture MANIFEST -- FILE...`
  captures repository/HEAD/index/file identity and candidate index images.
  Use explicit `--stage-from DEST SOURCE` before `--` for reviewed prepared
  content when a file also contains unrelated work. `stage`, `untrack` and
  `verify` take that manifest. Resolve preexisting staged changes first. The
  real Git index lock and revalidated baselines reject concurrent changes;
  no checkout, reset, or working-file rewrite occurs. Review the exact staged
  scope before commit. External writes after verification remain possible.
- `mise exec -- ruby scripts/update_instruction.rb --root ROOT --destination FILE
  --baseline BASELINE --sha256 HASH --old OLD_TEXT_FILE --new NEW_TEXT_FILE`
  applies one unique byte patch from a separate immutable baseline. Reapplying
  is a no-op, including mtime; stale targets and ambiguous patches are blocked.
  An instruction alias updates its authorized real target while retaining the
  symlink. Use the canonical ai-memory installer for its managed block/skills;
  this helper does not replace that installer or infer replacements.

Before applying writes, validate current authorized destinations and preserve
unrelated changes. The reviewer checks exact scope, failure/cancellation/identity
coverage, repeated-application evidence, duration and limitations. A changed
index does not establish preserved local bytes without read-back. Shorter
instructions alone prove no quality improvement. The optional local
[guardrails toolkit](../../agent-guardrails/README.md) remains available for
privileged maintenance and paired prompt evaluations outside these repo tools.

For tool discovery, filter names first and load descriptions/schemas only for
bounded candidates. Save lengthy command output with an exact recovery path;
read relevant ranges rather than dumping registries, whole logs or unrelated
instructions. Preserve failure status when reducing output. Use argv interfaces
or a deliberate shell script with `set -euo pipefail` for dependent operations.

For ai-memory channel diagnostics, configuration delivery or transport-only
revalidation, follow [collaboration operations](agents/collaboration-operations.md).
These deterministic checks invoke no model. Use the existing actual-agent
handshake only for initial integration or changed interpretation requirements.

Collect native result evidence through `mise run native:xcresult -- BUNDLE --
xcrun xcresulttool ... --path BUNDLE`. The wrapper locks the canonical bundle,
including path aliases, so summary/export reads cannot race SQLite initialization.
Independent bundles retain parallelism. `XCRESULT_LOCK_TIMEOUT_SECONDS` defaults
to 30 and accepts a positive value up to 60; timeout returns 75, invalid input 2,
and tool errors/signals retain their actual status. The lease follows the tool
if its supervisor dies. It does not compile or launch an app.

The local pre-commit hook remains a read-only whitespace gate. Native pairing
and language checks keep their existing owners. Inspect task definitions before
running build/test commands that may generate artifacts or set up dependencies.

## Review and delivery

The reviewer owns enforcement of scope, resource cost, regression quality and
acceptance evidence. Review the final diff against the user's actual request;
check that claimed behavior was exercised at its runtime and that original data
and unrelated work remain intact. Follow the execution policy for the minimal
PR gate, standing automatic-merge authorization for ready PRs to `master`
and no-monitoring default. Keep the repository's existing guarded merge
workflow enabled; other targets follow the execution policy's authorization rules.
Comprehensive post-merge validation and publishers are separate from PR checks.

After an authorized merge, read back its identity and confirm it belongs to
`origin/master`. Preserve local overlays, fast-forward local `master`, then remove
only confirmed-integrated branches. Keep useful evidence and compatible outputs.
Report implementation, local checks, app acceptance and delivery state separately.
