let worker: Worker | undefined;
let pending: { resolve: (wav: Uint8Array) => void; reject: (error: Error) => void } | undefined;

/** One synthesis worker keeps phonemization and ONNX inference off the reader UI. */
export function synthesizePiper(text: string): Promise<Uint8Array> {
  if (pending) return Promise.reject(new Error("A Piper segment is already active."));
  if (!worker) {
    worker = new Worker(new URL("./BrowserPiperWorker.ts", import.meta.url), { type: "module" });
    worker.onmessage = ({ data }: MessageEvent<{ wav?: ArrayBuffer; error?: string }>) => {
      const request = pending;
      pending = undefined;
      if (data.wav) request?.resolve(new Uint8Array(data.wav));
      else {
        worker?.terminate();
        worker = undefined;
        request?.reject(new Error(data.error ?? "Piper returned no audio."));
      }
    };
    worker.onerror = ({ message }) => { cancelPiper(new Error(message)); };
  }
  return new Promise((resolve, reject) => {
    pending = { resolve, reject };
    worker!.postMessage({ text });
  });
}

export function cancelPiper(error = new Error("Piper synthesis cancelled.")): void {
  worker?.terminate();
  worker = undefined;
  pending?.reject(error);
  pending = undefined;
}
