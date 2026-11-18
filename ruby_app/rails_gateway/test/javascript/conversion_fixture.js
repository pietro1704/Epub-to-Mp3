// Test-only synthesis for conversion system tests. Served only in the test
// environment (config/environments/test.rb adds test/javascript to the asset
// paths) and named by the conversion-test-fixture meta tag, which the layout
// renders only when Rails.env.test?. It keeps the real Rust session, catalog
// identity, receipts and MP3 encoding, and replaces only model verification
// and Piper inference, so no voice model is needed or downloaded. The real
// worker path is covered by test/system/piper_worker_test.rb.

import { loadConverterRuntime, loadTtsCatalog } from "runtime/converter_runtime"
import { createPiperPreparation, createSynthesis } from "runtime/conversion_runtime"

const SAMPLE_RATE = 22050

/** Tests steer the fixture through this object: failures, delay, observed requests. */
export const control = window.conversionFixture ??= { failNext: 0, delayMs: 0, requests: [] }

/** A short tone, so each segment yields a decodable MP3 with a real duration. */
function tone(seconds = 0.2) {
  return Float32Array.from({ length: Math.round(seconds * SAMPLE_RATE) }, (_, index) =>
    0.2 * Math.sin((2 * Math.PI * 440 * index) / SAMPLE_RATE))
}

export const synthesis = createSynthesis({
  ...createPiperPreparation({ loadCatalog: loadTtsCatalog, verifyModel: async () => {} }),
  piper: {
    synthesize: async (text, modelId, modelRevision, voice) => {
      control.requests.push({ text, modelId })
      if (control.failNext > 0) {
        control.failNext--
        throw new Error("Fixture provider failure")
      }
      if (control.delayMs) await new Promise((resolve) => setTimeout(resolve, control.delayMs))
      const bindings = await loadConverterRuntime()
      return { audio: bindings.encode_pcm_f32_mp3(tone(), SAMPLE_RATE), modelRevision: modelRevision ?? "", voice: voice ?? "0" }
    },
    cancel: () => {},
  },
})
