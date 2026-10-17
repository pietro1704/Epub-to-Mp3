# Fresh-session continuation prompt

```text
Continue the authorized Piper/native-fallback implementation in repository
github.com/pietro1704/Epub-to-Mp3. Reply concisely in Brazilian Portuguese.

Read current AGENTS.md/CLAUDE.md, CODING_STANDARDS.md, the runtime navigation,
docs/plans/2026-10-16-piper-native-fallback.md and the task
APP-20261016-TTS-NATIVE-FALLBACK in TODO_APP.md before editing.

User decisions are settled: pt_BR-faber-medium is the default app primary;
installed native TTS is fallback, preferring Apple Luciana for pt-BR. If Piper
is missing or persistently fails, continue native with bounded Piper recovery.
Linux may use installed eSpeak NG. Browser native fallback is listening-only;
MP3 conversion/export requires Piper. No automatic model/package downloads,
paid providers or Edge without explicit consent. Do not ask these again.

Worktree: /private/tmp/epub-piper-native-fallback
Branch: feature/piper-native-fallback
PR: https://github.com/pietro1704/Epub-to-Mp3/pull/837
Dependency: PR #821 / feature/faber-integration, based at
b55244e0d59166472916cc6b684cb33937038846 when work began. Master did not contain
the typed Faber preferences, so #837 is stacked on that branch for review.
Inspect current branch/head, PR base, diff and exact-head checks before acting.
Initial implementation was 1945c19da736b5a5e736c123b4a03d882e781ac5; later fixes
must be read from current Git history. Never assume an old green run verifies HEAD.
If the temporary worktree is gone, fetch and create an isolated checkout of the
remote feature branch. Preserve the original heavily dirty workspace at
/Users/pips/Developer/epubtomp3 and every unrelated branch/worktree.

Source changes exist across Rust core/FFI, Swift, Flutter/Android and web:
- policy_version:2 opts into continued native fallback; absent retains legacy.
- fresh app defaults Faber+system, preserving saved settings and strict jobs;
  explicit adoption is supported. After two failures, retry Piper after eight
  native segments; cancellation/stale results must not mutate recovery state.
- missing model/preflight/packaged assets can reach allowed native fallback;
  invalid identifiers/paths/languages still fail. No implicit installation.
- desktop explicit FFI registration installs eSpeak NG (Linux) / SAPI fixed
  PowerShell child (Windows); bounded timeout, cancellation, kill/wait, no shell
  interpolation of text. Windows child hides its console. Native WAV is encoded
  by Rust once; Android WorkManager has the same JNI speech/cancel seam.
- browser reader offers installed-local-voice listening after provider failure;
  no fake MP3, export completion or mutation of captured strict job policies.
  Generation guards reject callbacks after chapter/job changes and cancellation.
- healthy Piper cache/recovery is retained. v2 native artifacts with unknown
  voice identity cannot be reused. Callback v1 still lacks exact resolved native
  voice metadata in Rust manifests; document this limitation honestly.

Tests/builds/CI are GitHub-only. NEVER boot/retry Intel Simulator or bypass the
quarantine, even through direct simctl, another launcher or an existing lease.
No local native builds/test suites, device actions, audible playback or heavy
benchmark are needed to resume. Source inspection/formatting/Git are allowed.
Any new host panic is a stop event; follow canonical safety instructions.

Next steps:
1. Inspect current PR #837 head and Actions. Diagnose/fix only related failures;
   preserve already working behavior. Existing queued/failed prerequisite jobs
   are not evidence for this implementation. Inspect actual logs and test counts.
2. Verify owning-runtime regressions: Rust/FFI missing-model continuation,
   cancellation/stale state, native timeout/supervision, cache/strict resume;
   Dart preferences/settings/desktop ABI; Kotlin assets/background cancellation;
   XCTest Luciana/locale/migration; Vitest native controls/stale callbacks and
   MP3 artifact integrity. Local suites remain suspended.
3. New workflow .github/workflows/native-fallback.yml tests installed Linux
   pt-BR eSpeak and Windows en-US SAPI. English smoke does not prove pt-BR voice
   installation. Full platform acceptance remains pending until actually tested.
4. Actual Apple GUI/SE1, physical Samsung, Linux GUI, Windows pt-BR and real
   browser-native playback were NOT verified. A test double or compile is not
   acceptance. Samsung/Linux app checks belong on Arch; current device/service
   permissions and the Simulator quarantine still apply.
5. Once required exact-head CI is green, review final scoped diff and dependency
   integration. Do not merge a failing/pending PR. Retarget #837 to master after
   #821 integration and revalidate the actual merge head. No forced history,
   broad cleanup or deletion of unmerged/uncommitted work.
6. Update task evidence, PR description and this continuation context with the
   actual SHA/results/remaining limits; report implementation and verification
   separately. Do not redo the benchmark or reopen settled product decisions.
```
