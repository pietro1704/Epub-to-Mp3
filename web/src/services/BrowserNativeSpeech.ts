/** Playback only: this service never produces conversion artifacts or advances a job. */
export class BrowserNativeSpeech {
  private generation = 0;
  private rejectPending?: (error: Error) => void;
  private utteranceCleanup?: () => void;
  private voiceWaitCleanup?: () => void;
  private deadline?: { pause: () => void; resume: () => void };
  private paused = false;
  constructor(
    private readonly synthesis: SpeechSynthesis,
    private readonly utterance: (text: string) => SpeechSynthesisUtterance = text => new SpeechSynthesisUtterance(text),
  ) {}

  cancel(): void {
    this.generation++;
    this.voiceWaitCleanup?.();
    this.voiceWaitCleanup = undefined;
    this.utteranceCleanup?.();
    this.utteranceCleanup = undefined;
    this.deadline = undefined;
    this.synthesis.cancel();
    if (this.paused) this.synthesis.resume();
    this.paused = false;
    this.rejectPending?.(new DOMException("Native playback cancelled", "AbortError"));
    this.rejectPending = undefined;
  }

  pause(): void {
    if (this.paused) return;
    this.paused = true;
    this.deadline?.pause();
    this.synthesis.pause();
  }
  resume(): void {
    if (!this.paused) return;
    this.paused = false;
    this.synthesis.resume();
    this.deadline?.resume();
  }

  async speak(text: string, language: string, requestedVoice: string | null, onVoice: (name: string) => void): Promise<void> {
    this.cancel();
    const generation = this.generation;
    const locale = language.replaceAll("_", "-").toLowerCase();
    const compatible = () => this.synthesis.getVoices().filter(voice => {
      const voiceLocale = voice.lang.replaceAll("_", "-").toLowerCase();
      return voice.localService && (voiceLocale === locale || (!locale.includes("-") && voiceLocale.split("-")[0] === locale));
    }).sort((a, b) => {
      const preferred = (value: SpeechSynthesisVoice) => locale === "pt-br" && value.name.toLowerCase().includes("luciana") ? 0 : 1;
      return preferred(a) - preferred(b) || a.voiceURI.localeCompare(b.voiceURI);
    });
    let voices = compatible();
    if (!voices.length) {
      await new Promise<void>((resolve, reject) => {
        this.rejectPending = reject;
        const finish = () => { cleanup(); resolve(); };
        const changed = () => { if (compatible().length) finish(); };
        const timer = setTimeout(finish, 1500);
        const cleanup = () => { clearTimeout(timer); this.synthesis.removeEventListener("voiceschanged", changed); this.voiceWaitCleanup = undefined; };
        this.voiceWaitCleanup = cleanup;
        this.synthesis.addEventListener("voiceschanged", changed);
      });
      voices = compatible();
    }
    if (generation !== this.generation) throw new DOMException("Stale native playback", "AbortError");
    const voice = requestedVoice ? voices.find(value => value.voiceURI === requestedVoice || value.name === requestedVoice) : voices[0];
    if (!voice) throw new Error(`No installed offline system voice for ${language}. Install a compatible voice or use Piper.`);
    // Stop existing book/preview audio before handing the speakers to native speech.
    document.querySelectorAll("audio").forEach(audio => audio.pause());
    onVoice(`${voice.name} (${voice.lang})`);
    // Keep utterances bounded; browsers may truncate very long chapter utterances.
    const chunks = text.match(/[\s\S]{1,400}(?:\s|$)|[\s\S]{1,400}/g) ?? [];
    try {
      for (const chunk of chunks) {
        if (generation !== this.generation) throw new DOMException("Stale native playback", "AbortError");
        await new Promise<void>((resolve, reject) => {
          this.rejectPending = reject;
          const utterance = this.utterance(chunk);
          utterance.voice = voice;
          utterance.lang = voice.lang;
          let remaining = 120_000;
          let started = Date.now();
          let timer: ReturnType<typeof setTimeout> | undefined;
          const clear = () => { clearTimeout(timer); timer = undefined; };
          const arm = () => {
            if (timer !== undefined || this.paused) return;
            started = Date.now();
            timer = setTimeout(() => {
              if (generation === this.generation) {
                this.rejectPending = undefined;
                this.cancel();
                reject(new Error("Native playback timed out"));
              }
            }, remaining);
          };
          this.deadline = {
            pause: () => {
              if (timer === undefined) return;
              remaining = Math.max(0, remaining - (Date.now() - started));
              clear();
            },
            resume: arm,
          };
          this.utteranceCleanup = clear;
          arm();
          const done = (error?: Error) => {
            clear();
            if (generation !== this.generation) return;
            this.utteranceCleanup = undefined;
            this.deadline = undefined;
            this.rejectPending = undefined;
            if (error) reject(error); else resolve();
          };
          utterance.onend = () => done();
          utterance.onerror = event => done(new Error(`Native playback failed: ${event.error}`));
          try { this.synthesis.speak(utterance); } catch (error) { done(error instanceof Error ? error : new Error(String(error))); }
        });
      }
    } finally {
      if (generation === this.generation) this.rejectPending = undefined;
    }
  }
}
let nativeSpeech: BrowserNativeSpeech | undefined;
export function browserNativeSpeech(): BrowserNativeSpeech | undefined {
  if (typeof window === "undefined" || !window.speechSynthesis) return undefined;
  return nativeSpeech ??= new BrowserNativeSpeech(window.speechSynthesis);
}
