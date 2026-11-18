import test from "node:test"
import assert from "node:assert/strict"
import { assertInstalledModelId, assertSegmentLength, modelRevision, speakerFor, validatedConfig, validatedPhonemeIds } from "./workers/piper_model.js"

const config = { audio: { sample_rate: 22050 }, espeak: { voice: "pt-br" }, inference: { noise_scale: 0.667, length_scale: 1, noise_w: 0.8 } }

test("installed model IDs cannot leave the OPFS piper directory", () => {
  for (const unsafe of [ "", ".", "..", "a/b", "a\\b", "bad\u0001id" ]) assert.throws(() => assertInstalledModelId(unsafe), /Invalid installed model ID/)
  assert.doesNotThrow(() => assertInstalledModelId("pt_BR-faber-medium"))
})

test("model configuration needs a bounded sample rate, an eSpeak voice and finite scales", () => {
  assert.equal(validatedConfig(config), config)
  for (const broken of [
    { ...config, audio: { sample_rate: 4000 } },
    { ...config, audio: { sample_rate: 22050.5 } },
    { ...config, espeak: {} },
    { ...config, inference: { ...config.inference, noise_w: Number.NaN } },
    { ...config, inference: { noise_scale: 1, length_scale: 1 } },
    null,
  ]) assert.throws(() => validatedConfig(broken), /Unsupported Piper model configuration/)
})

test("segments are non-empty and at most 800 code points", () => {
  assert.throws(() => assertSegmentLength("   "), /segment length/)
  assert.doesNotThrow(() => assertSegmentLength("🙂".repeat(800)))
  assert.throws(() => assertSegmentLength("🙂".repeat(801)), /segment length/)
})

test("speaker selection maps names to indices and refuses unknown voices", () => {
  assert.deepEqual(speakerFor(config, undefined), { speaker: 0, voice: "0" })
  const multi = { ...config, speaker_id_map: { ana: 0, bia: 3 } }
  assert.deepEqual(speakerFor(multi, undefined), { speaker: 0, voice: "ana" })
  assert.deepEqual(speakerFor(multi, "bia"), { speaker: 3, voice: "bia" })
  assert.throws(() => speakerFor(multi, "carla"), /Voice is unavailable/)
})

test("phoneme IDs must be non-negative integers and the phonemizer error is surfaced", () => {
  assert.deepEqual(validatedPhonemeIds([ 1, 0, 27 ]), [ 1, 0, 27 ])
  assert.throws(() => validatedPhonemeIds([], "espeak: unknown voice"), /espeak: unknown voice/)
  assert.throws(() => validatedPhonemeIds([ 1, -1 ]), /no valid IDs/)
  assert.throws(() => validatedPhonemeIds(undefined), /no valid IDs/)
})

test("model revision is the SHA-256 of model and configuration joined by a colon", async () => {
  const revision = await modelRevision(new TextEncoder().encode("model").buffer, new TextEncoder().encode("{}").buffer)
  assert.equal(revision, "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
})
