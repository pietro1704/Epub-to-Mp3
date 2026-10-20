# Git hygiene and shared agent assets

Baseline: `2477485280`, branch `feature/architecture-hardening`.
Parent: TOOL-20261015-GIT-HYGIENE in TODO_APP.md. Owner: Codex.

## Execution prompt

Use `$auto-prompt-execute`, `$tdd` and `$code-review` to repair Git hygiene.
Keep project-owned skills, instructions, plans and portable editor configuration
versioned. Ignore local agent state, secret environment files, instruction
backups, installed tools and generated snapshots. Untrack existing local/generated
artifacts without changing their disk bytes. Preserve unrelated product changes
and security configuration. Exercise the rules through real Git in a temporary
repository, inspect the owned index diff, then commit/push this slice only.
Do not rewrite history, run native apps/builds, open PRs or merge.

## Task board

| ID | Owner | Depends on | Acceptance | Status/evidence |
| --- | --- | --- | --- | --- |
| GIT-1 | Codex | Baseline | Shared assets distinguished from local state | Verified: 62 initial tracked-but-ignored files; retained three shared VS Code files and four public Vite profiles; shared skills/relative aliases remain versioned |
| GIT-2 | Codex | GIT-1 | Rules preserve shared skills/editor files and exclude generated/local files | Verified: red on visible `.env`, local agent settings and hidden VS Code profiles; green 5 tests/137 assertions, no skips via `mise run git:hygiene:test` |
| GIT-3 | Codex | GIT-2 | Index cleanup preserves local bytes and unrelated changes | Verified: 76 index-only removals; SHA-256 read-back matches all 76 files; unrelated unstaged diff byte-identical; zero tracked-but-ignored files |

## Review

Standards: host tests use real Git in isolated repositories with global/system
Git configuration disabled. They exercise secret/local exclusion, shared asset
visibility, relative skill symlink identity and index-only removal with byte
preservation. No source-contract/native claims. Shared assets and security
configuration remain untouched; generated artifacts have no active script or
manifest dependency in the inspected paths. One vendor path has a historical
QA-document reference; its local file and Git history remain available.

Spec: all three criteria pass. Removed from the index: 51 QA captures/logs,
3 harness-private memory files, 2 nightly session notes, 9 Hermes snapshot files,
6 installed cargo-ndk files and 5 generated legacy vendor copies. All remain
locally. Existing source/test edits and other task plans are outside the commit.

Verification: `mise run git:hygiene:test` (5 tests/137 assertions),
`mise run native:build:preflight:test` (7 tests/46 assertions),
`mise run preflight`, `git diff --check` and index/hash review passed.
Later review detected concurrent changes in eight product/test files. They were
left untouched and excluded from the index; the byte-identical unrelated diff
claim applies to the immediate before/after cleanup snapshot, not later work.
No app/build/device run, history rewrite, remote audit, PR or merge.
