import { afterEach, describe, expect, it, vi } from 'vitest';
import { cancelPiper, synthesizePiper } from './BrowserPiper';

class SpeechWorker {
  static instances: SpeechWorker[] = [];
  onmessage?: (event: {
    data: {
      version: number;
      requestId: number;
      modelId: string;
      format: string;
      audio: ArrayBuffer;
    };
  }) => void;
  onerror?: (event: { message: string }) => void;
  terminate = vi.fn();
  postMessage = vi.fn();
  constructor() {
    SpeechWorker.instances.push(this);
  }
}
function reply(index: number, samples: number[], format = 'mp3') {
  const worker = SpeechWorker.instances[index];
  const request = worker.postMessage.mock.calls.at(-1)![0] as {
    requestId: number;
    modelId: string;
  };
  worker.onmessage?.({
    data: { version: 2, ...request, format, audio: new Uint8Array(samples).buffer },
  });
}
afterEach(() => {
  cancelPiper();
  vi.useRealTimers();
  vi.unstubAllGlobals();
  SpeechWorker.instances = [];
});
describe('browser synthesis worker lifecycle', () => {
  it('terminates a runtime that never responds and releases its request lease', async () => {
    vi.useFakeTimers();
    vi.stubGlobal('Worker', SpeechWorker);
    const hung = synthesizePiper('A bounded request.');
    const rejected = expect(hung).rejects.toThrow('deadline exceeded');
    await vi.advanceTimersByTimeAsync(120_001);
    await rejected;
    expect(SpeechWorker.instances[0].terminate).toHaveBeenCalledOnce();
    const next = synthesizePiper('Recovered.');
    reply(1, [1, 2]);
    await expect(next).resolves.toEqual(new Uint8Array([1, 2]));
  });
  it('ignores a late callback from a cancelled worker and rejects undeclared audio', async () => {
    vi.stubGlobal('Worker', SpeechWorker);
    const first = synthesizePiper('First', 'model-a');
    const rejected = expect(first).rejects.toThrow('cancelled');
    cancelPiper();
    await rejected;
    const second = synthesizePiper('Second', 'model-b');
    expect(SpeechWorker.instances[1].postMessage).toHaveBeenCalledWith(
      expect.objectContaining({ version: 2, text: 'Second', modelId: 'model-b' }),
    );
    reply(0, [9], 'mp3');
    SpeechWorker.instances[0].onerror?.({ message: 'Retired worker error' });
    reply(1, [1], 'wav');
    await expect(second).rejects.toThrow('no audio');
  });
  it('cancels an active segment and allows a fresh independent conversion', async () => {
    vi.stubGlobal('Worker', SpeechWorker);
    const first = synthesizePiper('Primeira frase.');
    const rejected = expect(first).rejects.toThrow('cancelled');
    cancelPiper();
    await rejected;
    expect(SpeechWorker.instances[0].terminate).toHaveBeenCalledOnce();
    const next = synthesizePiper('Segunda frase.');
    reply(1, [1, 2], 'mp3');
    expect(await next).toEqual(new Uint8Array([1, 2]));
  });
  it('rejects overlapping synthesis instead of running two heavy segments', async () => {
    vi.stubGlobal('Worker', SpeechWorker);
    const active = synthesizePiper('Um segmento.');
    await expect(synthesizePiper('Outro segmento.')).rejects.toThrow('already active');
    reply(0, [3], 'mp3');
    await active;
    expect(SpeechWorker.instances).toHaveLength(1);
  });
});
