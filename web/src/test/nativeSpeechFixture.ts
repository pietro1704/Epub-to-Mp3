import { vi } from 'vitest';
import { BrowserNativeSpeech } from '../services/BrowserNativeSpeech';

export function nativeSpeechFixture() {
  const utterances: SpeechSynthesisUtterance[] = [];
  const voice = {
    name: 'Luciana',
    lang: 'pt-BR',
    voiceURI: 'local-luciana',
    localService: true,
  } as SpeechSynthesisVoice;
  const synthesis = {
    cancel: vi.fn(),
    pause: vi.fn(),
    resume: vi.fn(),
    getVoices: vi.fn(() => [voice]),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    speak: vi.fn((utterance: SpeechSynthesisUtterance) => {
      utterances.push(utterance);
    }),
  };
  const speech = new BrowserNativeSpeech(
    synthesis as unknown as SpeechSynthesis,
    (text) =>
      ({ text, onstart: null, onend: null, onerror: null }) as unknown as SpeechSynthesisUtterance,
  );
  return {
    speech,
    synthesis,
    utterances,
    voice,
    start(index = utterances.length - 1) {
      const utterance = utterances[index];
      utterance.onstart?.call(utterance, new Event('start') as SpeechSynthesisEvent);
    },
    end(index = utterances.length - 1) {
      const utterance = utterances[index];
      utterance.onend?.call(utterance, new Event('end') as SpeechSynthesisEvent);
    },
    fail(message: string, index = utterances.length - 1) {
      const utterance = utterances[index];
      utterance.onerror?.call(utterance, { error: message } as SpeechSynthesisErrorEvent);
    },
  };
}
