import { afterEach, describe, expect, it, vi } from "vitest";
import { BrowserNativeSpeech } from "./BrowserNativeSpeech";
function fixture(voices: Partial<SpeechSynthesisVoice>[] = [{ name: "Local", voiceURI: "local", lang: "pt-BR", localService: true }]) {
  const utterances: SpeechSynthesisUtterance[] = [];
  const events = new EventTarget();
  const synthesis = {
    getVoices: vi.fn(() => voices), cancel: vi.fn(), pause: vi.fn(), resume: vi.fn(),
    speak: vi.fn((value: SpeechSynthesisUtterance) => utterances.push(value)),
    addEventListener: events.addEventListener.bind(events), removeEventListener: events.removeEventListener.bind(events),
  };
  const service = new BrowserNativeSpeech(synthesis as unknown as SpeechSynthesis, text => ({ text }) as SpeechSynthesisUtterance);
  return { service, synthesis, utterances, voices, events };
}
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); document.body.innerHTML = ""; });
describe("installed browser narration", () => {
  it("pins compatible local voice, stops existing audio and completes playback only", async () => {
    document.body.innerHTML = "<audio></audio>";
    const pause = vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(() => undefined);
    const { service, synthesis, utterances } = fixture();
    const voice = vi.fn();
    const done = service.speak("Texto", "pt-BR", null, voice);
    expect(pause).toHaveBeenCalledOnce();
    expect(voice).toHaveBeenCalledWith("Local (pt-BR)");
    expect(utterances[0].voice?.voiceURI).toBe("local");
    service.pause(); service.resume();
    expect(synthesis.pause).toHaveBeenCalledOnce(); expect(synthesis.resume).toHaveBeenCalledOnce();
    utterances[0].onend?.({} as SpeechSynthesisEvent);
    await done;
  });
  it("never uses cloud or wrong-region voices and bounds delayed enumeration", async () => {
    vi.useFakeTimers();
    const { service, synthesis } = fixture([
      { lang: "pt-BR", localService: false }, { lang: "pt-PT", localService: true },
    ]);
    const done = service.speak("Texto", "pt-BR", null, vi.fn());
    const assertion = expect(done).rejects.toThrow("No installed offline");
    await vi.advanceTimersByTimeAsync(1500);
    await assertion;
    expect(synthesis.speak).not.toHaveBeenCalled();
  });
  it("waits for asynchronously installed voices without downloading", async () => {
    const { service, voices, events, utterances } = fixture([]);
    const done = service.speak("Texto", "pt-BR", null, vi.fn());
    voices.push({ name: "Offline", voiceURI: "offline", lang: "pt-BR", localService: true });
    events.dispatchEvent(new Event("voiceschanged"));
    await Promise.resolve();
    expect(utterances[0].voice?.voiceURI).toBe("offline");
    utterances[0].onend?.({} as SpeechSynthesisEvent); await done;
  });
  it("rejects errors and ignores cancelled chapter callbacks after a new request", async () => {
    const { service, utterances } = fixture();
    const old = service.speak("Old chapter", "pt-BR", null, vi.fn());
    const cancelled = expect(old).rejects.toMatchObject({ name: "AbortError" });
    service.cancel(); await cancelled;
    const fresh = service.speak("New chapter", "pt-BR", null, vi.fn());
    utterances[0].onend?.({} as SpeechSynthesisEvent);
    const failure = expect(fresh).rejects.toThrow("synthesis-failed");
    utterances[1].onerror?.({ error: "synthesis-failed" } as SpeechSynthesisErrorEvent);
    await failure;
  });
  it("bounds an utterance whose browser callbacks never arrive", async () => {
    vi.useFakeTimers();
    const { service, synthesis } = fixture();
    const done = service.speak("Texto", "pt-BR", null, vi.fn());
    const assertion = expect(done).rejects.toThrow("timed out");
    await vi.advanceTimersByTimeAsync(120_000);
    await assertion;
    expect(synthesis.cancel).toHaveBeenCalledTimes(2);
  });
  it("keeps long pauses resumable without resetting the active playback deadline", async () => {
    vi.useFakeTimers();
    const { service, synthesis, utterances } = fixture();
    let settled = false;
    const done = service.speak("Texto", "pt-BR", null, vi.fn());
    void done.then(() => { settled = true; }, () => { settled = true; });
    await vi.advanceTimersByTimeAsync(30_000);
    service.pause();
    service.pause();
    await vi.advanceTimersByTimeAsync(180_000);
    expect(settled).toBe(false);
    expect(synthesis.cancel).toHaveBeenCalledTimes(1);
    service.resume();
    service.resume();
    await vi.advanceTimersByTimeAsync(89_999);
    expect(settled).toBe(false);
    const assertion = expect(done).rejects.toThrow("timed out");
    await vi.advanceTimersByTimeAsync(1);
    await assertion;
    utterances[0].onend?.({} as SpeechSynthesisEvent);
    expect(synthesis.cancel).toHaveBeenCalledTimes(2);
  });
  it("completes after resuming a long pause and still drains cancellation while paused", async () => {
    vi.useFakeTimers();
    const { service, utterances } = fixture();
    const done = service.speak("Texto", "pt-BR", null, vi.fn());
    void done.catch(() => undefined);
    service.pause();
    await vi.advanceTimersByTimeAsync(180_000);
    service.resume();
    utterances[0].onend?.({} as SpeechSynthesisEvent);
    await done;
    const cancelled = service.speak("Outro texto", "pt-BR", null, vi.fn());
    service.pause();
    const assertion = expect(cancelled).rejects.toMatchObject({ name: "AbortError" });
    service.cancel();
    await assertion;
    await vi.advanceTimersByTimeAsync(180_000);
    expect(vi.getTimerCount()).toBe(0);
  });
  it("drains pending voice readiness on cancellation", async () => {
    const { service, synthesis } = fixture([]);
    const done = service.speak("Texto", "pt-BR", null, vi.fn());
    const cancelled = expect(done).rejects.toMatchObject({ name: "AbortError" });
    service.cancel(); await cancelled;
    expect(synthesis.speak).not.toHaveBeenCalled();
  });
});
