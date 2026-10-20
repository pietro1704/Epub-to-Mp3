# Comparable ebook/audio projects: research and adoption

Research date: 2026-10-15. Repository baseline: `a41b61ffc1` plus unrelated pending
product work, preserved. This directory separates upstream evidence from local
adoption decisions; upstream claims are not local benchmark results.

## Scope

Find useful ideas in live GitHub repositories and Hugging Face projects, compare
them with the existing embedded Rust pipeline and native Apple clients, and
adopt only bounded improvements with compatible licensing and regression tests.
Preserve Piper `pt_BR-faber-medium`, explicit model installation and opt-in Edge
consent. No backend service, paid provider, voice cloning, model downloads or
implicit platform/runtime change is introduced by research.

## Sources and task board

| ID | Owner | Dependency | File / acceptance | Status |
| --- | --- | --- | --- | --- |
| SIM-1 | git_safety | Current architecture | [Converters](converters.md): primary code/docs, revision, licensing and transferable behavior | Researched; no upstream code copied |
| SIM-2 | native_safety | Existing model studies | [Hugging Face](huggingface.md): model/Space deployment, Portuguese/runtime/license gates | Researched; only public text/JSON metadata retrieved |
| SIM-3 | checks_docs | Current reader/playback | [Readers and playback](readers-and-playback.md): concrete UX/state ideas and existing/gap classification | Researched; user prioritizes reading/audio sync |
| SIM-4 | Root | SIM-1..3 | Prioritized adoption matrix, smallest complete slice and exact verification evidence | Verified: six URLs pinned; 20 Rust tests and local preflight pass; reader work remains planned |

## Adoption decisions and verification

User-selected priority: **reading and synchronization with audio**. Put
context-backed resume and a measured sentence-follow audit ahead of export,
pronunciation UI or alternative TTS providers. This selection prioritizes the
larger follow-up work; it does not establish a reader defect or authorize an
unverified UI rewrite.

Continuation: [reading/audio contract audit and pending page-seek correction](reading-audio-contract.md).
The audit traces actual producers/consumers and separates proportional navigation
from measured alignment; its board records native verification independently.

[Native reader theme correction](reader-theme-correction.md) tracks the user's
light/dark follow-up: Apple semantic colors, unchanged native material/transparency
policy, custom reader choices and preserved reading/audio anchors.

Small immediate adoption: pin all six existing Piper ONNX/config URLs in the
Rust catalog to HF revision `c10ece1aade47bb51c153c893d14e5bf8e5b7117`.
Live Hub tree metadata confirmed the three weight sizes/LFS SHA256 values;
retrieving the three small JSON configurations confirmed their bytes and SHA256.
All match the existing catalog. Keep IDs, ranks, checksums, model weights,
installation consent and runtime policy; add no dependency. Run model catalog
and model-store regressions before delivery. This is a metadata/reproducibility
adaptation, not a voice-quality or performance claim.

## Prioritized adoption matrix

| ID / priority | Inspiration | Local decision and acceptance | Status |
| --- | --- | --- | --- |
| ADOPT-1 / now | [HF exact revisions](https://huggingface.co/docs/huggingface_hub/guides/download#from-specific-version), [Pocket provenance locks](huggingface.md#4-import-bundle-provenance-patterns-before-importing-pocket-weights) | Pin the six existing Piper URLs; preserve artifact/model identity, hashes, explicit install and default voice. Verify catalog/manifests and corrupt/missing-artifact tests without weight downloads. | Implemented and Rust-verified |
| READ-1 / first follow-up | [Readest TTS flow](readers-and-playback.md) | Audit existing sentence timing at Rust publication and native playback/follow seams before adding anything. Require correct book/chapter/segment identity through seek, cancellation, interruption and book switch; fall back honestly when timestamps are absent. | [Audited](reading-audio-contract.md); proportional-seek correction tracked separately; measured following still pending |
| READ-2 / first follow-up | [Readium Locator](readers-and-playback.md) | Add a versioned context/resource-backed resume fallback only after the current seam is exercised. Decode old entries; resolve repeated text within the right resource; preserve exact raw offset during chrome transitions. | Confirmed persistence-contract gap; feature not implemented |
| READ-3 / conditional | [Readest timed Media Overlays](readers-and-playback.md) | Assess EPUB-provided text/audio timing separately from generated TTS. Use exact timing when present; do not present estimated speech progress as word alignment. | Feasibility candidate, no dependency or renderer replacement |
| LATER-1 | [Audiobookshelf chapter-end timer](readers-and-playback.md) | Extend the current timer only after boundary behavior across streamed segments is tested on both native apps. | Secondary to selected reading/sync work |
| LATER-2 | [p0n1 filename bounds, ID3 and speech preview](converters.md) | Bound UTF-8 artifact filenames without changing short names/identity; add title/author/track metadata; show the exact speech payload before conversion. Reconcile pending worker ownership first. | Proposed independent slices, not implemented |
| LATER-3 | [Converter pronunciation overrides](converters.md) | Per-book explicit corrections must preserve displayed text and participate in audio cache identity. | Requires product decisions and fixtures; no automatic substitutions |
| DEFER | [HF model/provider alternatives](huggingface.md) | Keep additional models, voice cloning, automatic downloads, Python sidecars and remote audiobook servers outside this adoption. Their deployment/license/latency gates are not proven for this app. | Deferred |

The local embedded pipeline already has progressive publication, receipts,
cancellation and parts of sentence synchronization. Existing native playback
already has rate, skip, resume and timer/fade behavior. Do not turn upstream
feature lists into duplicate implementations.

An additional Rust comparison is
[haydonryan/epub2audiobook](https://github.com/haydonryan/epub2audiobook/blob/0b66c5386635ac9a4996a78916e88c4bc255d822/README.md)
(revision `0b66c5386635ac9a4996a78916e88c4bc255d822`, inspected 2026-10-15).
Its documented workflow separates text extraction/replacement from local TTS
and cover/tag encoding. It reinforces the usefulness of a reviewable speech
payload, but its shell/FFmpeg workflow is not a replacement for the embedded
Rust/native app. [License](https://github.com/haydonryan/epub2audiobook/blob/0b66c5386635ac9a4996a78916e88c4bc255d822/LICENSE.txt).

## Next reading/audio verification slice

READ-1's [contract inventory](reading-audio-contract.md#current-contract) found
no measured sentence timing in the current Rust/FFI audio callback and no visible
consumer of the dormant sentence engine. The continuation addresses demonstrated
pending proportional-seek ownership; it does not introduce sentence following.
The next synchronization feature must first carry actual interval provenance
and book/job/chapter/chunk/text identity across the shared runtime, reject stale
or cancelled events, and keep an honest fallback when timing is absent. Require
Rust contract tests and native XCTest, then verify the exact iPhone SE1/iOS15.5
and macOS apps sequentially with Xcode16.4 and the build/Simulator safeguards.
READ-2 follows the same native gate and preserves reader glyph/viewport invariants.

## Actual verification and limits

- Live primary-source reads inspected the revisions/licenses in the three
  companion reports. No upstream project was executed and no source, model or
  audio asset was copied into the product.
- HF tree metadata at the pinned revision matched all three ONNX sizes and
  LFS SHA256 values. Hashing the three small JSON configs matched all existing
  config SHA256 values and sizes. No model weights or sample audio downloaded.
- Red: `mise run models:catalog:test` ran 19 tests; 18 passed and the new snapshot
  assertion failed on the existing `/resolve/main/` Faber URL.
- Green: the same task passed **20 Rust tests**, zero failures/ignored, after
  the six URLs were pinned and exact voice/artifact identity coverage added.
  Existing missing/corrupt artifact, insecure/path-traversal, unknown-model and
  unverified-runtime cases passed. Builds used one job under the native lease;
  no Apple app or Simulator was launched.
- Changed-file `rustfmt --check`, **26 local documentation links/anchors**, and
  `mise run preflight` passed. The latter ran **65 host tests / 596 assertions**,
  zero failures/errors/skips. Exact output:
  `.reports/similar-projects-checks-20261015-20272-4y7o46/evidence/report.json` and
  `.reports/host-workflow/20261015T172122-20296/results/report.json`.
- Independent review found no catalog correctness blocker or unsupported
  implemented-reader claim. Only metadata sourcing changed; no voice quality,
  speed, native synchronization or remote-availability guarantee is asserted.
  Reader/audio follow-ups are prioritized proposals, with their own native
  acceptance gates. CI was not monitored; existing product edits were preserved.

Similar feature names alone do not establish
equivalent behavior. Copying source or adding a dependency requires its actual
license and transitive/runtime compatibility to be reviewed; an idea can be
independently implemented without importing that source. Weight, model code,
dataset, voice and demo-service licenses are separate questions.
