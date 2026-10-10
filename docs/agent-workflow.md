# Delivery workflow

Use this workflow for changes that must survive review and future agent runs.

## Model and prompt selection

For day-to-day work in Codex, use **GPT-5.6 Terra** as the default: it is the
best cost/capability balance for this repository's Swift, Rust, FFI, and test
work. Use **GPT-5.6 Sol** for difficult root-cause analysis, architecture, or
changes spanning several runtimes. Use **GPT-5.6 Luna** for bounded edits,
documentation, summaries, and routine questions; its speed and low price are
useful, but it is not the default for long autonomous coding tasks when those
tasks are looping or missing constraints. Start with medium reasoning; raise it
for a hard diagnosis instead of switching every task to the most expensive
model.

At the 2026-10-07 API list prices, Luna was $0.20/$1.20, Terra $2/$12, and Sol
$4/$20 per million input/output tokens. These are API prices, not Codex plan
quota rates. Check the linked current model pages before budgeting because
availability and prices change:

- [GPT-5.6 Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna)
- [GPT-5.6 Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra)
- [GPT-5.6 Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol)
- [Model availability in Codex](https://help.openai.com/en/articles/20001354-gpt-6-and-other-models-in-chatgpt)

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

- `$ask-matt` when unsure which workflow/skill applies.
- `$diagnosing-bugs` for a reported failure, regression, or slow path; then use
  `$tdd` when the fix needs a regression test.
- `$grill-with-docs` for an unresolved design or multi-session idea; use
  `$to-spec` and `$to-tickets` when it needs a durable spec and task graph.
- `$implement` for a planned ticket; `$implement-spec` for executing a whole
  ticket graph. Use `$code-review` against the matching plan before delivery.
- `$domain-modeling` or `$codebase-design` when domain language or module
  boundaries are the actual problem; `$retro` after a workflow went sideways.

Keep the workflow proportional: do not invoke every role for a focused fix.
Make progress visible in the worktree or in verified evidence each turn. After
the focused verification, report exact commands/results and unresolved
blockers; do not narrate repeated exploration as progress. Commit, push, or
perform device/service actions only when authorized for that task.

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

For substantial feature delivery requested by Pietro, use Gitflow from the
current integration branch and a `feature/*` branch. Keep modules cohesive and
small, apply SOLID where responsibilities have distinct owners, and optimize
measured hot paths instead of imposing arbitrary file-length limits. When the
request explicitly asks for PR and merge, push the feature, open a PR to
`master`, and enable auto-merge; CI monitoring remains opt-in.

For a feature larger than one focused change, write a short spec and split it
into vertical tickets. Each ticket names its dependencies, acceptance evidence,
regression test, and verification command. Keep one behavior change per branch;
do not combine feature work, refactors, dependency upgrades, and CI changes.

## During implementation

For every feature or bug fix, check the required local runtime before coding:
iPhone SE (1st generation) Simulator on iOS 15.5 and the native macOS app. Verify
the affected behavior in both real apps after implementation. Automated tests are
additional evidence, not a substitute. If either app is unavailable, document the
blocker and leave runtime verification incomplete. All development stays on this
Mac; do not route implementation or validation to Arch.

Start each bug fix with a failing regression test. Keep the implementation and
its test in the same commit when practical. Preserve unrelated local changes by
using a detached worktree instead of stashing or resetting them.

Before pushing, update the branch from `master`, run `git diff --check`, and run
`mise run preflight`. A source-level test is not evidence for a native runtime
behavior; use the platform's executable test path for native changes.

## Review and merge

Every PR has one scope and a concrete acceptance checklist. Review the complete
diff against the ticket and project standards. Do not enable auto-merge for
feature PRs. Merge only after all required checks are green, the PR is not
behind `master`, security checks are green, and the merge is visible in
`master`.

After merging, verify the branch and worktree state, then remove stale branches
only after confirming they are merged. If CI fails, inspect the failing job and
push a focused fix; never close the task on a pending or blocked check.
