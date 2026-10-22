import initWasm, { ConversionSession } from '../wasm/converter_wasm';
import { embeddedConverter } from './EmbeddedConverter';
import { cancelPiper, synthesizePiper } from './BrowserPiper';
import { browserVoiceId, pendingBrowserModelInstallation } from './BrowserModelInstallation';
import { verifyBrowserFaber } from './BrowserModelIntegrity';
import type { BookTextDocument, TtsPreferences, TtsSelection } from '../types/conversion';

export type InspectedBook = Omit<BookTextDocument, 'jobId'> & { language?: string };
export interface BrowserSegment {
  chapter: number;
  index: number;
  total: number;
  text: string;
  selection: TtsSelection;
  fallback_used: boolean;
}
export interface BrowserSession {
  next_segment(): string;
  provider_failed(): void;
  accept_audio(wav: Uint8Array): boolean;
  chapter_audio(): Uint8Array;
  cancel(): void;
  free?(): void;
}
export interface BrowserRuntime {
  inspect(file: File): Promise<InspectedBook>;
  create(
    chapters: BookTextDocument['chapters'],
    preferences: TtsPreferences,
    language: string,
  ): Promise<BrowserSession>;
  synthesize(text: string, selection: TtsSelection): Promise<Uint8Array>;
  cancelSynthesis?(): void;
}
/** Injectable model-readiness I/O keeps the production synthesis boundary testable. */
export function createBrowserSynthesis(
  prepare: (selection: TtsSelection) => Promise<void> = prepareBrowserPiper,
): Pick<BrowserRuntime, 'synthesize' | 'cancelSynthesis'> {
  let generation = 0;
  return {
    synthesize: async (text, selection) => {
      const requestedGeneration = generation;
      await prepare(selection);
      if (requestedGeneration !== generation) throw new Error('Piper synthesis cancelled.');
      return synthesizePiper(text);
    },
    cancelSynthesis: () => {
      generation++;
      cancelPiper();
    },
  };
}
async function prepareBrowserPiper(selection: TtsSelection): Promise<void> {
  if (selection.engine !== 'piper')
    throw new Error('Edge is unavailable in this browser. Select Faber medium; no server is used.');
  if (selection.model_id !== browserVoiceId)
    throw new Error('Only Faber medium is available in this browser.');
  const installation = pendingBrowserModelInstallation();
  if (installation) await installation;
  const piper = await import('@mintplex-labs/piper-tts-web');
  if (!(await piper.stored()).includes(browserVoiceId))
    throw new Error('Install Faber medium explicitly before converting.');
  await verifyBrowserFaber();
}
export const platformRuntime: BrowserRuntime = {
  inspect: (file) => embeddedConverter.inspect(file),
  create: async (chapters, preferences, language) => {
    await initWasm();
    return new ConversionSession(JSON.stringify(chapters), JSON.stringify(preferences), language);
  },
  ...createBrowserSynthesis(),
};
