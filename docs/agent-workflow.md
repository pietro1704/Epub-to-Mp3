# Delivery workflow

Use this workflow for changes that must survive review and future agent runs.

## Model and prompt selection

Use the model selected by the user or the active Codex configuration. Do not
pin model names, prices, or reasoning defaults in workflow prose. Consult
current official OpenAI documentation when changing model/tool configuration.

Give the agent one observable outcome, the platform/runtime, hard constraints,
acceptance checks, and the requested delivery actions. Let repository
instructions supply project-wide rules rather than pasting them into every
prompt. A reusable prompt for this project:

```text
Objetivo: [resultado observável]
Contexto: [iOS/macOS + Swift/Rust/FFI, ou CLI/web; inclua os livros/capítulos se relevante]
Restrições: [dados a preservar, dispositivo, cache, limites de execução, ações proibidas]
Aceitação: [comportamentos e artefatos que precisam estar corretos]
Verificação: [teste/build mínimo que prova isso; sem alegar execução não feita]
Entrega: [resumo, limitações e se commit/push estão autorizados]
Faça uma investigação focada, implemente a menor fatia completa e pare quando a aceitação for provada.
Se faltar acesso a dispositivo/serviço ou houver falha sem causa clara, informe a evidência e o próximo passo concreto; não repita tentativas sem nova evidência.
```

For a task that is already clear and small, send the request directly. Use a
skill only when its trigger fits; the skills are a router, not a checklist to
run all at once:

- Discover an available skill by its actual description when routing is unclear.
- `$diagnosing-bugs` for a reported failure, regression, or slow path; then use
  `$tdd` when the fix needs a regression test.
- Use the available grilling skill only when unresolved decisions affect scope or acceptance.
- Implement the bounded ticket directly; use `$code-review` when reviewing its change.
- `$domain-modeling` or `$codebase-design` when domain language or module
  boundaries are the actual problem; `$retro` after a workflow went sideways.

Keep the workflow proportional: do not invoke every role for a focused fix.
Make progress visible in the worktree or in verified evidence each turn. After
the focused verification, report exact commands/results and unresolved
blockers; do not narrate repeated exploration as progress. Apply the standing commit/push authorization in AGENTS.md unless revoked.
Other external/device/service actions follow the authorization stated there.

## Operational guardrails

For file synchronization, privileged maintenance, instruction-file edits, or
completion claims, use the [local guardrails toolkit](../../agent-guardrails/README.md).
It supplies fail-closed scope manifests, real-path checks, unit/privilege
preflight, bounded evidence capture, and a paired-response evaluation rubric.
The controls are explicit, not automatic interception of all agent tools.

Before applying writes, validate the exact current authorized destinations;
separate profiles need separate approval. During review, inspect acceptance
artifacts and read-back, test duration, and limits before accepting runtime
or optimization claims. Use the same rubric and real baseline/candidate
responses for prompt comparisons; shorter instructions alone prove no quality gain.

The local pre-commit hook is a read-only staged-whitespace gate. Existing CI
owns language lint/tests. `preflight.sh` no longer bootstraps the legacy Apple
Python vendor, but its build/test commands may still generate artifacts or invoke
setup when dependencies are absent; inspect task definitions before execution.

## Before implementation

For substantial feature delivery requested by Pietro, use Gitflow from current
`master` and a `feature/*` branch. Keep modules cohesive and
small, apply SOLID where responsibilities have distinct owners, and optimize
measured hot paths instead of imposing arbitrary file-length limits. When a task
explicitly authorizes a PR and merge, open a PR to `master`. Merge only after
required checks are green. Enable auto-merge only with explicit user
authorization and after that green-check gate is satisfied. CI/PR monitoring
remains opt-in; report pending checks without polling unless requested. PR
authorization alone does not authorize merge.

For a feature larger than one focused change, write a short spec and split it
into vertical tickets. Each ticket names its dependencies, acceptance evidence,
regression test, and verification command. Keep one behavior change per branch;
do not combine feature work, refactors, dependency upgrades, and CI changes.

## During implementation

For native Apple behavior changes, use this exact native iOS runtime: iPhone SE (1st
generation) Simulator on iOS 15.5. Check it and the native macOS target before
coding, then install, launch, and exercise both real apps. Automated tests are
additional evidence. If either app is unavailable, document the blocker and leave
runtime verification incomplete. All development stays on this Mac; do not route
implementation or validation to Arch.

Start each bug fix with a failing regression test. Keep the implementation and
its test in the same commit when practical. Preserve unrelated local changes by
using a detached worktree instead of stashing or resetting them.

Before pushing, inspect divergence from `master` and preserve feature dependencies;
update safely when required without rewriting unrelated work. Run `git diff --check`
and `mise run preflight`, plus focused runtime tests. Preflight alone is not coverage. A source-level test is not evidence for a native runtime
behavior; use the platform's executable test path for native changes.

## Intel Mac build and Simulator phases

The supplied 2026-10-15 panic reports `IGGuC.cpp:2913`, work queue 41,
`AppleIntelKBLGraphics`, and `SimMetalHost` for the iPhone SE. Compressor
and swap were reported OK. This supports a graphics-driver queue failure;
it does not establish disk exhaustion, general RAM exhaustion, hardware
failure, or an app defect. Hermes reported concurrent compilation from a
separate capture; that capture was not independently inspected in this task.
The measures below reduce concurrency; they are not a verified driver fix.

1. Before compiling Swift/Rust/native dependencies, stop the active native
   app, shut down its Simulator, and verify shutdown and `SimMetalHost` exit.
   Use `mise run native:build:preflight` for the read-only Intel check. A
   failed inspection blocks compilation; preserve the failure evidence.
2. Keep heavy jobs under the existing `/tmp/epub2mp3.heavy-job.lock` lease.
   The preflight is a snapshot, not a lock or global interception. Keep the
   Simulator off throughout compilation, including incremental builds and
   build phases. Avoid other GPU-heavy work during verification.
3. For the required SE1/iOS 15.5 reader run, select Xcode 16.4 with
   `DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer`.
   Verify the exact destination; do not substitute another runtime.
   Run `build-for-testing` first with `-jobs 1` and parallel testing disabled.
4. After compilation exits, boot only the selected Simulator and execute
   `test-without-building` against the compatible existing `.xctestrun` and
   derived-data artifacts, again with parallel testing disabled. Existing
   `ios:simulator:test` supports `IOS_SKIP_BUILD=1`; use it only with valid
   artifacts from the matching source, SDK, architecture and test settings.
   A `xcodebuild test-without-building` process is expected during execution;
   compiler/build processes alongside it are not.
5. Shut down and confirm exit before rebuilding or switching to macOS.
   Verify macOS separately. At the end of reader verification, leave only
   the required SE Simulator/app open on the seeded book. A later build
   must stop that retained session first.

Documentation/configuration changes need focused host/content checks, not an
app launch. Do not restart services, change renderer defaults, disable Metal,
install drivers/runtimes, erase Simulators, or reproduce a kernel panic as an
implicit workaround. Report any unverified app/driver stability explicitly.

## Review, merge, and post-merge reconciliation

Every PR has one scope and a concrete acceptance checklist. Review the complete
diff against the ticket and project standards. Merge only after all required
checks are green, the PR is not behind `master`, security checks are green, and
the merge is visible in `master`. Follow the explicit authorization and
auto-merge rule above; do not monitor CI/PR unless requested.

After merging, verify current branch and worktree status, preserve local changes,
and fetch `origin`. Fast-forward local `master` to `origin/master` and confirm
the merge commit is present. Integrate documentation-only changes by fast-forward
when histories align or cherry-pick when they do not. Inspect the staged diff to
ensure no product files are included. Never push stale local `master` or rewrite
history. Remove stale branches only after confirming they are merged. Report
check failures and act only within authorized scope; do not poll unless requested.
