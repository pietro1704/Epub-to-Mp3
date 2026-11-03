# Phase 4: shared Rust audit

Status: execution playbook, not an audit result. Start after the Swift/build
phases are accepted or the user explicitly resolves their blocking dependency.
Return to the [six-phase plan](../2026-11-03-complete-code-audit.md).

## Scope and source observations

The [workspace manifest](../../../Cargo.toml) includes `converter-core`,
`converter-ffi`, CLI, server, WASM, `native/piper-runtime`, vendored eSpeak and
benchmarks. It patches four crates through `native/vendor/`. Release currently
uses one codegen unit, thin LTO and stripping. These are observed settings, not
evidence of optimal performance or passing tests.

[book_input.rs](../../../crates/converter-core/src/book_input.rs) dispatches PDF
sources to native text extraction. PDF unit/integration and FFI contracts exist;
older documentation describing all embedded PDF conversion as unsupported must
be reconciled against actual entry points and platform behavior.

The FFI contains versioned options and older entry points. Its v1 engine helper
defaults omitted or unrecognized values to Edge. Trace callers and compatibility
contracts before deciding whether this can violate the current explicit-consent
policy; this source observation alone is not a confirmed product bug.

## Preparation and evidence model

1. Read [runtime navigation](../../agents/runtime-navigation.md),
   [domain contracts](../../../CONTEXT.md),
   [coding standards](../../../CODING_STANDARDS.md) and the
   [execution policy](../../agents/execution-policy.md).
2. Record source SHA, dirty state, lockfile, enabled features, target triple,
   compiler/SDK, native dependency receipt and current platform owner. Assign
   exactly one Rust editing owner; other agents may inspect or test disjoint
   consumers but must not edit the same Rust files concurrently.
3. Inventory every owned Rust module, test, example, build script, C header and
   native wrapper. Classify unchanged vendor code separately, retaining patch,
   license and provenance review. Include feature-gated and WASM-excluded paths.
4. For each finding, capture the triggering input/state, expected contract,
   observed result, severity, confidence, affected consumers and smallest test
   that could disprove the hypothesis. Do not count a suspicious pattern as a bug.
5. Before any command that may compile dependencies or tools on Mac, ask whether
   a verified source/platform-matched prebuilt is available and wait for the
   answer. `cargo test`, `check`, `clippy` and audit-tool installation can compile.
   Use guarded tasks and the storage preflight after authorization; never bypass
   the shared one-job lease. No model downloads or real provider calls are implied.

## Ordered investigation and execution

### R1. Input boundaries, document fidelity and resource limits

1. Trace metadata and conversion separately through `embedded.rs`, `book_input.rs`,
   `epub.rs`, `epub/`, `ingestion/pdf_text.rs`, `toc.rs`, `structure.rs`, `text.rs`
   and `zip_names.rs` under `crates/converter-core/src/`.
2. Compare source TOC hierarchy, titles, chapter identity/order, anchors, markup,
   resources and Unicode text with the extracted structure and synthesis payload.
   Include PDF outlines, page-label fallback, front matter and image-only input;
   document format support per entry point rather than assuming reader parity.
3. Examine archive entry normalization, duplicate/local-versus-central ZIP names,
   missing resources, truncated input, decompression growth, recursion and source
   size limits. Measure bounded reads at the owning seam before optimizing IO.
4. Extend the smallest existing fixture and regression. Starting references are
   [EPUB contracts](../../../crates/converter-core/src/epub/epub_contract_tests.rs),
   [read limits](../../../crates/converter-core/tests/epub_read_limits.rs),
   [streaming input](../../../crates/converter-core/tests/book_input_streaming.rs),
   [PDF ingestion](../../../crates/converter-core/tests/pdf_ingestion.rs) and
   [PDF conversion](../../../crates/converter-core/tests/pdf_conversion.rs).
5. Fix the boundary that loses information or admits invalid input; preserve
   explicit unsupported-format behavior. Accept only after valid, malformed,
   cancellation and same-name/different-content cases produce the expected result.

### R2. Provider selection, model identity and recovery

1. Follow `tts_preferences.rs`, `tts_session/`, `model_catalog.rs`, `model_store/`,
   `worker/typed_speech_policy.rs`, `worker/provider_execution.rs` and
   `piper/piper_runtime_registry.rs` from client options to actual synthesis.
2. Build a decision table for default selection, explicit job selection, missing
   models, unavailable system voices, transient and persistent provider failure,
   bounded primary recovery, and cancellation. Verify the reported active voice
   differs from the configured primary when fallback is active.
3. Trace old FFI/CLI/server defaults to live callers. Reproduce any consent or
   preference mismatch at the public boundary before changing legacy semantics.
   Compatibility changes need a concrete proposal and user confirmation.
4. Check model install preflight, resumable partial downloads, checksums, atomic
   publication, cancellation, removal while in use and provider/language identity.
   Use local fixtures; installation must remain an explicit user action.
5. Extend [configured recovery tests](../../../crates/converter-core/src/tts_session/configured_recovery_tests.rs),
   [fallback tests](../../../crates/converter-core/src/worker/typed_fallback_tests.rs),
   [model operation tests](../../../crates/converter-core/src/model_store/model_install_operation_tests.rs)
   or the owning policy tests. Prove that user cancellation cannot initiate fallback.

### R3. Jobs, streaming, cancellation and durable artifacts

1. Follow `worker.rs`, `worker/conversion_schedule.rs`, `conversion_control.rs`,
   `jobs/`, `worker/playback_chunk_delivery.rs`, `cache/` and `audio/` from request
   acceptance through the final persisted manifest and playable output.
2. Draw the actual state transitions for manual conversion and listening windows.
   Locate cancellation checks around blocking IO, synthesis, segment publication,
   finalization and persistence. Check backpressure, bounded queues and resource
   policy when playback or navigation becomes urgent.
3. Use controlled providers to return late, out-of-order, invalid or duplicate
   results; replace the active book/window; cancel immediately before publication;
   simulate failed writes and relaunch from incomplete manifests. Assert that
   stale work cannot publish artifacts or overwrite the current job's state.
4. Verify cache keys include relevant source, text, voice/model, configuration and
   format identities. Distinguish rebuildable artifacts from retained listening
   audio, and preserve existing valid bytes when replacement fails.
5. Starting regressions include
   [cancellation](../../../crates/converter-core/src/worker/typed_cancellation_tests.rs),
   [job identity](../../../crates/converter-core/tests/embedded_job_identity.rs),
   [cache behavior](../../../crates/converter-core/src/worker/chapter_cache_tests.rs),
   [artifact receipts](../../../crates/converter-core/src/worker/chapter_receipt_tests.rs)
   and [job storage](../../../crates/converter-core/src/jobs/job_store_tests.rs).
   Accept only when terminal state agrees with durable, validated output.

### R4. FFI and native ownership

1. Inventory exported symbols and compare `converter-ffi/src/lib.rs`, boundary
   modules and `include/` headers with the Swift adapter, desktop Dart adapter and
   Android JNI declarations. Record sizes, signedness, encodings and ABI versions.
2. Audit each `unsafe` block's caller requirements and enforcement: pointer/length
   pairs, allocation/free symmetry, null handling, string validity, callback/context
   lifetime, handle concurrency, panic paths and thread-local error consumption.
   Do not deliberately dereference invalid pointers in ordinary in-process tests.
3. Trace the duration for which callbacks borrow bytes versus retain copied values.
   Verify freeing/replacing a client session cannot race a still-borrowed context;
   distinguish supported null rejection from undefined caller misuse.
4. Review option/schema validation and error clearing on recovery. Start with
   [memory boundaries](../../../crates/converter-ffi/src/ffi_memory_boundary.rs),
   [conversion callbacks](../../../crates/converter-ffi/src/conversion_callback_boundary.rs),
   [control/streaming tests](../../../crates/converter-ffi/src/ffi_tests/control_and_streaming_contract_tests.rs)
   and [PDF error recovery](../../../crates/converter-ffi/src/ffi_tests/pdf_contract_tests.rs).
5. Fix one ownership or contract defect with Rust regression plus affected-client
   verification. Preserve public symbols and serialized keys unless a reviewed
   migration is authorized. A Rust mock alone cannot establish Swift/Dart/JNI safety.

### R5. Consumers and supported feature combinations

1. Check CLI argument validation, literal chapter ranges, exit codes, cancellation,
   file selection and output reporting in `converter-cli/src/`; start with
   [command contracts](../../../crates/converter-cli/tests/command_contracts.rs).
2. Inspect `converter-wasm/src/lib.rs` and `session.rs` for browser-safe exports,
   error propagation, schema/cache identity, PCM/MP3 boundaries and non-native
   feature gating. Exercise generated bindings at the Web runtime when changed.
3. Inspect server path/upload/output boundaries and lifecycle through
   `converter-server/src/http_*` and existing HTTP contract tests. Preserve its
   compatibility role; never make an external server an Apple/Flutter prerequisite.
4. Derive a feature/target matrix from manifests and producer workflows, including
   default features, `piper-runtime`, `android-jni`, optional Kokoro runtimes and
   WASM. Prioritize affected supported combinations rather than enabling every
   optional runtime or downloading SDKs as a blanket audit step.
5. Verify shared changes against exact source/build identities on affected clients.
   Native Apple acceptance stays on Mac; Flutter Linux/Android belongs on Arch,
   Android remains paused, and Windows needs its own compatible environment.

### R6. Native dependencies, profiles and measurable improvements

1. Trace `native/piper-runtime`, vendored Piper/eSpeak/Sherpa patches, build scripts,
   native binary selection and packaged licenses. Verify retained artifact receipts
   against source, platform, architecture, ABI and relevant build flags.
2. Preserve the eSpeak WAV build inputs documented in
   [VENDORED-ASSETS.md](../../../native/vendor/espeak-rs-sys/VENDORED-ASSETS.md).
   A third-party audio extension is not evidence of disposable generated output.
3. Review lockfile advisories using the existing
   [dependency-audit workflow](../../../.github/workflows/rust-dependency-audit.yml).
   Separate an advisory, reachability assessment and verified remediation. Optional
   `DOCS_RS` checks do not establish native linking or synthesis acceptance.
4. Identify measurable costs before changing profiles: parsing allocations,
   repeated hashing/copies, cache IO, first audio, synthesis throughput and final
   encoding. Hold source, book/range, provider/model, build profile and cache state
   constant; report build time separately from runtime and audio reuse.
5. Propose one change with a before/after experiment and quality invariant. Do not
   remove validation, symbols needed for diagnosis, or resource limits to claim
   speed. New device/provider benchmarks need their own agreed scope.

## Validation selection and completion

Read each task and its dependencies again before execution; these are entry points,
not commands authorized by this planning document:

| Existing route | Use and limitation |
| --- | --- |
| `models:catalog:test` | Model-focused Rust tests; compiles under the native guard. |
| `piper:phonemes:test` | Vendored eSpeak punctuation/voice tests; no ONNX model, but native compilation is possible. |
| `native-tts:rust:test` | Core/FFI platform speech tests and an FFI build; not a lightweight inspection. |
| `tts:preferences:test` | Core, FFI, CLI and server selection contracts; has ONNX preparation dependencies. |
| `converter-ffi:ios-packaging:test` | Packaging boundary tests; does not prove playback or synthesis. |
| `web:wasm-contract:test` | Generated WASM contracts; matching built artifacts must already exist. |
| `.github/workflows/ci.yml` | Existing locked workspace tests and formatting gate; review selected features and exact tested SHA. |

For a narrower missing seam, use the existing guarded native command wrapper with
an explicitly selected crate/test filter; add a focused task only when necessary.
Never mistake a filter matching zero tests, an ignored test or a model-gated skip
for passing coverage. Broader suites follow an actual cross-crate impact or failure.

For each bounded finding: reproduce before the fix where feasible, change the
owning implementation, run success and relevant error/cancellation/identity tests,
re-run the original journey, review the full diff, then deliver through the scoped
PR and required CI gate. Confirm destructive removals and contract changes first.
Complete and integrate the current item before moving to the next; report blocked
platform acceptance instead of substituting another runtime or silently advancing.

Exit artifacts are the coverage inventory, verified findings and resolved PRs,
feature/consumer verification matrix, performance evidence where changes claim a
benefit, and explicit pending checks. No Rust test, build, model installation,
runtime benchmark or device validation was performed to write this playbook.
