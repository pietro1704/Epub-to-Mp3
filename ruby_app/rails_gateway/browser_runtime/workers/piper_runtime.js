// One immutable ONNX session over installed model bytes. Port of
// web/src/services/BrowserPiperRuntime.ts. ONNX Runtime Web and the
// phonemizer are imported as native ES modules from the sibling tts/ subtree
// (ADR R-02); it never fetches weights: models come only from OPFS piper/.
import { env, InferenceSession, Tensor } from "../tts/ort.wasm.min.mjs"
import createPiperPhonemize from "../tts/piper_phonemize.js"
import { assertInstalledModelId, assertSegmentLength, modelRevision, speakerFor, validatedConfig, validatedPhonemeIds } from "./piper_model.js"

const TTS_BASE = new URL("../tts/", import.meta.url).href

/** @param {string} modelId */
async function readInstalled(modelId) {
  const directory = await (await navigator.storage.getDirectory()).getDirectoryHandle("piper")
  // getFileHandle without { create: true } only opens files that exist.
  const read = async (/** @type {string} */ name) => (await (await directory.getFileHandle(name)).getFile()).arrayBuffer()
  return { model: await read(`${modelId}.onnx`), config: await read(`${modelId}.onnx.json`) }
}

export class PiperRuntime {
  /**
   * @param {InferenceSession} session
   * @param {import("./piper_model.js").PiperConfig} config
   * @param {string} modelRevision
   */
  constructor(session, config, modelRevision) {
    this.session = session
    this.config = config
    this.modelRevision = modelRevision
  }

  /**
   * @param {string} modelId
   * @param {string} [expectedRevision] refuses a model replaced since capture
   */
  static async prepare(modelId, expectedRevision) {
    assertInstalledModelId(modelId)
    const installed = await readInstalled(modelId)
    const revision = await modelRevision(installed.model, installed.config)
    if (expectedRevision && expectedRevision !== revision) throw new Error("Installed model revision changed before preparation")
    const config = validatedConfig(JSON.parse(new TextDecoder().decode(installed.config)))
    env.wasm.numThreads = 1
    env.wasm.wasmPaths = TTS_BASE
    const session = await InferenceSession.create(new Uint8Array(installed.model), { executionProviders: [ "wasm" ] })
    return new PiperRuntime(session, config, revision)
  }

  /**
   * @param {string} text
   * @param {string} [requestedVoice]
   * @returns {Promise<{samples: Float32Array, sampleRate: number, modelRevision: string, voice: string}>}
   */
  async synthesize(text, requestedVoice) {
    assertSegmentLength(text)
    /** @type {unknown} */
    let phonemeIds
    /** @type {string | undefined} */
    let phonemeError
    const module = await createPiperPhonemize({
      print: (/** @type {string} */ message) => { phonemeIds = JSON.parse(message).phoneme_ids },
      printErr: (/** @type {string} */ message) => { phonemeError = message },
      locateFile: (/** @type {string} */ name) => `${TTS_BASE}${name.split("/").pop()}`,
    })
    module.callMain([ "-l", this.config.espeak.voice, "--input", JSON.stringify([ { text } ]), "--espeak_data", "/espeak-ng-data" ])
    const ids = validatedPhonemeIds(phonemeIds, phonemeError)
    const { speaker, voice } = speakerFor(this.config, requestedVoice)
    const { noise_scale, length_scale, noise_w } = this.config.inference
    /** @type {Record<string, Tensor>} */
    const feeds = {
      input: new Tensor("int64", BigInt64Array.from(ids, BigInt), [ 1, ids.length ]),
      input_lengths: new Tensor("int64", BigInt64Array.from([ BigInt(ids.length) ]), [ 1 ]),
      scales: new Tensor("float32", new Float32Array([ noise_scale, length_scale, noise_w ]), [ 3 ]),
    }
    if (this.session.inputNames.includes("sid")) feeds.sid = new Tensor("int64", BigInt64Array.from([ BigInt(speaker) ]), [ 1 ])
    else if (requestedVoice !== undefined) throw new Error("This model does not accept a speaker selection")
    const output = (await this.session.run(feeds)).output?.data
    if (!(output instanceof Float32Array)) throw new Error("Piper returned an unsupported audio tensor")
    return { samples: output, sampleRate: this.config.audio.sample_rate, modelRevision: this.modelRevision, voice }
  }

  dispose() { return this.session.release() }
}
