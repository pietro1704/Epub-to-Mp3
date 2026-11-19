// Piper module worker, version 2 message contract (shared with the React
// worker and rt:piper_client): {version, requestId, text, modelId,
// modelRevision?, voice?} -> {version, requestId, modelId, format: "mp3",
// audio, receipt} or {version, requestId, error}. Rust encodes the MP3.
import initConverter, * as converter from "../wasm/converter_wasm.js"
import { PiperRuntime } from "./piper_runtime.js"

/** @type {{key: string, runtime: PiperRuntime} | undefined} */
let prepared
const port = /** @type {any} */ (self)

port.onmessage = async (/** @type {MessageEvent} */ { data }) => {
  try {
    if (data.version !== 2) throw new Error("Unsupported synthesis contract")
    const key = JSON.stringify([ data.modelId, data.modelRevision ])
    if (prepared?.key !== key) {
      const previous = prepared
      prepared = { key, runtime: await PiperRuntime.prepare(data.modelId, data.modelRevision) }
      await previous?.runtime.dispose()
    }
    const audio = await prepared.runtime.synthesize(data.text, data.voice)
    await initConverter()
    if (typeof converter.encode_pcm_f32_mp3 !== "function") throw new Error("The embedded converter does not support float PCM")
    const mp3 = converter.encode_pcm_f32_mp3(audio.samples, audio.sampleRate)
    if (!(mp3 instanceof Uint8Array)) throw new Error("The embedded converter returned invalid MP3")
    const encoded = mp3.slice().buffer
    port.postMessage({
      version: 2, requestId: data.requestId, modelId: data.modelId, format: "mp3", audio: encoded,
      receipt: { runtime: "piper-web", modelRevision: audio.modelRevision, voice: audio.voice },
    }, [ encoded ])
  } catch (error) {
    port.postMessage({ version: 2, requestId: data.requestId, error: String(error) })
  }
}
