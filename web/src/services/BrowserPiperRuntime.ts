import createPiperPhonemize from '@diffusionstudio/piper-wasm/build/piper_phonemize.js';
import { env, InferenceSession, Tensor } from 'onnxruntime-web/wasm';

interface PiperConfig {
  audio: { sample_rate: number };
  espeak: { voice: string };
  inference: { noise_scale: number; length_scale: number; noise_w: number };
  speaker_id_map?: Record<string, number>;
}
export interface BrowserPiperAudio {
  samples: Float32Array;
  sampleRate: number;
  modelRevision: string;
  voice: string;
}
export interface BrowserPiperAssets {
  onnxWasm: string;
  phonemizer: string;
}
const bundledAssets: BrowserPiperAssets = { onnxWasm: '/tts/', phonemizer: '/tts/' };
/** One immutable ONNX session, using installed bytes without a remote voice map. */
export class BrowserPiperRuntime {
  private constructor(
    private readonly session: InferenceSession,
    private readonly config: PiperConfig,
    readonly modelRevision: string,
    private readonly assets: BrowserPiperAssets,
  ) {}

  static async prepare(
    modelId: string,
    expectedRevision?: string,
    assets: BrowserPiperAssets = bundledAssets,
  ): Promise<BrowserPiperRuntime> {
    if (
      !modelId ||
      /[\\/]/.test(modelId) ||
      Array.from(modelId).some((character) => character.charCodeAt(0) < 32) ||
      modelId === '.' ||
      modelId === '..'
    )
      throw new Error('Invalid installed model ID');
    const directory = await (await navigator.storage.getDirectory()).getDirectoryHandle('piper');
    const read = async (name: string) =>
      (await (await directory.getFileHandle(name)).getFile()).arrayBuffer();
    // getFileHandle has no create option and this adapter never fetches weights.
    const model = await read(`${modelId}.onnx`);
    const configBytes = await read(`${modelId}.onnx.json`);
    const digest = async (bytes: ArrayBuffer) =>
      Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), (byte) =>
        byte.toString(16).padStart(2, '0'),
      ).join('');
    const revision = `${await digest(model)}:${await digest(configBytes)}`;
    if (expectedRevision && expectedRevision !== revision)
      throw new Error('Installed model revision changed before preparation');
    const config = JSON.parse(new TextDecoder().decode(configBytes)) as PiperConfig;
    if (
      !Number.isInteger(config.audio?.sample_rate) ||
      config.audio.sample_rate < 8000 ||
      config.audio.sample_rate > 96000 ||
      !config.espeak?.voice ||
      !Object.values(config.inference ?? {}).every(Number.isFinite) ||
      !Number.isFinite(config.inference?.noise_scale) ||
      !Number.isFinite(config.inference?.length_scale) ||
      !Number.isFinite(config.inference?.noise_w)
    )
      throw new Error('Unsupported Piper model configuration');
    env.wasm.numThreads = 1;
    env.wasm.wasmPaths = assets.onnxWasm;
    const session = await InferenceSession.create(model, { executionProviders: ['wasm'] });
    return new BrowserPiperRuntime(session, config, revision, { ...assets });
  }

  async synthesize(text: string, requestedVoice?: string): Promise<BrowserPiperAudio> {
    if (!text.trim() || Array.from(text).length > 800)
      throw new Error('Invalid Piper segment length');
    let phonemeIds: number[] | undefined;
    let phonemeError: string | undefined;
    const module = await createPiperPhonemize({
      print: (message: string) => {
        const result = JSON.parse(message) as { phoneme_ids?: number[] };
        phonemeIds = result.phoneme_ids;
      },
      printErr: (message: string) => {
        phonemeError = message;
      },
      locateFile: (name: string) => `${this.assets.phonemizer}${name.split('/').pop()}`,
    });
    module.callMain([
      '-l',
      this.config.espeak.voice,
      '--input',
      JSON.stringify([{ text }]),
      '--espeak_data',
      '/espeak-ng-data',
    ]);
    if (!phonemeIds?.length || phonemeIds.some((id) => !Number.isSafeInteger(id) || id < 0))
      throw new Error(phonemeError ?? 'Piper phonemizer returned no valid IDs');
    const speakers = this.config.speaker_id_map ?? {};
    const speaker = requestedVoice === undefined ? 0 : speakers[requestedVoice];
    if (!Number.isSafeInteger(speaker) || speaker < 0)
      throw new Error('Voice is unavailable in the selected model');
    const feeds: Record<string, Tensor> = {
      input: new Tensor('int64', BigInt64Array.from(phonemeIds, BigInt), [1, phonemeIds.length]),
      input_lengths: new Tensor('int64', BigInt64Array.from([BigInt(phonemeIds.length)]), [1]),
      scales: new Tensor(
        'float32',
        new Float32Array([
          this.config.inference.noise_scale,
          this.config.inference.length_scale,
          this.config.inference.noise_w,
        ]),
        [3],
      ),
    };
    if (this.session.inputNames.includes('sid'))
      feeds.sid = new Tensor('int64', BigInt64Array.from([BigInt(speaker)]), [1]);
    else if (requestedVoice !== undefined)
      throw new Error('This model does not accept a speaker selection');
    const result = await this.session.run(feeds);
    const output = result.output?.data;
    if (!(output instanceof Float32Array))
      throw new Error('Piper returned an unsupported audio tensor');
    return {
      samples: output,
      sampleRate: this.config.audio.sample_rate,
      modelRevision: this.modelRevision,
      voice: Object.keys(speakers).find((key) => speakers[key] === speaker) ?? String(speaker),
    };
  }
  async dispose(): Promise<void> {
    await this.session.release();
  }
}
