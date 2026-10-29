# IOS-18: Brazilian Portuguese Piper voice comparison

Revalidated on 2026-10-29. Product checkout inspected at
`3396d04f7328d42fa410bb97be41854376e71161`. The catalog and Piper decoder files
are unchanged from `f3e46180719f9f304ed242d54784e077bd390f5c`.
This is a metadata/source assessment, not an audible ranking or inference test.

## Recommendation

Retain `pt_BR-faber-medium` as primary, installed system speech as fallback,
and online Edge only with explicit consent. Cadu and Jeff are legitimate
medium-tier comparison candidates; the available evidence does not establish
that either sounds better. First resolve their configuration-decoder blocker,
then compare identical newly synthesized Portuguese prose in the native app
using explicitly installed, verified artifacts. No model selection, installation
or new benchmark follows from this report.

The live upstream repository revision remains
`5041a7a49ae5b3a0f30e6837769eb03fdbb231bd`. Its complete `pt_BR` inventory has
Faber, Cadu, Jeff and Edresson only, matching the product's pinned inventory
`c10ece1aade47bb51c153c893d14e5bf8e5b7117`. There is no `pt_BR` high-tier entry
in that inventory; this is not a claim about every external Piper-compatible
model. [Inventory](https://huggingface.co/rhasspy/piper-voices/blob/5041a7a49ae5b3a0f30e6837769eb03fdbb231bd/voices.json),
[product catalog](https://github.com/pietro1704/Epub-to-Mp3/blob/f3e46180719f9f304ed242d54784e077bd390f5c/crates/converter-core/src/model_catalog/piper_voices.rs).

| Literal identity | Declared tier / rate | ONNX bytes declared in product catalog | Pinned config bytes / speaker map | Assessment |
| --- | --- | ---: | --- | --- |
| `pt_BR-faber-medium` | medium / 22,050 Hz | 63,201,294 | 4,855 / empty object | Retain primary |
| `pt_BR-cadu-medium` | medium / 22,050 Hz | 62,950,044 | 5,040 / null | Candidate, decoder blocker |
| `pt_BR-jeff-medium` | medium / 22,050 Hz | 62,950,044 | 5,041 / null | Candidate, decoder blocker |
| `pt_BR-edresson-low` | low / 16,000 Hz | 63,104,526 | 4,168 / empty object | Excluded by current low-tier policy |

All four pinned configs declare one speaker and eSpeak `pt-br`. Model size and
tier do not measure speech quality, resident memory, startup or iPhone speed.
The ONNX sizes above are catalog declarations, not a fresh payload hash audit.
[Faber config](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/faber/medium/pt_BR-faber-medium.onnx.json),
[Cadu config](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/cadu/medium/pt_BR-cadu-medium.onnx.json),
[Jeff config](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/jeff/medium/pt_BR-jeff-medium.onnx.json),
[Edresson config](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/edresson/low/pt_BR-edresson-low.onnx.json).

Small config responses were fetched anew and SHA-256 recomputed:

- Faber: `7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f`.
- Cadu: `5fe03aa3d4901880554905b12075713cd552598c8a350455a1ec73f8b4e6be19`.
- Jeff: `7bf8145b572b36806f5ce0f1d3322b6711975bc7d0473e8d36fced4a9ec0030d`.

These match the product catalog. ONNX graphs were not fetched or inspected.

## Compatibility and licensing findings

**The earlier report's nullable speaker-map finding is confirmed in source and
fresh metadata.** The vendored `ModelConfig` requires a non-optional
`HashMap<String, i64>` with no nullable/default deserializer. `Piper::new`
deserializes the original JSON before opening ONNX; the embedded native runtime
calls that constructor. Consequently, the unmodified Cadu/Jeff configs are
predicted to fail configuration loading before inference. No Rust test was run
in this assessment. A focused repair should preserve the original immutable
artifact bytes, accept missing/null maps for valid single-speaker configs, and
validate malformed/multi-speaker cases separately. Passing that decoder test
would still not establish successful graph loading or native playback.
[Decoder](https://github.com/pietro1704/Epub-to-Mp3/blob/f3e46180719f9f304ed242d54784e077bd390f5c/native/vendor/piper-rs/src/model.rs),
[constructor](https://github.com/pietro1704/Epub-to-Mp3/blob/f3e46180719f9f304ed242d54784e077bd390f5c/native/vendor/piper-rs/src/lib.rs),
[embedded bridge](https://github.com/pietro1704/Epub-to-Mp3/blob/f3e46180719f9f304ed242d54784e077bd390f5c/native/piper-runtime/src/lib.rs).

Fresh model cards identify CC0 for Faber/Cadu/Jeff's datasets and Lessac-medium
initialization. The product correctly retains dataset/partial provenance rather
than claiming an independently verified unrestricted grant for every model-weight
and training-lineage right. Edresson's dataset card identifies CC BY 4.0 and
Ryan-low initialization. These declarations do not select a better-sounding voice.
[Faber card](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/faber/medium/MODEL_CARD),
[Cadu card](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/cadu/medium/MODEL_CARD),
[Jeff card](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/jeff/medium/MODEL_CARD),
[Edresson card](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/edresson/low/MODEL_CARD).

External Miro and Dii owner revisions remain respectively
`297248553a3da3f3e7fcb0f730685c0997d73d77` and
`38281189bdbc6a0346041925b56da6d71d6fba3d`. Fresh owner cards identify CC BY-NC-ND
4.0 and TigreGotico Lda; their configs declare 22,050 Hz, one speaker,
`quality=training`, and empty speaker maps. A converted mirror's `high` filename
is not an owner's quality measurement or proof of embedded-runtime compatibility.
The older report retained mirrors with differing CC BY-NC-SA declarations; use
owner provenance, not a mirror label, for any later adoption review.
[Miro owner](https://huggingface.co/OpenVoiceOS/pipertts_pt-BR_miro/blob/297248553a3da3f3e7fcb0f730685c0997d73d77/README.md),
[Dii owner](https://huggingface.co/OpenVoiceOS/pipertts_pt-BR_dii/blob/38281189bdbc6a0346041925b56da6d71d6fba3d/README.md).

## Evidence still required

Use the same Portuguese text, punctuation correction, chunk policy, rate,
settings and uncached generation for each candidate. Cover dialogue, questions,
commas, abbreviations, accents and paragraph boundaries. Record actual active
provider, immutable model/config hashes, output validity, fallback, cancellation
and voice-replacement identity. Compare intelligibility, pauses, pronunciation,
artifacts and chunk continuity in the visible native app, with Pietro's listening
preference collected only after objective failures are resolved.

No new audible comparison was performed. No sample audio, ONNX model, dataset,
checkpoint or tool was downloaded; no model installation, compile, synthesis,
benchmark, device or Simulator action occurred. Older Sherpa timings are not
current embedded Piper measurements. Required SE1/iOS 15.5 acceptance remains
blocked by quarantine. No material error was found in the earlier report's
inventory, config hashes or decoder finding; the refined table explicitly labels
ONNX sizes as product declarations rather than freshly verified payloads.
