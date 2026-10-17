/** Playback only: this service never produces conversion artifacts or advances a job. */
export class BrowserNativeSpeech {
  private generation = 0;
  private rejectPending?: (error: Error) => void;
  private utteranceCleanup?: () => void;
  private voiceWaitCleanup?: () => void;
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
    this.synthesis.cancel();
    this.rejectPending?.(new DOMException("Native playback cancelled", "AbortError"));
    this.rejectPending = undefined;
  }

  pause(): void { this.synthesis.pause(); }
  resume(): void { this.synthesis.resume(); }

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
          const timer = setTimeout(() => { if (generation === this.generation) { this.rejectPending = undefined; this.cancel(); reject(new Error("Native playback timed out")); } }, 120_000);
          this.utteranceCleanup = () => clearTimeout(timer);
          const done = (error?: Error) => {
            clearTimeout(timer);
            if (generation !== this.generation) return;
            this.utteranceCleanup = undefined;
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
