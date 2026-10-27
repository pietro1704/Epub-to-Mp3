# Model catalogue, download and voice labels: implementation roadmap

Date: 2026-10-25

## Executive decision

EpubToMp3 should not start this work by adding another abstraction layer or a
generic model marketplace. The repository already has the beginnings of the
right implementation: Rust descriptors with pinned files and checksums, an
atomic `ModelStore`, versioned session identity, an FFI boundary, and Swift
decoding. The correct next move is to deepen those existing modules and remove
client-side policy duplication one vertical slice at a time.

The recommended end state is:

1. Rust is the single authority for model identity, exact language evidence,
   voice metadata, installability, licence metadata, compatibility, installed
   integrity and runtime readiness.
2. One versioned Rust snapshot projects that authority to clients. It keeps
   catalogue facts, installed state, runtime readiness, user consent and active
   selection as separate fields.
3. One concrete Apple module owns the FFI instance and maps that snapshot to
   native view state. Settings controllers send intents to it; they do not open
   the FFI, derive labels, inspect files or run installation themselves.
4. Download remains an explicit user action. Installing never selects a model,
   revokes a previous selection, deletes another model or grants licence consent.
5. The first shipped slice supports the already real Piper Faber path. It does
   not introduce a Rust trait or Swift protocol until a second real adapter needs
   the seam.
6. Preflight, observable progress, cancellation and crash-safe cleanup precede
   resumable download. Resume is a later capability because it needs validated
   HTTP range/validator semantics, not merely a `.part` file.
7. One product decision must precede the transport design: whether downloads
   must continue while the app is suspended/locked and reconnect after relaunch.
   If yes, Apple background `URLSession` is a real second transport adapter;
   Rust still owns the manifest, full-file verification and atomic publication.

This report proposes no code change. It separates facts, inferences and
recommendations, and all implementation phases require their own reviewable
change and runtime evidence.

## Scope and evidence discipline

- Repository snapshot: `f4546e669852e50602d893e9e8b603511e1a90b6`.
- The current dirty worktree was treated as user-owned and was not modified,
  except for this new report.
- Fabio Akita's positions were read in his original dated blog posts.
- Codex workflow claims come from official OpenAI documentation, checked on
  2026-10-25.
- Claude Code behavior and workflow claims come from current official Anthropic
  documentation, checked on 2026-10-25.
- Reddit material is explicitly anecdotal. It is used only to identify failure
  modes worth testing, never to establish architecture or product requirements.
- Local source establishes what is implemented. Absence claims are bounded to
  the inspected files and exported interfaces; they do not prove that no
  experimental implementation exists elsewhere.

Labels used throughout:

- **Fact:** directly observed in source or an official source.
- **Inference:** a conclusion drawn from facts; it still needs implementation or
  runtime evidence.
- **Recommendation:** the proposed course of action.

## What the source material actually supports

### Fabio Akita: SOLID is useful as concrete design pressure, not ceremony

In [Clean Code pra Agentes de IA](https://akitaonrails.com/2026/04/20/clean-code-para-agentes-de-ia/),
Akita re-ranks practices for agent-maintained code. His central points relevant
here are small and coherent responsibilities, searchable names, explicit types,
dependency injection where substitution is real, headless tests, and concise
project instructions. He also argues that tests are the feedback loop that keeps
plausible agent output from silently breaking existing behavior.

**Inference:** “apply SOLID” should not become `CatalogProviderFactory`,
`VoiceLabelStrategy` and a protocol for every function. For this repository it
means concentrating catalogue policy in one Rust module, keeping identity types
explicit, and testing through the same small interface used by clients. A class
or trait earns its place only if it hides real complexity or supports real
variation.

In [[Akitando] #144 — Modelagem de Software é Difícil?](https://akitaonrails.com/2023/08/11/akitando-144-modelagem-de-software-e-dificil-ver-vs-enxergar/),
Akita treats patterns and architecture literature as vocabulary, not a recipe.
He argues that architecture emerges from actual domain experience and that a
technique useful in one part of a system can be overengineering in another.

**Inference:** the existing duplicate catalogue projections, hard-coded Faber
readiness and repeated direct FFI use are concrete evidence for deepening the
current seam. A hypothetical plugin system is not. This is enough evidence for
a `SpeechModelLibrary` module; it is not evidence for a universal engine SDK.

In [ai-memory: arquitetura emergente e software maleável](https://akitaonrails.com/2026/06/14/ai-memory-arquitetura-emergente-e-software-maleavel/),
Akita describes building one working feature at a time, hardening and refactoring
along the way, and allowing some duplication until real use justifies a common
shape. His stated order is “make it work, make it right, make it fast.”

**Recommendation:** preserve the working Faber path and replace its duplicated
facts through compatibility-preserving slices. Do not rewrite catalogue,
installation, preferences and Settings together.

### Fabio Akita: tests and short probes buy down uncertainty

In [[Akitando] #130 — Projetos, TESTES e Estimativa](https://akitaonrails.com/2022/10/25/akitando-130-rant-projetos-testes-e-estimativa-rated-r/),
Akita presents a test-first bug fix as a small proof that first demonstrates the
uncertainty and then proves the correction. He similarly recommends time-bounded
proofs of concept for costly unknowns rather than long commitments based on
opinion.

**Recommendation:** characterize the current JSON/selection/install behavior
before changing it. Use a throwaway, bounded spike only for the unresolved HTTP
resume design; do not merge the spike as production architecture unless it
demonstrates interruption and byte-identical recovery against a controlled
server fixture.

In [Software Nunca Está “Pronto”](https://akitaonrails.com/2026/03/01/software-nunca-esta-pronto-4-projetos-a-vida-pos-deploy-e-por-que-one-shot-prompt-e-mito/),
Akita argues against one-shot delivery and describes production work as repeated
correction, hardening, testing and documentation after the first functioning
version.

**Inference:** a large “models screen” PR can look complete while conflating
catalogue, installation, selection and runtime readiness. Each phase below has a
separate observable result so mistakes surface before they spread across Rust,
FFI and two native UIs.

### Fabio Akita: software economics constrains architecture

In [A Economia do Desenvolvimento de Software](https://akitaonrails.com/2017/06/22/a-economia-do-desenvolvimento-de-software/),
Akita warns that premature microservices, performance machinery and generalized
infrastructure create debt a small team must pay before those choices deliver
value. The practical theme is to constrain time/cost, deliver the smallest
working value and let evidence change priorities.

**Recommendation:** do not add a remote catalogue service, account system,
background daemon, generic plugin marketplace or Python sidecar for this work.
The source catalogue remains shipped with the Rust core. A future signed remote
catalogue would be a separate security/product decision with its own threat
model.

## What official Codex guidance contributes

Official OpenAI guidance supports a phased, repository-grounded execution
process. It does not prescribe the EpubToMp3 architecture or make SOLID a goal
independent of the product behavior.

| Official source | Fact from the source | Application here |
| --- | --- | --- |
| [Iterating Development Workflows with Codex](https://developers.openai.com/cookbook/examples/codex/iterating-development-workflows-with-codex) | `AGENTS.md` is persistent repository guidance; a plan is an optional source of truth for multi-phase work. The recommended phase shape includes explicit scope/non-goals, a read-only preflight, red/green/refactor where appropriate, observed validation evidence and a stop after the selected phase. | Keep stable ownership and safety invariants in `AGENTS.md`. Execute only one roadmap phase per branch/PR, with its own acceptance evidence, instead of asking an agent to implement “the model marketplace” in one pass. |
| [Using PLANS.md for multi-hour problem solving](https://developers.openai.com/cookbook/articles/codex_exec_plans) | Long-running plans should be living documents with context, concrete steps, progress, discoveries, decisions, observable acceptance, idempotence and recovery. The page is archived, so it is supporting workflow guidance rather than current product behavior. | Before phases 1–7, promote the approved slice into a live implementation plan that names exact Rust/FFI/Swift seams, commands and recovery behavior. Update it from execution evidence; do not treat this research report as proof of completion. |
| [Codex Prompting Guide](https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide) | Codex works best with explicit tool-use and verification expectations, efficient context gathering, preservation of repository conventions and completion criteria grounded in working code. | Require each phase to inspect the owning code, reproduce the missing behavior, correct the cause at that seam, run the relevant runtime checks and review the final diff. Avoid speculative adjacent cleanup. |

### Codex execution rule for this roadmap

**Recommendation:** phase 0 is the local red/preflight of phase 1, not a broken
PR. For every subsequent slice:

1. read the current owning modules and applicable project instructions;
2. state scope, non-goals, identities affected and observable acceptance;
3. make the smallest failing runtime/contract test that exposes the missing
   behavior when feasible;
4. implement at the authority that owns the rule, then refactor only proven
   duplication;
5. exercise success and relevant failure/cancellation/identity paths;
6. inspect the final diff for accidental policy duplication and unrelated work;
7. commit and review only the coherent, passing slice.

This is the operational meaning of “correct implementation” here: preserve the
working repository shape, fix the cause instead of a UI symptom, and require
executed evidence before calling a phase complete.

## What official Claude Code guidance contributes

Official Claude Code guidance describes how an agent should work; it does not
decide EpubToMp3's product architecture.

| Official source | Fact from the source | Application here |
| --- | --- | --- |
| [Best practices for Claude Code](https://code.claude.com/docs/en/best-practices) | Separate exploration, planning, implementation and delivery for uncertain multi-file work; give the agent an executable verification oracle and require evidence. Planning adds unnecessary overhead for small obvious work. | Use this report as the cross-cutting plan, then implement each small phase directly. Every phase names an observable oracle; no phase is “done” because code compiles. |
| [How Claude remembers your project](https://code.claude.com/docs/en/memory) | `CLAUDE.md`/`AGENTS.md` are context, not enforcement. Concrete, verifiable instructions are more reliable than vague principles; procedures and localized knowledge should be loaded on demand. | Keep stable invariants in `AGENTS.md`; keep schema details and migration steps in focused docs/tests. Enforce hashes, HTTPS, identity and explicit installation in Rust, not prose. |
| [How Claude Code works](https://code.claude.com/docs/en/how-claude-code-works) | The loop gathers context, acts and verifies, then repeats. Skills are loaded on demand and subagents isolate disposable context. | Inspect the owning seam before each slice, run its focused checks, inspect the diff and only then continue. |
| [Common workflows](https://code.claude.com/docs/en/common-workflows) | Refactor in small testable increments; describe behavior, edge cases and errors in tests; follow repository patterns. | Add characterization/contract tests before replacing v2 consumers. Do not invent a parallel architecture. |
| [Create custom subagents](https://code.claude.com/docs/en/sub-agents) | Subagents suit bounded lateral research or independent verification with fresh context. | Use one for licence/artifact audits or independent diff review, not for concurrent edits to the same Rust/Swift seam. |
| [Run agents in parallel](https://code.claude.com/docs/en/agents) | Parallel work needs separable ownership and adds coordination/context cost. | Catalogue schema must land before dependent FFI and Apple projections. Parallelize source audits or disjoint tests only. |

### What belongs in project instructions

**Recommendation:** retain only durable rules such as these in canonical project
instructions:

- shared conversion/model policy belongs in Rust;
- model installation is always an explicit user action;
- installation never changes active selection;
- preserve installed models and verified artifacts;
- identity uses literal model/revision/voice IDs, never display labels;
- a new seam requires two real adapters;
- success, failure, cancellation and identity behavior need runtime tests.

Do not add field-by-field schema documentation, temporary migration steps,
individual model hashes or a phase checklist to `AGENTS.md`. Those belong beside
the module or in a scoped implementation plan. Deterministic invariants must be
implemented and tested; prose alone cannot enforce them.

## Reddit signals: useful questions, not authority

The following are self-reported experiences without controlled experiments.
They do not override source evidence, project policy or official documentation.

| Discussion | Anecdotal signal | Question it adds to review |
| --- | --- | --- |
| [How do you use Claude Code for professional software engineering?](https://www.reddit.com/r/ClaudeCode/comments/1x3f7yw/how_do_you_use_claude_code_for_professional/) (2026-10-11) | A generic “use OOP/SOLID/patterns” prompt reportedly oscillated between no structure and trivial classes. Respondents preferred real repository boundaries and requiring each interface to justify itself. | Does the proposed module remove policy from multiple callers, or merely rename pass-throughs? |
| [How to avoid overengineering?](https://www.reddit.com/r/ClaudeCode/comments/1uepqau/how_to_avoid_overengineering/) (2026-06-24) | Commenters report that design review before code and periodic simplification reduce unnecessary agent output; several distinguish written guidance from deterministic gates. | Which catalogue rules can be made impossible to violate in Rust types/tests rather than requested in prompts? |
| [The hidden cost of coding with AI: overconfidence, overengineering… and wasted time](https://www.reddit.com/r/ClaudeCode/comments/1mhn6la/the_hidden_cost_of_coding_with_ai_overconfidence/) (2025-08-04) | The author reports adopting an architecture they did not understand and later reverting it; discussion invokes YAGNI and waiting for concrete repetition before generalizing. | Is a proposed abstraction required by Faber plus an existing second case, or by an imagined marketplace? |
| [Are y'all overengineering or am I not unlocking Claude's full potential](https://www.reddit.com/r/ClaudeAI/comments/1us0h97/are_yall_overengineering_or_am_i_not_unlocking/) (2026-07-09) | Users report better outcomes with small issues, explicit expected results, fresh contexts and selective delegation; others warn that autonomy can add visible process without better code. | Can the slice be reviewed and accepted independently, with a user-visible result or contract fixture? |

These discussions reinforce questions already justified by stronger evidence;
they are not evidence that a particular class layout or workflow is correct.

## Current repository state

### Facts: catalogue and selection

1. [`model_catalog.rs`](../../crates/converter-core/src/model_catalog.rs)
   defines `MODELS`, artifact URLs, SHA-256 values, byte counts, platforms,
   base-language strings, ranking and `runtime_available`.
2. [`tts_session/catalog.rs`](../../crates/converter-core/src/tts_session/catalog.rs)
   builds a second, versioned catalogue projection. It derives runtime and a
   revision string from `MODELS`, then adds provider descriptors and default
   selection.
3. [`model_catalog_boundary.rs`](../../crates/converter-ffi/src/model_catalog_boundary.rs)
   exports both raw `converter_tts_models_json()` and enriched
   `converter_tts_catalog_json_v2()` views.
4. [`TtsCatalog.swift`](../../ios/EpubToMp3/EpubToMp3/Features/Conversion/Services/TtsCatalog.swift)
   decodes the v2 projection but exposes only a subset of model metadata. Its
   `selections(platform:)` filters by platform and `runtimeAvailable == true`;
   it does not require installable artifacts, installed integrity, readiness,
   exact language, licence acceptance or a valid voice.
5. `piper-default` is marked `runtime_available: true` in `MODELS` but has an
   empty artifact list. It can therefore appear selectable in the Swift filter
   even though a catalogue-manifest installation will reject an empty manifest.
6. Language compatibility currently reduces a request such as `pt-BR` to `pt`
   and descriptors record `pt`. That is adequate for broad routing but is not
   evidence that an exact artifact, frontend and voice were validated for
   Brazilian Portuguese.
7. Session identity already preserves provider, runtime, model ID, model
   revision and voice, and rejects conflicting resolved identity. This is a
   strong base to preserve rather than replace.

**Inference:** `MODELS` is close to the authoritative source, while the raw and
v2 JSON forms are projections. The problem is not “two unrelated databases,”
but that two public contracts expose different meanings and Swift must compose
facts that Rust already owns. Adding a third independent catalogue file would
make this worse.

### Facts: installation and installed state

1. [`model_installation.rs`](../../crates/converter-core/src/model_store/model_installation.rs)
   already requires HTTPS and SHA-256, writes into a staging directory, and
   replaces the target only after every artifact validates. A previous target is
   kept through a backup/swap sequence during publication.
2. The catalogue manifest rejects unknown IDs before network access. Existing
   Rust/FFI tests cover HTTPS, missing checksums, invalid artifact names,
   corrupted artifacts, exact pinned Piper hashes and unknown models.
3. The inspected install interface does not expose a disk-space preflight,
   byte/stage progress, cancellation or resumable HTTP state.
4. The current blocking FFI is documented for a client background worker, but
   it returns only final success/error. It has no operation handle or event
   stream.
5. [`LocalSpeechModelReadiness.swift`](../../ios/EpubToMp3/EpubToMp3/Shared/Configuration/LocalSpeechModelReadiness.swift)
   reads filesystem metadata independently. Its generic check trusts recorded
   hashes plus file presence; its Faber-specific helper duplicates the exact
   Faber hashes already owned by Rust and checks only nonzero file size.

**Inference:** download integrity and atomic publication already belong to a
deep Rust implementation. Progress/cancellation should deepen that module, not
move networking into Swift. Apple filesystem checks cannot be the authority for
cryptographic installed state.

### Facts: Apple presentation and labels

1. [`AppSpeechPreferences.swift`](../../ios/EpubToMp3/EpubToMp3/Shared/Configuration/AppSpeechPreferences.swift)
   displays a selected model ID directly when a versioned selection exists.
2. iOS and macOS Settings currently construct `ConverterFFIAdapter` directly in
   their catalogue/install flows. They also own background task/error UI
   behavior.
3. macOS Settings contains a literal “Faber medium” row and a Piper-specific
   install button. The button state comes from Swift readiness rather than one
   Rust snapshot.
4. `TtsCatalog.Model` does not decode user-facing model name, exact locale,
   quality, named voice choices, installed state, readiness state, licence or
   download/installed size.
5. The native tests already preserve selection identity across JSON snapshots,
   reject unsupported catalogue versions and ensure preference changes do not
   mutate already captured jobs.

**Inference:** the UI cannot produce trustworthy model/voice labels from the
current decoded contract. Adding a Swift dictionary from IDs to names would
repeat the Faber-hash problem in a new form.

## Existing invariants that constrain the design

The roadmap must preserve these current project contracts:

- Rust owns conversion, provider/model selection, progress, cancellation and
  artifacts. Apple clients are adapters, not alternate policy owners.
- Piper `pt_BR-faber-medium` remains the default primary candidate; installed
  system speech is the fallback. Edge needs explicit consent and remains off by
  default.
- A model is never downloaded implicitly. Installation requires an explicit
  user action, preserves existing models and must not require a paid provider.
- An explicit per-job selection is authoritative. Installation, catalogue
  refresh or fallback cannot silently replace it.
- Active provider and voice must remain distinguishable from configured primary
  selection during fallback.
- Shared model behavior belongs in Rust before client projections.
- Apple compatibility includes iOS 15.0 deployment and required acceptance on
  iPhone SE (1st generation)/iOS 15.5. Simulator execution is currently
  quarantined; unavailable acceptance stays pending rather than being replaced
  by a newer device.
- Native model downloads or new benchmarks require their own explicit execution
  scope. Implementing a button does not authorize downloading a model during
  development or tests.

## Domain model: separate facts that currently blur together

The catalogue should make the following states impossible to confuse:

| Domain fact | Meaning | Must not imply |
| --- | --- | --- |
| Catalogue entry | The app knows an immutable model descriptor. | Installed, accepted, compatible or ready. |
| Distribution | Exact downloadable artifacts, sizes, hashes and licence evidence exist. | User consent or completed download. |
| Compatible | The exact model/runtime/target/language policy permits use. | Files exist or runtime can load them. |
| Installed | Every required artifact matches its pinned identity. | Runtime initialization succeeds. |
| Ready | Runtime probe accepted the verified installation on this device. | It is selected. |
| Accepted | Required licence terms fingerprint was explicitly accepted. | Files are installed or model is selected. |
| Selected | The user/job captured a literal provider/model/revision/voice identity. | That identity may be silently substituted. |
| Active | A prepared session actually resolved to a provider/model/voice. | It is the configured primary during fallback. |

**Recommendation:** these should be explicit fields/enums in one versioned
snapshot rather than inferred from `runtime_available`, file existence or label
text.

## Proposed Rust deep module

### Seam and responsibility

Create or evolve one concrete `SpeechModelLibrary` module at the existing
catalogue/store seam. The name is illustrative; the implementation should use
the project's chosen domain vocabulary. Its interface should hide:

- static catalogue composition;
- exact target/language compatibility;
- distribution and licence metadata;
- artifact revision derivation;
- installed-integrity inspection;
- download staging, hashing and atomic publication;
- runtime readiness projection;
- progress, cancellation and cleanup semantics.

The interface should not expose `reqwest`, temporary paths, JSON dictionaries or
client-specific labels. Its deletion test is strong: without it, each client
would need to reproduce compatibility, integrity, state combination and install
transactions.

### Minimal external interface

Use concrete Rust types first, not a trait:

```rust
pub struct SpeechModelLibrary { /* private implementation */ }

impl SpeechModelLibrary {
    pub fn snapshot(&self, query: CatalogQuery) -> Result<SpeechModelSnapshot, ModelError>;

    pub async fn install(
        &self,
        request: InstallRequest,
        progress: impl FnMut(InstallProgress),
        cancellation: &CancellationToken,
    ) -> Result<InstallReceipt, ModelError>;

    pub async fn remove(&self, request: RemoveRequest) -> Result<RemoveReceipt, ModelError>;
}
```

This is a design sketch, not a required signature. The important properties are:

- `snapshot` returns one internally consistent view, not separate catalog/readiness
  calls that can race or disagree;
- install takes a catalogue model ID and root, never an arbitrary URL/hash from
  the Apple UI;
- progress is monotonic and structured by stage and byte counts;
- cancellation has a defined result and leaves the previous verified model
  usable;
- receipts return literal identities and verified artifacts;
- removal refuses an active/in-use identity and never broad-deletes a root.

Do not create `SpeechModelLibraryProtocol`, `ModelDownloader`,
`VoiceLabelProvider` or a provider factory in phase 1. A local HTTP fixture can
exercise the real downloader without exposing an external seam. Introduce a
port only if a second real transport or store adapter is accepted.

### Snapshot contract

The next versioned snapshot should preserve stable identity separately from
presentation:

```text
schema_version
generated_from_catalog_revision
target { platform, os_version, architecture }
entries[]
  identity { provider, runtime, model_id, model_revision }
  presentation { model_name, voice_choices[], quality }
  language_evidence { exact_tags[], frontend, validation_status }
  distribution { installable, artifacts[], download_bytes, installed_bytes }
  licence { id, category, evidence_url, terms_fingerprint, requires_acceptance }
  compatibility { compatible, reasons[] }
  installation { state, verified_revision, installed_bytes }
  readiness { state, active_runtime_revision, failure }
  selection { selectable, reasons[] }
```

Field names are provisional. Required semantics:

- `model_id`, `model_revision` and `voice_id` are opaque identity, never labels;
- exact `pt-BR` evidence is stored when that exact artifact/frontend/voice was
  validated; a broad `pt` family can be separate routing metadata but cannot
  masquerade as validation;
- `installable` is explicit and false for provider placeholders such as the
  current artifact-less `piper-default`;
- `selectable` is derived from compatibility, licence, installation and
  readiness, not from `runtime_available` alone;
- download and installed bytes are distinct, especially for archives;
- a label change does not change cache or selection identity;
- a terms change creates a new fingerprint and invalidates only the applicable
  consent, not installed files or unrelated selections.

### Label ownership

Rust should own factual presentation metadata tied to the artifact: model family
name, speaker/voice name supplied by the model source, quality tier and exact
language evidence. Apple should localize generic UI grammar such as “Medium,”
“Installed,” “Requires 64 MB” and failure text.

For Piper Faber, a client might format the facts as “Faber · Português (Brasil)
· Medium,” while selection persists `pt_BR-faber-medium` and `speaker-0` (if the
runtime truly supports that explicit speaker). The formatted label must never be
parsed back into identity.

Do not expose invented voice choices. A model with one validated implicit voice
should show one factual name and produce `voice: nil` if that is the runtime's
real contract. Numeric speaker IDs become selectable only when the exact
artifact/runtime declares and validates them.

## Proposed Apple deep module

Create one concrete actor or main-actor-owned module, for example
`SpeechModelLibraryClient`, that:

- owns one `ConverterFFIAdapter`/catalogue binding;
- loads and decodes the Rust snapshot;
- exposes immutable native view state;
- accepts `install(modelID:)`, `cancelInstall(modelID:)`, `remove(modelID:)` and
  `select(identity:)` intents as those capabilities land;
- maps structured Rust errors to existing localized presentation;
- refreshes state after receipts rather than guessing from local files.

Settings controllers should render state and forward intent only. They should
not instantiate FFI adapters, hash/inspect files, decide compatibility, or own
download lifecycles.

Use the concrete module in production and tests at first. Inject its concrete
dependencies/closures internally where needed; do not publish a Swift protocol
until a second adapter exists. This follows the project invariant that one
adapter is a hypothetical seam and two adapters are a real one.

## Installation lifecycle

### Transport decision: foreground Rust or Apple background adapter

Apple documents that a background `URLSession` can continue transfers while an
app is suspended and can reconnect the app to them after relaunch
([Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)).
Apple also exposes system-produced resume data for pausing/resuming downloads
([Pausing and resuming downloads](https://developer.apple.com/documentation/foundation/pausing-and-resuming-downloads))
and capacity values intended for important usage
([Checking volume storage capacity](https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity)).

**Fact:** the current Rust `reqwest` implementation is an in-process foreground
transport. The inspected interface has no OS background-transfer reassociation.

**Recommendation:** decide the product requirement before phase 4:

- If foreground-only download is acceptable, keep `reqwest` inside the deep
  Rust module; it is the smallest architecture.
- If transfer must survive screen lock, suspension or relaunch, define a narrow
  transport seam because two real adapters now exist: `reqwest` for portable
  clients/tests and Apple background `URLSession` for Apple. The adapter may
  deliver bytes and OS resume metadata, but Rust must still authorize the
  catalogue URL/revision, validate final size/SHA-256, write the installation
  receipt and atomically publish the verified model.

Do not let `resumeData` become integrity authority. It is transport state, and
the completed artifact still has to match the immutable Rust manifest.

### Required state machine

```text
known → preflighting → downloading → verifying → publishing → installed
              │             │            │            │
              └─────────────┴────────────┴────────────┴→ failed
                            └──────────────→ cancelled
```

Rules:

- preflight validates explicit user intent, catalogue ID, compatibility,
  licence acceptance when required, target root and available space before
  network access;
- required free space includes download, extracted/staging footprint, existing
  version retained for rollback and a bounded safety margin;
- progress reports stage, current artifact, received bytes, total bytes when
  known and verified/published completion;
- cancellation is cooperative during network I/O and between verification and
  publication; once the atomic swap begins, it completes or rolls back;
- failure/cancellation removes only owned staging data and preserves the prior
  verified target;
- process restart detects stale owned staging by manifest identity and applies a
  documented cleanup/resume rule;
- install success writes structured metadata atomically and the subsequent Rust
  snapshot must report the same revision as the receipt.

### Resume is not “keep the `.part` file”

Resuming safely requires all of the following:

- immutable artifact URL/revision and expected full SHA-256;
- server `Accept-Ranges` behavior verified by a controlled integration test;
- stored byte count plus ETag or Last-Modified validator where available;
- rejection of mismatched validators, oversized partials and servers that ignore
  the requested range;
- hashing that covers the complete reconstructed file;
- cancellation/restart tests at several byte boundaries.

Until those conditions pass, restart the current artifact from zero while
preserving completed artifacts in the same verified staging transaction. Do not
advertise “resume” merely because partial bytes survive.

## Phased implementation plan

Each implementation phase from 1 onward is one coherent feature branch/PR under
the repository workflow. Phase 0 is the local pre-implementation red/preflight
inside the phase-1 branch, not a PR that leaves CI failing. A later phase starts
only after the earlier contract is verified.

### Phase 0 — characterize the current seam locally

**Change:** establish the red evidence on the phase-1 branch before production
edits. Do not publish a commit or PR with the required suite failing.

- Freeze representative v2 catalogue JSON for Faber, `piper-default` and one
  incompatible model.
- Prove current model/session identity round-trips Rust → FFI → Swift.
- Add failing characterization for the undesired case: artifact-less
  `piper-default` must not be installable/selectable.
- Add a failing exact-language case showing that broad `pt` is not equivalent to
  validated `pt-BR` evidence.
- Record current Faber label and readiness duplication so removal is observable.

**Acceptance:** focused tests fail for only the intended missing behavior before
the phase-1 production edit, and the same tests pass before the atomic phase-1
commit/PR. Existing selection persistence and fallback tests remain green.

### Phase 1 — one authoritative Rust catalogue snapshot

**Change:** deepen existing `model_catalog`/`tts_session::catalog_json`; add a
new versioned projection without removing v2.

- Define explicit identity, presentation, language-evidence, distribution,
  licence, compatibility and installability types.
- Make artifact-less provider placeholders explicitly non-installable.
- Record exact locale evidence; keep broad routing distinct.
- Derive revision once and reuse it in catalogue, manifests and session capture.
- Validate uniqueness, nonempty labels, immutable HTTPS artifacts, byte totals,
  hash shape and licence fingerprint rules at test time.
- Keep legacy v2 output stable for existing clients.

**Acceptance:** one Rust fixture produces deterministic v3 JSON; Faber is
installable with exact identity, `piper-default` is not; `pt` cannot claim
verified `pt-BR`; v2 compatibility tests pass unchanged.

### Phase 2 — Rust-owned installed/readiness projection

**Change:** extend `ModelStore`/library inspection and the snapshot; no new UI.

- Rehash artifacts through Rust for installed truth.
- Join installed state and runtime readiness into the snapshot without equating
  them.
- Remove no Swift logic yet; compare old/new state in tests or diagnostics.
- Preserve a corrupt/missing/stale-revision reason without exposing private
  filesystem details to UI.

**Acceptance:** valid, missing, corrupted, wrong-revision and runtime-unavailable
fixtures yield distinct states. Inspection performs no network access and never
mutates selection.

### Phase 3 — native labels and read-only model list

**Change:** add the concrete Apple module and render v3 labels/status while the
existing installation call still operates behind it.

- Decode v3 with fail-closed version handling.
- Replace raw model IDs and literal “Faber medium” with factual model/locale/
  quality presentation.
- Route both iOS and macOS Settings through the one Apple module.
- Keep model/voice identity literal in preferences and captured jobs.
- Do not expose unsupported speaker IDs or non-installable entries as actions.

**Acceptance:** native tests prove label changes do not change selection JSON;
Faber shows a human label on both Apple Settings surfaces; unknown/malformed v3
fails without erasing the current preference; iOS/macOS parity is covered.

### Phase 4 — preflight, progress and cancellation

**Change:** deepen the existing Rust install transaction and add an operation
handle/event FFI; Settings only observes it.

- Add exact space preflight and structured failure.
- Add monotonic byte/stage progress.
- Reuse the project's existing cancellation vocabulary where possible.
- Select foreground `reqwest` or the Apple background transport adapter from the
  explicit suspension/relaunch requirement; do not implement both speculatively.
- Guarantee previous-version survival and staging cleanup on failure/cancel.
- Disable duplicate install intent for the same identity while allowing the UI
  to remain responsive.

**Acceptance:** controlled local HTTP tests cover success, HTTP failure,
checksum mismatch, insufficient space, cancellation early/mid/late, duplicate
request and previous-version preservation. Swift tests cover progress ordering,
cancel intent and error rendering. No public model is downloaded by tests.

### Phase 5 — explicit install/remove/select product flow

**Change:** replace the Piper-specific button with catalogue-driven actions.

- Show download size, installed size where known, exact locale/voice evidence,
  licence status and compatibility reason.
- Require an explicit install confirmation; require separate terms acceptance
  only when catalogue metadata says so.
- Keep selection as a separate explicit action after readiness succeeds.
- Refuse removal of an active/in-use model and preserve unrelated models.
- Remove `isFaberInstalled` and direct Settings FFI construction only after the
  snapshot path fully replaces them.

**Acceptance:** install does not select; select does not download; remove does not
touch another model; consent revocation does not corrupt files; fallback still
reports configured versus active voice correctly.

### Phase 6 — resumable downloads, only after a bounded proof

**Change:** implement validator-aware range resume for servers/artifacts proven
to support it.

- First run a time-bounded local-server spike covering interruption, validator
  change, ignored range and final full hash.
- Merge only if the production interface stays small and every failure falls
  back safely to restart.
- Treat per-artifact completed staging reuse separately from intra-file range
  resume.

**Acceptance:** byte-identical reconstructed output, no duplicate bytes, stale
partial rejection, final SHA-256 match, and crash/restart evidence. If the proof
does not justify complexity, retain restart-from-zero and document the decision.

### Phase 7 — additional model/voice families

Only after the Faber vertical slice is complete:

- audit one exact model artifact and licence at a time;
- add exact voice/language evidence and runtime acceptance;
- use the existing VoiceStudio comparison as candidate context, not proof that a
  model is faster ([VoiceStudio reuse analysis](voicestudio-reuse-analysis-2026-10-25.md));
- do not add a runtime trait until a second production adapter genuinely needs
  the same seam.

## Test architecture

### Rust catalogue contract

Test through the public snapshot interface:

- deterministic schema/revision;
- unique literal IDs;
- exact target and locale compatibility;
- broad-language routing cannot become validation evidence;
- artifact-less entries are not installable;
- download/installed sizes and artifact sums are coherent;
- invalid/missing hash, insecure URL, duplicate artifact path and path traversal
  fail before network;
- voice IDs are unique inside a model and labels never participate in identity;
- licence acceptance is keyed by terms fingerprint.

### Rust installation integration

Use a controlled local HTTP server rather than public Hugging Face/GitHub:

- successful multi-artifact install and atomic receipt;
- HTTP status/connection failure;
- short body and checksum mismatch;
- insufficient space before first request;
- cancellation before request, during transfer, after download and before
  publication;
- existing verified target survives every failure;
- concurrent same-ID install is rejected or coalesced deterministically;
- stale staging cleanup respects root/model identity;
- resume cases only when phase 6 is authorized.

The interface is the test surface. Avoid unit tests that reach past it into temp
file naming or private helper call order unless a low-level security invariant
cannot be observed otherwise.

### FFI contract

- owned JSON/string/event memory is freed exactly once;
- unknown model and unsupported schema fail closed;
- operation handle identity prevents cross-cancel/cross-progress;
- progress ordering remains monotonic across the language boundary;
- cancellation and failure preserve native error category/details;
- v2 remains callable until every supported client migrates.

### Native Apple tests

- decode the real Rust-produced fixture rather than a Swift-invented shape;
- human label and literal identity remain distinct;
- iOS and macOS present the same model state/actions;
- install, cancel, retry, select and remove actions call the concrete module once
  and update from the returned snapshot;
- corrupt/unknown catalogue does not erase persisted selection;
- fallback UI distinguishes configured primary from active voice;
- Settings production changes have XCTest coverage, not Swift-source parsing.

### Runtime acceptance

- focused Rust and FFI tests prove contracts, not native UI/runtime behavior;
- the native macOS app must visibly exercise list → explicit install confirmation
  → progress/cancel or completed install → explicit selection, with a deliberately
  authorized fixture/model;
- required SE1/iOS 15.5 acceptance remains pending while Simulator use is
  quarantined; another device is not a substitute;
- no model download or benchmark is implied by implementation authorization.

## Acceptance criteria for the complete program

The work is complete only when all are true:

1. One Rust source produces the client catalogue/session projection and install
   manifest identity.
2. No Apple production file contains Faber artifact hashes or uses model IDs as
   the primary user-facing label.
3. `piper-default` and every artifact-less entry are visibly non-installable.
4. Exact `pt-BR` evidence is distinguishable from broad Portuguese routing.
5. Catalogue, compatible, installed, ready, accepted, selected and active are
   observable separate states.
6. Installing is always explicit and never changes selection.
7. Failure/cancellation preserves the previous verified model and removes only
   owned staging.
8. Progress is monotonic and cancellation is identity-safe across FFI.
9. Both Apple Settings surfaces consume one concrete module and preserve literal
   job/session identity.
10. Success, HTTP/checksum/space failure, cancellation, retry, corruption,
    identity and consent cases have tests at the owning runtime.
11. Native macOS acceptance passes; SE1/iOS 15.5 is either passed on the required
    target or reported pending under current safety policy.
12. Final implementation diffs contain no generic marketplace, speculative
    adapter protocol or duplicated catalogue dictionary.

## Risks to reject during review

- **“Just add labels in Swift.”** This creates a second source of artifact truth
  and allows labels to drift from model revision.
- **“Make every model runtime a protocol now.”** There is not yet a second
  accepted production adapter at every proposed seam.
- **“`runtime_available` means selectable.”** It says neither installable,
  installed, ready nor licensed.
- **“`pt` means verified PT-BR.”** It is routing evidence only under the current
  contract.
- **“The `.part` file makes downloads resumable.”** It lacks range and validator
  integrity semantics.
- **“A successful build proves the feature.”** It does not exercise model
  integrity, Settings behavior, cancellation or actual runtime readiness.
- **“One PR is simpler.”** It hides which seam failed and makes identity/
  compatibility regressions harder to isolate.
- **“Put every detail in AGENTS.md.”** Large procedural context competes with the
  task and still does not enforce behavior.

## Open questions requiring product or measured evidence

These do not block phases 0–3 unless noted:

1. What disk-space safety margin should installation reserve on the weakest
   supported Apple device? This blocks final phase-4 policy.
2. Must downloads continue while the app is backgrounded or the screen is
   locked, and must they reconnect after process termination/relaunch? This
   blocks the phase-4 transport seam (`reqwest` only versus Apple background
   `URLSession` adapter with Rust verification/publication).
3. Should a single-voice model display the source model/speaker name (“Faber”)
   or a localized role label (“Narrador Faber”)? Identity is unaffected, but
   product copy needs a decision.
4. Which exact Piper artifacts beyond Faber are approved for download, and what
   licence/provenance evidence is required for each?
5. Is model removal allowed while a captured but not currently running job
   references that model, or only prohibited for an active prepared session?
6. What persistence/retention policy applies to failed staging and resumable
   partials?
7. Do the current Hugging Face artifact endpoints provide stable range validators
   across redirects/CDN behavior? This must be measured before phase 6.
8. What accessible wording and VoiceOver order should distinguish Installed,
   Ready and Selected without overwhelming the Settings screen?
9. SE1/iOS 15.5 runtime acceptance is presently unavailable under Simulator
   quarantine. The implementation must not claim full Apple acceptance until
   that required target is safely reauthorized and exercised.

## Final recommendation

Proceed with phases 0–3 before expanding download mechanics. They solve the
highest-risk correctness problem—multiple meanings and client-owned policy—while
preserving the working installer. Then deepen `ModelStore` with preflight,
progress and cancellation under controlled integration tests. Treat resumable
HTTP and new voice families as separate evidence-driven projects.

This applies SOLID pragmatically: one authority, cohesive responsibilities,
explicit domain states, dependency direction toward Rust, and real seams only.
It also follows the strongest common thread across Akita, OpenAI, Anthropic and
the repository's own invariants: inspect first, implement a small working slice,
verify through an executable oracle, and generalize only after the code proves
where the abstraction belongs.
