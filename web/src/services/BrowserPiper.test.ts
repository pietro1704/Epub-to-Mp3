import { afterEach, describe, expect, it, vi } from "vitest";
import { cancelPiper, synthesizePiper } from "./BrowserPiper";

class SpeechWorker {
  static instances: SpeechWorker[] = [];
  onmessage?: (event: { data: { wav: ArrayBuffer } }) => void;
  onerror?: (event: { message: string }) => void;
  terminate = vi.fn();
  postMessage = vi.fn();
  constructor() { SpeechWorker.instances.push(this); }
}
afterEach(() => { cancelPiper(); vi.unstubAllGlobals(); SpeechWorker.instances = []; });
describe("browser synthesis worker lifecycle", () => {
  it("cancels an active segment and allows a fresh independent conversion", async () => {
    vi.stubGlobal("Worker", SpeechWorker);
    const first = synthesizePiper("Primeira frase.");
    const rejected = expect(first).rejects.toThrow("cancelled");
    cancelPiper();
    await rejected;
    expect(SpeechWorker.instances[0].terminate).toHaveBeenCalledOnce();
    const next = synthesizePiper("Segunda frase.");
    SpeechWorker.instances[1].onmessage?.({ data: { wav: new Uint8Array([1, 2]).buffer } });
    expect(await next).toEqual(new Uint8Array([1, 2]));
  });
  it("rejects overlapping synthesis instead of running two heavy segments", async () => {
    vi.stubGlobal("Worker", SpeechWorker);
    const active = synthesizePiper("Um segmento.");
    await expect(synthesizePiper("Outro segmento.")).rejects.toThrow("already active");
    SpeechWorker.instances[0].onmessage?.({ data: { wav: new Uint8Array([3]).buffer } });
    await active;
    expect(SpeechWorker.instances).toHaveLength(1);
  });
});
