# Piper primary and native fallback: implementation dry run

Status: implementation authorized after reviewed planning; verification pending.
Owner: Codex root. User accepted P1/P2/P3 and then explicitly requested implementation
and a self-contained prompt for continuing in a fresh session.

## Accepted scope and boundaries

Default app primary is Piper `pt_BR-faber-medium`. Default secondary is installed
native speech; prefer installed Luciana for Apple pt-BR. Keep Edge opt-in with
explicit online consent. Preserve explicit model installation, user choices,
strict job snapshots, cancellation and stable book/chapter identity. Do not
silently select Faber for incompatible non-Portuguese text. Existing language
validation remains until another compatible model is deliberately chosen.

Record the policy once in `CLAUDE.md`. This plan describes how to implement it;
it does not assert that installed apps or current master already comply.
Dirty working-tree architecture work remains untouched. Implementation should
start on isolated feature branches from current master after reconciling which
existing changes are prerequisite PRs. Do not copy the dirty worktree wholesale.

## Facts established by inspection

1. All inspected app preference defaults already use Faber but omit secondary.
2. Rust accepts engine `system`; native WAV is encoded/published by Rust. Apple
   and Android register adapters. Desktop opens sessions without one. Swift
   engine choices and the TypeScript TtsSelection union omit `system`.
3. FFI `resolve_piper_model_paths` and worker model hashing fail before segment
   synthesis if the model pair is missing. Changing secondary alone cannot
   provide missing-model fallback.
4. SegmentPolicy stops before the third consecutive primary failure. Its state
   is serialized in OutputManifest.tts_policy_state and accepted in FFI options,
   validated as 0..2. ChapterAudioReceipt does not contain this counter. WASM
   session reuses the same policy logic.
5. BrowserConversionClient.runtime.synthesize requires Piper output bytes;
   ConversionSession.accept_audio validates MP3 before advancing. Browser-native
   speech playback cannot be inserted as an empty or invented MP3.
6. Dart `_legacyConversionOptions` explicitly records secondary:null to preserve
   old job identity. This is not a fresh-job default and must remain immutable.
7. Typed `synthesize_preferences` lacks the legacy native path's platform gate
   and deadline. Existing Apple/Android adapters have their own controls, but
   that does not establish a uniform cancellation/deadline contract for desktop.
8. The current C callback v1 and PlatformTts trait do not report the actual
   resolved native voice. Safe native cache identity requires a contract addition,
   not simply assigning a friendly Luciana label to the requested selection.

## Architecture and implementation slices

| ID | Owned surface / future owner | Change | Dependency and acceptance |
| --- | --- | --- | --- |
| TTS-1 | Rust core/FFI; one named editor | Add app default-policy resolution with explicit capabilities and compatible language. Keep headless callers free of a promised system adapter. Separate policy preference from adapter availability and native output type. | Contract first; tests prove default Faber, native secondary on supported app targets, absent capability and strict explicit overrides. |
| TTS-2 | Rust core/FFI; same editor | Resolve primary readiness without preempting an allowed fallback. Use typed missing-model/voice/runtime/cancellation errors. Continue working native fallback through persistent primary failures; retry primary at bounded recovery points. Preserve fast aborts for cancellation and stale playback, and no repeated expensive model initialization when a model is known absent. | P2 accepted. Cover missing/incomplete/corrupt model pairs and missing phonemizer; never download implicitly or label invalid artifacts complete. |
| TTS-3 | Swift native; Mac owner | Expose system secondary in typed preferences/settings; install defaults only on new/unconfigured settings. Reuse PlatformSpeechSynthesizer; prefer installed locale-compatible Luciana deterministically, otherwise another compatible installed voice. | TTS-1/2; Apple XCTest selection, buffer, cancellation and actual native verification. Use current API compatible with existing deployment targets. |
| TTS-4 | Flutter/Android; Arch owner | Add system selection and shared preference migration; reuse JNI AndroidPlatformSpeech and Kotlin offline voice filtering. Reader conversion and manual conversion receive the same effective policy. | TTS-1/2; Dart/Kotlin regressions plus actual Samsung run after separate runtime authorization. |
| TTS-5 | Rust desktop adapter/FFI; one named Rust editor, Arch verifies Linux | Supply installed native Windows/Linux speech as bounded PCM WAV using target-specific backends; register on every desktop worker session through an explicit app integration point. | TTS-1/2; prove the worker registration path, ABI lifetime, timeouts, missing backend/voice and cancellation. No synchronous Dart callback dependent on a blocked UI isolate. |
| TTS-6 | Web TypeScript and Rust WASM; designated owners with separate paths | Add system selection/capability reporting and reader playback fallback. Keep native playback state separate from persisted converted-audio artifacts. Never advance accept_audio or completed conversion with speech-only output. | P1 accepted: native playback only; export requires Piper. Browser implementation requires a separate playback completion/state contract; Rust retains segment identity/policy. |
| TTS-7 | Verification and release owner | Review exact-head CI and collect actual platform evidence for affected paths before claiming platform acceptance. Small coherent PRs per slice; merge only under existing authorization and green required checks. | All corresponding dependencies; Simulator acceptance remains blocked by quarantine. |

### Preferences and job identity

Use a versioned preferences migration and a single effective-policy resolver at
each adapter boundary. Fresh defaults become Piper + system. Preserve saved
explicit primary/secondary choices, including no-fallback settings. Old null
secondary values have no provenance: conservatively retain them and present the
new recommended default for explicit adoption; do not guess user intent.
Do not mutate already queued/running/resumable jobs. Manual strict selection
continues to disable inherited fallback unless explicitly enabled.

Add a versioned native capability/voice-resolution metadata seam before synthesis
so Rust can build the right cache key, with a backward-compatible v1 fallback
that disables unsafe native reuse when identity is unknown. Define metadata
and lifetime contracts before implementation; do not silently alter callback v1.
Resolved identity must remain pinned for a segment even if installed voices change.
Retain existing provider-local serialization, and add a deadline/cancellation
contract to the typed path without holding global locks across UI callbacks.

Policy snapshots, manifests and cache identities must include policy version,
requested provider/model and actual resolved native voice/backend identity.
Include backend version where obtainable, locale and relevant synthesis settings;
avoid reusing old native artifacts after voice/backend changes. Distinguish a
temporarily missing primary from a stable content hash. Missing models cannot be
represented as an existing verified model. Persist failure counters and fallback
reason without conflating a cancelled/stale request with provider failure.

### Desktop feasibility

Windows candidate: native SAPI/COM stream synthesis in a worker-owned COM
apartment, copied to bounded PCM WAV before shared Rust encoding. Enumerate
installed locale-compatible voices, serialize access per synthesizer and drain
cancellation before releasing COM objects/session callbacks. A library that only
speaks through speakers is insufficient for conversion artifacts.
Before choosing SAPI, run a bounded Windows CI feasibility check for installed
pt-BR voice enumeration, PCM output and cancellation. WinRT SpeechSynthesizer
is another official stream-producing candidate if SAPI cannot access the
required installed voices. Pick one backend from actual evidence; do not promise
all Windows voices or add both preemptively.

Linux candidate: explicitly detect an installed speech backend that can supply
PCM/WAV (for example eSpeak NG retrieval API), with an owned serialization gate
and cancellation. Do not assume Speech Dispatcher speaker output supplies PCM.
No service/package installation or automatic download. Expose unavailable native
speech when no compatible backend/voice exists. Backend choice remains subject
to specialist feasibility review; optional compile-time bindings must preserve
portable packages and licenses.
The user accepted installed eSpeak NG for Linux in P3. It does not necessarily
match a desktop user's Speech Dispatcher voice. Its phonemizer family overlaps
Piper's dependencies: test whether an actual Piper dependency failure also
disables fallback, and never claim independent redundancy without evidence.
The existing Piper runtime uses espeak_rs/global state. A second in-process
eSpeak initialization could interfere; a separate mutex does not establish
safety. The Linux feasibility slice must compare sharing that state safely
against an installed eSpeak subprocess with literal argv/stdin or a private text
file, bounded timeout, cancellation, kill/wait and owned-temp cleanup. Do not
install a package or spawn an unbounded shell pipeline as an implementation shortcut.

For browser playback, accept only installed compatible voices with localService
true under the offline policy. Resolve the asynchronously available voice list
with bounded readiness, and invalidate callbacks on job/chapter change. Do not
use a remote browser default when no offline voice exists. Existing book-audio
playback must stop before native narration starts, and cancellation must drain
native narration before primary audio resumes.

### Apple selection

Resolve against voices actually returned by AVSpeechSynthesisVoice.speechVoices;
do not assume a benchmark `say` voice identifier exists on iOS. Prefer Luciana
only in the applicable Portuguese locale. Do not apply the current compact-only
filter before checking for installed Luciana. Keep a deterministic compatible
fallback, reject region mismatches, and persist the actual selected voice.
No implicit download, personal-voice authorization or new minimum OS requirement.

## Dry-run scenarios and expected boundaries

| Scenario | Planned observable result |
| --- | --- |
| Faber installed and healthy | Only Faber audio; native speech does not start. |
| Isolated Piper segment failure | Native supplies that segment; next segment retries Piper; one visible fallback notice. |
| Missing Faber or repeated failures | Continue using working native fallback; primary preference remains Faber, UI explains native use, and recovery attempts are bounded. Stop with a clear error if both providers are unavailable. |
| Missing native voice/backend | Actionable error with install/configuration choices; no cloud substitution or invented artifact. |
| Cancel while queued/synthesizing/encoding | Stop and drain provider work; no later fallback, stale audio publication or success state. |
| Switch chapter/book during inference | Reject late output using existing content/request identity; never attach audio to another selection. |
| Partial PCM, silence, invalid rate/oversize output | Validate before Rust encoding/publication; retain failure reason and clean owned temporary output. |
| Resume old job / change settings | Resume original captured policy; new jobs use explicitly adopted current defaults. |
| Install Faber after native use | Reevaluate readiness at a defined request/segment boundary; avoid mixing cache identities or mutating in-flight policy. |
| Non-Portuguese input | Preserve compatibility validation; require explicit compatible primary selection, no silent wrong-language Faber narration. |
| Browser native playback | Playback-only state and controls; converted job/artifact progress does not pretend completion. |
| No installed offline native voice | Native unavailable; internet/paid provider never selected automatically. |

PCM nonempty/finite/rate/size validation and any silence-detection threshold are
planned acceptance work, not a claim that all current adapters already detect
silence. Keep legitimate pauses intact; define any silence rejection from a
representative corpus before making it a production failure condition.
Readiness can change between requests/segments without changing the captured
requested policy. Record effective provider identity and readiness transitions
with resulting artifacts; freeze each segment's resolved voice until completion.

## Future verification, not executed

Use current task definitions rather than invented commands. Root mise tasks
`tts:preferences:test` and `native-tts:rust:test` cover existing Rust/FFI seams;
inspect their prerequisites on the implementation branch before use. Run test
suites/CI on GitHub Actions under the current repository policy. Existing web
package scripts are `test`, `build`, `lint`; focused Vitest and TypeScript checks
must include system union, migration, browser fallback and artifact integrity.
Native Apple regressions belong in XCTest, Android in Kotlin/Dart, desktop in
the target runtime with real installed speech. Unit fakes alone do not establish
native speech or browser playback performance.

CI matrix must actually exercise Windows COM and Linux native synthesis, not
merely cross-compile. Use controlled installed voice fixtures where possible,
explicitly skip with evidence when unavailable, and retain acceptance as pending.
Measure process/model readiness separately from first playable output, peak RAM,
timeouts and transition delay, using the same representative text/range. Add
no duplicate full benchmark merely to validate a preference change.

Actual Apple runtime verification remains unexecuted; the required SE1/iOS15.5
Simulator is quarantined. No alternative launcher or physical device establishes
that acceptance. Linux/Samsung live verification belongs on Arch when authorized;
Windows and real-browser acceptance require available matching environments.

## Accepted product decisions

- P1 — Accepted by user: installed browser speech is a playback-only emergency
  fallback; export/conversion requires Piper. Standard browser
  speech does not provide PCM for the existing MP3 contract; requiring native
  browser MP3 export needs a separately supported capability, not a fake adapter.
- P2 — Accepted by user: if the model is missing or Piper persistently fails,
  continue with working native speech while keeping Piper as preferred primary;
  retry at bounded recovery points and show the active voice. This supersedes
  the old three-consecutive-failure stop rule. Implementation must version the
  policy state, preserve strict legacy job snapshots and test compatibility.
- P3 — Accepted by user: installed eSpeak NG is an acceptable Linux fallback
  when the desktop speech service cannot supply PCM. Explicitly label the
  selected voice/backend. No package/model installation is automatic.

The user's reply was "sim pros 3". It resolved the dry-run product questions;
the subsequent request explicitly authorized implementation.
Exact recovery intervals and platform backend selection are engineering choices
to validate in the corresponding implementation slice, not measured facts.

## References

- Apple voice enumeration/availability: https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice
- Apple PCM synthesis: https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer
- Android installed/offline voice selection: https://developer.android.com/reference/android/speech/tts/TextToSpeech.Engine
- Windows SAPI stream output: https://learn.microsoft.com/en-us/previous-versions/windows/desktop/ms719788(v=vs.85)
- Windows WinRT voices: https://learn.microsoft.com/en-us/uwp/api/windows.media.speechsynthesis.speechsynthesizer.allvoices
- Linux Speech Dispatcher contract: https://github.com/brailcom/speechd/blob/master/doc/speech-dispatcher.texi
- eSpeak NG Portuguese/WAV example: https://github.com/espeak-ng/espeak-ng/blob/master/docs/languages/roa/pt.md
- Browser Web Speech contract: https://webaudio.github.io/web-speech-api/#speechsynthesis
- Source audit: `../research/2026-10-16-tts-platform-policy-audit.md`.

## Review evidence

Both independent specialists read the actual draft and returned conditional
planning approval; no runtime checks or product edits were performed by them.

- tts_core_policy_review: required typed-path deadline/serialization, versioned
  native identity before cache, exact manifest counter location, explicit PCM
  validation scope and P3. All incorporated above. Conservative settings migration
  was accepted; strict old jobs remain unchanged.
- tts_platform_specialist: required explicit browser playback/artifact separation,
  offline voice filtering, Windows installed-voice feasibility, Linux backend
  acceptance, and eSpeak global-state coexistence/cancellation evaluation. All
  incorporated above, including official API references.

All three product conditions were resolved by the user's acceptance. The
implementation proceeds in an isolated feature worktree depending on Faber
PR #821; the original dirty workspace is preserved. Runtime acceptance is not
established by code presence. Exact verification and delivery status will be
recorded below and in the continuation prompt.
