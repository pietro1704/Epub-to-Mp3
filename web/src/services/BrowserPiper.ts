import { browserVoiceId } from './BrowserModelInstallation';
let worker: Worker | undefined;
let sequence = 0;
export interface PiperSynthesis {
  audio: Uint8Array;
  modelRevision: string;
  voice: string;
}
let pending:
  | {
      requestId: number;
      modelId: string;
      modelRevision?: string;
      timer: ReturnType<typeof setTimeout>;
      resolve: (audio: PiperSynthesis) => void;
      reject: (error: Error) => void;
    }
  | undefined;

/** The worker pins installed model bytes; each callback belongs to one request. */
export async function synthesizePiper(
  text: string,
  modelId = browserVoiceId,
  modelRevision?: string,
  voice?: string,
): Promise<Uint8Array> {
  return (await synthesizePiperAudio(text, modelId, modelRevision, voice)).audio;
}
export function synthesizePiperAudio(
  text: string,
  modelId = browserVoiceId,
  modelRevision?: string,
  voice?: string,
): Promise<PiperSynthesis> {
  if (pending) return Promise.reject(new Error('A Piper segment is already active.'));
  if (!worker) {
    const activeWorker = new Worker(new URL('./BrowserPiperWorker.ts', import.meta.url), {
      type: 'module',
    });
    worker = activeWorker;
    worker.onmessage = ({
      data,
    }: MessageEvent<{
      version?: number;
      requestId?: number;
      modelId?: string;
      format?: string;
      audio?: ArrayBuffer;
      error?: string;
      receipt?: { modelRevision: string; voice: string };
    }>) => {
      if (worker !== activeWorker || !pending || data.requestId !== pending.requestId) return;
      const request = pending;
      clearTimeout(request.timer);
      pending = undefined;
      if (
        data.version === 2 &&
        data.format === 'mp3' &&
        data.audio &&
        data.modelId === request.modelId &&
        (!request.modelRevision || data.receipt?.modelRevision === request.modelRevision)
      )
        request.resolve({
          audio: new Uint8Array(data.audio),
          modelRevision: data.receipt?.modelRevision ?? '',
          voice: data.receipt?.voice ?? '0',
        });
      else {
        worker?.terminate();
        worker = undefined;
        request.reject(
          new Error(data.error ?? 'Piper returned no audio with the requested identity.'),
        );
      }
    };
    worker.onerror = ({ message }) => {
      if (worker === activeWorker) cancelPiper(new Error(message));
    };
  }
  return new Promise((resolve, reject) => {
    const requestId = ++sequence;
    const timer = setTimeout(() => {
      if (pending?.requestId === requestId)
        cancelPiper(new Error('Piper synthesis deadline exceeded.'));
    }, 120_000);
    pending = { requestId, modelId, modelRevision, timer, resolve, reject };
    try {
      worker!.postMessage({ version: 2, requestId, text, modelId, modelRevision, voice });
    } catch (error) {
      cancelPiper(error instanceof Error ? error : new Error(String(error)));
    }
  });
}
export function cancelPiper(error = new Error('Piper synthesis cancelled.')): void {
  worker?.terminate();
  worker = undefined;
  if (pending) clearTimeout(pending.timer);
  pending?.reject(error);
  pending = undefined;
}
