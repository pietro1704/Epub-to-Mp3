# Pinned Piper voice artifact and licence audit

Date checked: 2026-10-26.

This audit reads first-party repository metadata, small JSON configurations,
model cards, dataset publishers and the linked model creator. No ONNX payload,
dataset, sample audio or checkpoint was downloaded. No synthesis, benchmark,
runtime test, build or model installation was performed.

## Revision and identity

All Hugging Face paths below refer to `rhasspy/piper-voices` at the immutable
revision `c10ece1aade47bb51c153c893d14e5bf8e5b7117`, which the application already
uses for Faber. ONNX byte counts and SHA-256 values come from each file's `lfs`
entry in the repository tree API. They are declarations by the repository, not
hashes independently recomputed from downloaded model binaries.

Configuration byte counts and SHA-256 values were recomputed from the exact
small `.onnx.json` response bodies. For Cadu, Jeff, Lessac and Davefx, the Git blob
SHA-1 was also recomputed and matched the tree API's `oid`.

Use the literal IDs below for identity. Display names, licence labels and locale
labels must never replace those IDs. Each model has one speaker; none exposes a
named speaker map. The catalogue should represent one unnamed/default voice,
not invent selectable speaker identities from display names.

## Exact artifacts

| Literal ID | Repository directory | ONNX bytes | Config bytes | Total bytes |
| --- | --- | ---: | ---: | ---: |
| `pt_BR-cadu-medium` | `pt/pt_BR/cadu/medium` | 62,950,044 | 5,040 | 62,955,084 |
| `pt_BR-jeff-medium` | `pt/pt_BR/jeff/medium` | 62,950,044 | 5,041 | 62,955,085 |
| `en_US-lessac-medium` | `en/en_US/lessac/medium` | 63,201,294 | 4,885 | 63,206,179 |
| `es_ES-davefx-medium` | `es/es_ES/davefx/medium` | 63,201,294 | 4,817 | 63,206,111 |
| `en_US-ljspeech-medium` | `en/en_US/ljspeech/medium` | 63,531,379 | 4,972 | 63,536,351 |
| `en_US-ljspeech-high` | `en/en_US/ljspeech/high` | 114,199,011 | 4,970 | 114,203,981 |
| `en_GB-cori-medium` | `en/en_GB/cori/medium` | 63,531,379 | 4,966 | 63,536,345 |
| `en_US-kristin-medium` | `en/en_US/kristin/medium` | 63,531,379 | 4,968 | 63,536,347 |

All filenames follow `<literal-ID>.onnx` and `<literal-ID>.onnx.json`.
The immutable download URL is
`https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/<directory>/<filename>?download=true`.

| Literal ID | ONNX SHA-256 | Config SHA-256 |
| --- | --- | --- |
| `pt_BR-cadu-medium` | `765f0809a6ea9035d4a6d0d008dbf8876e68b2dd32029312672fa8f405bdb535` | `5fe03aa3d4901880554905b12075713cd552598c8a350455a1ec73f8b4e6be19` |
| `pt_BR-jeff-medium` | `3a6f4c46355813c2b7bbc4d16b6d13d60ed72074b952a393baace82a7d0c94b5` | `7bf8145b572b36806f5ce0f1d3322b6711975bc7d0473e8d36fced4a9ec0030d` |
| `en_US-lessac-medium` | `5efe09e69902187827af646e1a6e9d269dee769f9877d17b16b1b46eeaaf019f` | `efe19c417bed055f2d69908248c6ba650fa135bc868b0e6abb3da181dab690a0` |
| `es_ES-davefx-medium` | `6658b03b1a6c316ee4c265a9896abc1393353c2d9e1bca7d66c2c442e222a917` | `0e0dda87c732f6f38771ff274a6380d9252f327dca77aa2963d5fbdf9ec54842` |
| `en_US-ljspeech-medium` | `6f52a751e2349abe7a76735eb09dc1875298c77ea2342ffd2fef79ff81b87f22` | `141d612cc0a95ed7efc1ca936b845c2364967f2e9217c5dbfcf69fc4d6c65860` |
| `en_US-ljspeech-high` | `5d4f08ba6a2a48c44592eed3ce56bf85e9de3dd4e20df90541ae68a8310c029a` | `7e1f4634af596d83cca997fb7a931ba80b70f8a316a2655ee69c55365e0ace14` |
| `en_GB-cori-medium` | `1899f98e5fb8310154f3c2973f4b8a929ba7245e722b3d3a85680b833d95f10d` | `e262c16d7f192f69d4edd6b4ef8a5915379e67495fcc402f1ab15eeb33da3d36` |
| `en_US-kristin-medium` | `5849957f929cbf720c258f8458692d6103fff2f0e3d3b19c8259474bb06a18d4` | `5681426d4aead22195de70531eeeeddb46493cfaffc5764b2ea3db73428b651c` |

Primary tree metadata:

- [Cadu](https://huggingface.co/api/models/rhasspy/piper-voices/tree/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/cadu/medium?recursive=false&expand=false)
- [Jeff](https://huggingface.co/api/models/rhasspy/piper-voices/tree/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/jeff/medium?recursive=false&expand=false)
- [Lessac](https://huggingface.co/api/models/rhasspy/piper-voices/tree/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/lessac/medium?recursive=false&expand=false)
- [Davefx](https://huggingface.co/api/models/rhasspy/piper-voices/tree/c10ece1aade47bb51c153c893d14e5bf8e5b7117/es/es_ES/davefx/medium?recursive=false&expand=false)
- [LJSpeech medium](https://huggingface.co/api/models/rhasspy/piper-voices/tree/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/ljspeech/medium?recursive=false&expand=false)
- [LJSpeech high](https://huggingface.co/api/models/rhasspy/piper-voices/tree/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/ljspeech/high?recursive=false&expand=false)
- [Cori medium](https://huggingface.co/api/models/rhasspy/piper-voices/tree/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_GB/cori/medium?recursive=false&expand=false)
- [Kristin medium](https://huggingface.co/api/models/rhasspy/piper-voices/tree/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/kristin/medium?recursive=false&expand=false)

## Declared locale, frontend and speaker evidence

Every inspected configuration declares `phoneme_type: "espeak"`, sample rate
22,050 Hz and `num_speakers: 1`. Configurations declare the quality tier shown in
the ID, including `high` for LJSpeech high. `speaker_id_map` is null for Cadu and
Jeff and `{}` for the other candidates.

| Literal ID | Exact configuration locale | Exact `espeak.voice` | Validation level |
| --- | --- | --- | --- |
| `pt_BR-cadu-medium` | `pt_BR` / `pt-BR` | `pt-br` | Artifact declared |
| `pt_BR-jeff-medium` | `pt_BR` / `pt-BR` | `pt-br` | Artifact declared |
| `en_US-lessac-medium` | `en_US` / `en-US` | `en-us` | Artifact declared |
| `es_ES-davefx-medium` | `es_ES` / `es-ES` | `es` | Artifact declared |
| `en_US-ljspeech-medium` | `en_US` / `en-US` | `en` | Artifact declared |
| `en_US-ljspeech-high` | `en_US` / `en-US` | `en` | Artifact declared |
| `en_GB-cori-medium` | `en_GB` / `en-GB` | `en` | Artifact declared |
| `en_US-kristin-medium` | `en_US` / `en-US` | `en` | Artifact declared |

Preserve the literal frontend from each configuration. In particular, do not
rewrite the English `en` frontend to `en-us` because a model has `en_US` in its
identity. The exact locale is an artifact declaration, not proof of accent,
pronunciation quality, device speed or acceptance in the embedded runtime.

Primary configurations:

- [Cadu](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/cadu/medium/pt_BR-cadu-medium.onnx.json)
- [Jeff](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/jeff/medium/pt_BR-jeff-medium.onnx.json)
- [Lessac](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json)
- [Davefx](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/es/es_ES/davefx/medium/es_ES-davefx-medium.onnx.json)
- [LJSpeech medium](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/ljspeech/medium/en_US-ljspeech-medium.onnx.json)
- [LJSpeech high](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/ljspeech/high/en_US-ljspeech-high.onnx.json)
- [Cori medium](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_GB/cori/medium/en_GB-cori-medium.onnx.json)
- [Kristin medium](https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/kristin/medium/en_US-kristin-medium.onnx.json)

## Licence and training provenance

### Cadu, Jeff, Davefx and the existing Faber baseline

The pinned model cards state `License: CC0` in their **Dataset** section and say
they were fine-tuned from U.S. English Lessac medium. This is evidence of the
declared dataset licence, not a standalone grant covering every right in the
weights and their training lineage. The existing Faber card has exactly the same
dataset/initialization pattern. Retaining a `dataset`/`partial` classification for
new voices is consistent with that baseline; upgrading it to verified permissive
weights is unsupported by these cards.

[OHF Voice Datasets README at commit `1692a7c509e35eceb5d3bd6a7581a104629ded0f`](https://github.com/OHF-Voice/voice-datasets/blob/1692a7c509e35eceb5d3bd6a7581a104629ded0f/README.md)
independently declares CC0 1.0 for its crowdsourced datasets and lists Cadu, Jeff
and Faber. It lists the Spanish dataset as `dave`; the Piper card/configuration
uses `davefx`. Do not erase that provenance distinction.

The relationship between restrictions on Lessac training materials and the
resulting fine-tuned weights is **unresolved by the inspected sources**. This
audit neither asserts that the restrictions legally propagate to all those
weights nor asserts that a CC0 dataset declaration removes that uncertainty.
Dataset claims must remain visibly partial, and runtime validation must remain
separate from licence evidence. A product decision to offer these explicit
downloads does not create a stronger licence grant.

Pinned cards: [Cadu](https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/cadu/medium/MODEL_CARD),
[Jeff](https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/jeff/medium/MODEL_CARD),
[Davefx](https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/es/es_ES/davefx/medium/MODEL_CARD),
[Faber](https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/pt/pt_BR/faber/medium/MODEL_CARD).

### Lessac medium: explicit research-material restriction

The [pinned Lessac model card](https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/lessac/medium/MODEL_CARD)
links the dataset licence to the
[CSTR Blizzard 2013 Research Licence](https://www.cstr.ed.ac.uk/projects/blizzard/2013/lessac_blizzard2013/license.html).
That first-party licence explicitly limits the **Materials** to research,
excludes commercial speech-product/service use, requires a named approved
applicant and restricts distribution without written consent. No form was
submitted and no terms were accepted during this audit.

The material/weights boundary is not resolved by the card. Therefore, do not
advertise this candidate as CC0, public domain or unrestricted and do not assume
a generic in-app acceptance button can grant the third-party licence. Prefer the
from-scratch alternatives below for a general-purpose English voice.

### Cleaner alternatives: LJSpeech, Cori and Kristin

[Bryce Beattie's first-party Piper voice page](https://brycebeattie.com/files/tts/)
identifies LJSpeech medium/high, Cori medium and Kristin as **public-domain voice
models**, explains from-scratch training, permits legal and ethical uses and
explicitly blesses redistribution to Hugging Face. This supplies model-creator
evidence beyond a dataset-only claim. The page describes no Lessac initialization
for these voices.

The [LJ Speech dataset publisher](https://keithito.com/LJ-Speech-Dataset/) states
that its text, audio and annotations are public domain in the US, and notes that
other jurisdictions may differ. Cori and Kristin cards/creator identify LibriVox
recordings as public-domain sources. Do not rename public domain to `CC0-1.0`:
those are distinct legal descriptions.

The pinned [LJSpeech high card](https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/ljspeech/high/MODEL_CARD)
contains a stale training paragraph saying medium/1,000 epochs/22,500 Hz. Its
configuration unambiguously declares high/22,050 Hz; the creator's high entry
describes high/2,000 epochs/22,050 Hz. Record the discrepancy instead of copying
that paragraph into factual application labels.

Other pinned cards: [LJSpeech medium](https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/ljspeech/medium/MODEL_CARD),
[Cori medium](https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_GB/cori/medium/MODEL_CARD),
[Kristin medium](https://huggingface.co/rhasspy/piper-voices/blob/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/kristin/medium/MODEL_CARD).

### Rejected quick alternatives

The pinned Ryan medium card declares a CC BY-NC-SA 4.0 dataset and Lessac
initialization. Amy medium, Alan medium and Thorsten medium also declare Lessac
initialization. They do not provide a cleaner training chain than LJSpeech for
this phase. No exact manifest was promoted for these alternatives.

## Acceptance still required

These are source audits, not runtime acceptance. Before claiming phase-7
completion, the application must verify the downloaded bytes against the pinned
SHA-256, load each exact config/model in its real embedded Piper runtime, exercise
the declared language, validate speaker behavior and measure speed only when a
separate benchmark is authorized. An ONNX extension, generic Piper adapter or
matching sample rate alone cannot establish compatibility or performance.

Tests/builds were intentionally not run because the current request defers them
to the final verification batch. No new runtime, provider factory, paid API or
source-build dependency is required by these candidate artifacts.
