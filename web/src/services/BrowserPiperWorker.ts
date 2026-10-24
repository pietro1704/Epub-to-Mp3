import * as converter from '../wasm/converter_wasm';
import { BrowserPiperRuntime } from './BrowserPiperRuntime';

const port = self as unknown as {
  onmessage:
    | ((
        event: MessageEvent<{
          version: number;
          requestId: number;
          text: string;
          modelId: string;
          modelRevision?: string;
          voice?: string;
        }>,
      ) => void)
    | null;
  postMessage(message: unknown, transfer?: Transferable[]): void;
};
let prepared: { key: string; runtime: BrowserPiperRuntime } | undefined;
port.onmessage = async ({ data }) => {
  try {
    if (data.version !== 2) throw new Error('Unsupported synthesis contract');
    const key = JSON.stringify([data.modelId, data.modelRevision]);
    if (prepared?.key !== key) {
      const previous = prepared;
      prepared = {
        key,
        runtime: await BrowserPiperRuntime.prepare(data.modelId, data.modelRevision),
      };
      await previous?.runtime.dispose();
    }
    const audio = await prepared.runtime.synthesize(data.text, data.voice);
    await converter.default();
    if (!('encode_pcm_f32_mp3' in converter) || typeof converter.encode_pcm_f32_mp3 !== 'function')
      throw new Error('The embedded converter does not support float PCM');
    const mp3: unknown = converter.encode_pcm_f32_mp3(audio.samples, audio.sampleRate);
    if (!(mp3 instanceof Uint8Array))
      throw new Error('The embedded converter returned invalid MP3');
    const encoded = mp3.slice().buffer as ArrayBuffer;
    port.postMessage(
      {
        version: 2,
        requestId: data.requestId,
        modelId: data.modelId,
        format: 'mp3',
        audio: encoded,
        receipt: { runtime: 'piper-web', modelRevision: audio.modelRevision, voice: audio.voice },
      },
      [encoded],
    );
  } catch (error) {
    port.postMessage({ version: 2, requestId: data.requestId, error: String(error) });
  }
};
