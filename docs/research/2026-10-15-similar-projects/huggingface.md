# Hugging Face patterns worth adopting

> **Research status (reviewed 2026-10-21).** Original proposal retained. The mutable-URL gap below was addressed by the adoption recorded in this [research index](README.md); current [model catalog](../../../crates/converter-core/src/model_catalog.rs) pins Faber revisions. This status note does not add runtime acceptance.

Research date: 2026-10-15. Scope: primary model cards, artifact metadata and actual Space source, compared with the current Rust implementation. This review downloaded only text/JSON metadata; no weights, audio samples, builds or inference were downloaded or executed. Publisher claims are distinguished from local measurements. Current canonical policy remains offline Piper `pt_BR-faber-medium`, optional user-selected providers, consent for Edge, and explicit installation.

## 1. Pin the existing Piper release before adding another provider

The live [Piper repository API](https://huggingface.co/api/models/rhasspy/piper-voices?blobs=true) returned revision `c10ece1aade47bb51c153c893d14e5bf8e5b7117`. Its Faber ONNX LFS metadata reports 63,201,294 bytes and SHA256 `858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7`. The adjacent JSON is 4,855 bytes; hashing its retrieved text gave `7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f`. These exactly match the two checked-in Faber artifact checksums in `crates/converter-core/src/model_catalog.rs`.

The [pinned Faber configuration](https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/faber/medium/pt_BR-faber-medium.onnx.json) specifies `pt_BR`, eSpeak `pt-br`, and 22,050 Hz. The [voice card](https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/faber/medium/MODEL_CARD) identifies one Brazilian Portuguese speaker and CC0 for its dataset. Dataset licensing does not establish the license of the engine, phonemizer, or every redistributed component; preserve their existing notices separately.

**Local gap:** `PIPER_FABER_ARTIFACTS` uses `/resolve/main/` with fixed checksums. Hash checking already prevents accepting altered bytes, but a future upstream replacement can break repeatable installation. `ModelStore::install_manifest` already stages downloads and rejects checksum failures, while `is_manifest_installed` rehashes files. Replacing those two URLs with `/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/` preserves current bytes and policy while making the source reproducible. No new downloader or implicit install is needed.

## 2. Treat first-chunk streaming and complete narration as separate contracts

The actual [Kokoro Space source](https://huggingface.co/spaces/hexgrad/Kokoro-TTS/raw/main/app.py) implements separate `generate_first` and `generate_all` paths. The first returns from inside its generation loop; the second yields successive audio chunks. Its UI cancellation targets the streaming event. It also caps text and initializes English-only pipelines, so a successful demo invocation proves neither complete-book conversion nor Portuguese compatibility.

**Adopt the behavioral distinction, not the Python runtime.** At the Rust worker boundary, acceptance should require an early playable artifact and eventual complete segment coverage, with cancellation stopping subsequent publication. This fits the existing embedded Rust pipeline. Do not copy the demo's text truncation or its silent CPU retry into the product. The local worker already manages artifact receipts and cancellation; a follow-up must inspect the exact publication seam before changing it rather than add a second streaming subsystem.

## 3. Make pronunciation and chunk limits provider-specific

The [Kokoro voice document](https://huggingface.co/hexgrad/Kokoro-82M/raw/main/VOICES.md) explicitly maps Brazilian voices `pf_dora`, `pm_alex`, and `pm_santa` to language `p` and eSpeak `pt-br`. It warns about weak very short utterances and rushed very long utterances, and describes a preferred token range. These are author observations for that model, not universal Piper thresholds or measured results on this app.

The [Kokoro model card](https://huggingface.co/hexgrad/Kokoro-82M/raw/main/README.md) uses a grapheme/phoneme/audio generator and illustrates phoneme annotations. Its original weights are Apache-2.0. [Live metadata](https://huggingface.co/api/models/hexgrad/Kokoro-82M?blobs=true) returned revision `f3ff3571791e39611d31c381e3a41a3af07b4987`; original `kokoro-v1_0.pth` SHA256 is `496dba118d1a58f5f3db2efc88dbdc216e0483fc89fe6e47ee1f2c53f18ad1e4`. That hash identifies the PyTorch artifact, not a quantized ONNX export.

**Local implication:** `adaptive.rs` uses character-based tuning; `kokoro_sherpa.rs` sets one sentence per inference and passes no incremental callback. Do not relabel that API as token-aware streaming. If pronunciation overrides are introduced, store speech text separately from canonical EPUB text and include the selected lexicon version in cache identity. Validate accents, abbreviations, decimals, quotations and names without changing reader text. This is a candidate design, not evidence that current normalization is broken.

## 4. Import bundle provenance patterns before importing Pocket weights

The [unofficial Pocket ONNX export card](https://huggingface.co/Alias-Alias/pocket-3-3-0-tts-onnx/blob/71a4d6d11a76e26b98709fa163477c77d16bdbdb/README.md) describes explicit streaming state, packaged preset voices and bundle schema 3. It labels model/voice provenance separately from MIT upstream code and declares CC BY 4.0 for the model. It specifically disclaims physical-device performance and subjective listening approval. It is an export author's report, not independent verification.

The [pinned Portuguese package manifest](https://huggingface.co/Alias-Alias/pocket-3-3-0-tts-onnx/blob/71a4d6d11a76e26b98709fa163477c77d16bdbdb/pt/package-manifest.json) records language `pt`, upstream commit `3dbee45d343d7dddd0d105468d17f8dcba14db3e`, config SHA256 `5f9cd8b62a6012057b3e22c7d6ea85574de3e7b5e6cebd48ce38cc4f8100e51e`, tokenizer revision, resolved configuration and `insert_bos_before_voice=true`. Its package fingerprint is `7063afacdbdddb72e5b966dcf0b05950ce15e742e1bf536e8ec0140bd328f9f0`; a package fingerprint is not a substitute for verifying every downloaded artifact. [Repository metadata](https://huggingface.co/api/models/Alias-Alias/pocket-3-3-0-tts-onnx?blobs=true) confirms export revision `71a4d6d11a76e26b98709fa163477c77d16bdbdb`.

The actual [source lock](https://huggingface.co/Alias-Alias/pocket-3-3-0-tts-onnx/blob/71a4d6d11a76e26b98709fa163477c77d16bdbdb/source-lock.json) pins Portuguese weights and voice states to `4e1e0a3e611c51c0b4ed8174fc10f32a54644303`; the weights record SHA256 `982369b35c9fce8e8beb027f76c5d15dc0936851d8cb66f75d9678e0e6772b41`. This per-language revision differs from the English revision linked generically by the card, demonstrating why package-level provenance matters. Its tokenizer entry has a null SHA256 and a Git blob ID; the app should retain its stricter complete-artifact SHA256 requirement rather than copy that omission.

**Useful pattern:** model manifest provenance should bind source revision, tokenizer, voice state and schema as one identity. A future Rust adapter must reject unsupported bundle schemas before inference. A `pt` label does not establish Brazilian accent quality. The existing [lightweight-model inventory](../2026-10-14-lightweight-tts-models.md) already documents incompatible Pocket exports; this is no reason to install another package or change provider now.

## 5. Separate model terms, sample code and installation behavior

The [Supertonic 3 card](https://huggingface.co/Supertone/supertonic-3/raw/main/README.md) lists Portuguese `pt`, distinguishes MIT sample code from OpenRAIL-M weights, and shows an SDK quick-start with automatic asset download. Those defaults cannot be copied into this app's explicit-install workflow. A Portuguese language tag and ONNX availability do not establish Brazilian pronunciation, iOS compatibility, or acceptable weak-phone latency.

[Live metadata](https://huggingface.co/api/models/Supertone/supertonic-3?blobs=true) returned revision `3cadd1ee6394adea1bd021217a0e650ede09a323`. One listed artifact, `onnx/duration_predictor.onnx`, is 3,700,147 bytes with SHA256 `c3eb91414d5ff8a7a239b7fe9e34e7e2bf8a8140d8375ffb14718b1c639325db`; this is only one graph and is not the complete model footprint. The [weights' license](https://huggingface.co/Supertone/supertonic-3/blob/3cadd1ee6394adea1bd021217a0e650ede09a323/LICENSE) must be reviewed independently from code and downstream packaging. No new legal conclusion or performance ranking is established here.

## Smallest recommended Rust slice

Hugging Face's [official download guide](https://huggingface.co/docs/huggingface_hub/guides/download#from-specific-version) documents full-length commit revisions as a supported way to request an exact snapshot. The concrete Pocket source lock above illustrates the transferable practice; no Python library needs to be adopted to encode the same revision in Rust HTTPS URLs.

Pin the two existing Faber download URLs to the verified immutable revision while preserving IDs, checksums, output and explicit-install semantics. Exercise `ModelStore::catalog_manifest("pt_BR-faber-medium")` in a network-free Rust regression to verify both immutable URLs and unchanged artifact identity; retain the existing corrupt/missing-artifact coverage. Report no synthesis or device-performance improvement from this configuration change. Any new provider, pronunciation mechanism or streaming redesign requires its own measured acceptance and scope.

Historical notes may contain superseded provider policy; current project instructions take precedence. This document supplements the existing Pocket/Kokoro/Piper research rather than restating benchmark rankings.
