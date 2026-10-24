import initWasm, { ConversionSession } from '../wasm/converter_wasm';
import { BrowserTtsPreparationError } from './BrowserTtsFailure';
import { embeddedConverter } from './EmbeddedConverter';
import { cancelPiper, synthesizePiperAudio } from './BrowserPiper';
import { pendingBrowserModelInstallation } from './BrowserModelInstallation';
import { verifyBrowserModel } from './BrowserModelIntegrity';
import { browserSelections, loadTtsCatalog } from './TtsCatalog';
import type { BookTextDocument, TtsPreferences, TtsSelection } from '../types/conversion';

export type InspectedBook = Omit<BookTextDocument, 'jobId'> & { language?: string };
export interface BrowserSegment {
  session_id?: string;
  chapter: number;
  index: number;
  total: number;
  text: string;
  selection: TtsSelection;
  fallback_used: boolean;
}
export interface BrowserSynthesis {
  format: { encoding: 'mp3' };
  audio: Uint8Array;
  identity: {
    selection: import('../types/conversion').TtsSessionSelection;
    runtime_revision: string;
    artifacts: Record<string, string>;
    reusable: boolean;
  };
}
export interface BrowserAudioReceipt {
  version: 2;
  session_id: string;
  source_index: number;
  segment_index: number;
  format: { encoding: 'mp3' };
  identity: BrowserSynthesis['identity'];
}
export interface BrowserSession {
  listening_generation_v2?(): bigint | number;
  audio_duration_seconds_v2?(audio: Uint8Array): number;
  skip_cached_chapter_v2?(chapter: number): void;
  set_listening_position_json_v2?(position: string): void;
  playback_feedback_json_v2?(feedback: string): void;
  observe_generation_v2?(seconds: number, chars: number): void;
  policy_state_json?(): string;
  restore_policy_state_json?(state: string): void;
  next_segment(): string;
  provider_failed(): void;
  accept_audio_v2?(audio: Uint8Array, receipt: string): boolean;
  accept_audio(audio: Uint8Array): boolean;
  chapter_audio(): Uint8Array;
  cancel(): void;
  free?(): void;
}
export interface BrowserRuntime {
  capturePreferences?(preferences: TtsPreferences): Promise<TtsPreferences>;
  validateSelection?(selection: TtsSelection): Promise<void>;
  inspect(file: File): Promise<InspectedBook>;
  create(
    chapters: BookTextDocument['chapters'],
    preferences: TtsPreferences,
    language: string,
    policyState?: string,
  ): Promise<BrowserSession>;
  synthesize(text: string, selection: TtsSelection): Promise<Uint8Array | BrowserSynthesis>;
  cancelSynthesis?(): void;
}
/** Injectable model-readiness I/O keeps the production synthesis boundary testable. */
export function createBrowserSynthesis(
  prepare: (selection: TtsSelection) => Promise<void> = prepareBrowserPiper,
  additionalAdapters: ReadonlyMap<
    string,
    Pick<BrowserRuntime, 'synthesize' | 'cancelSynthesis'>
  > = new Map(),
): Pick<BrowserRuntime, 'synthesize' | 'cancelSynthesis'> {
  let generation = 0;
  const piper: Pick<BrowserRuntime, 'synthesize' | 'cancelSynthesis'> = {
    synthesize: async (text, selection) => {
      const requestedGeneration = generation;
      await prepare(selection);
      if (requestedGeneration !== generation) throw new Error('Piper synthesis cancelled.');
      const prepared = preparedSelections.get(selection.model_id ?? '');
      const audio = await synthesizePiperAudio(
        text,
        selection.model_id ?? undefined,
        selection.session?.model_revision ?? prepared?.selection.model_revision ?? undefined,
        selection.voice ?? undefined,
      );
      if (!prepared) return audio.audio;
      return {
        format: { encoding: 'mp3' },
        audio: audio.audio,
        identity: {
          selection: {
            ...prepared.selection,
            voice: audio.voice,
            model_revision: audio.modelRevision,
          },
          runtime_revision: prepared.runtimeRevision,
          artifacts: prepared.artifacts,
          reusable: true,
        },
      };
    },
    cancelSynthesis: () => {
      generation++;
      cancelPiper();
    },
  };
  if (additionalAdapters.has('piper-web'))
    throw new Error('The Piper browser adapter is already registered');
  const adapters = new Map([['piper-web', piper], ...additionalAdapters]);
  let active: typeof piper | undefined;
  let lease = 0;
  return {
    synthesize: async (text, selection) => {
      const runtime =
        selection.session?.runtime ?? (selection.engine === 'piper' ? 'piper-web' : '');
      const adapter = adapters.get(runtime);
      if (!adapter) throw new Error('The requested browser runtime adapter is unavailable');
      active = adapter;
      const requestedLease = lease;
      try {
        const audio = await adapter.synthesize(text, selection);
        if (requestedLease !== lease) throw new Error('Synthesis cancelled.');
        return audio;
      } finally {
        if (active === adapter) active = undefined;
      }
    },
    cancelSynthesis: () => {
      lease++;
      active?.cancelSynthesis?.();
    },
  };
}
const preparedSelections = new Map<
  string,
  {
    selection: import('../types/conversion').TtsSessionSelection;
    runtimeRevision: string;
    artifacts: Record<string, string>;
  }
>();
async function prepareBrowserPiper(selection: TtsSelection): Promise<void> {
  const catalog = await loadTtsCatalog();
  const model = catalog.models.find(
    (model) => model.id === selection.model_id && model.engine === selection.engine,
  );
  const available = browserSelections(catalog).find(
    (candidate) =>
      candidate.model_id === selection.model_id && candidate.engine === selection.engine,
  );
  if (!model || !available)
    throw new Error('The selected model has no compatible browser audio runtime.');
  if (
    selection.session &&
    (selection.session.runtime !== available.session?.runtime ||
      selection.session.provider !== model.engine ||
      selection.session.model_id !== model.id ||
      selection.session.model_revision !== model.revision ||
      Object.keys(selection.session.options).length > 0)
  )
    throw new Error('The captured model/runtime revision is incompatible with this browser.');
  const installation = pendingBrowserModelInstallation();
  if (installation) await installation;
  await verifyBrowserModel(model);
  const descriptor = catalog.providers.find(
    (descriptor) =>
      descriptor.runtime === available.session?.runtime && descriptor.provider === model.engine,
  )!;
  preparedSelections.set(model.id, {
    selection: available.session!,
    runtimeRevision: descriptor.revision,
    artifacts: Object.fromEntries(
      model.artifacts.map((artifact) => [artifact.name, artifact.sha256]),
    ),
  });
}
export const platformRuntime: BrowserRuntime = {
  capturePreferences: async (preferences) => {
    const choices = browserSelections(await loadTtsCatalog());
    const capture = (selection: TtsSelection): TtsSelection => {
      if (selection.session || selection.engine === 'system') return selection;
      const match = choices.find(
        (choice) => choice.engine === selection.engine && choice.model_id === selection.model_id,
      );
      if (!match?.session) throw new Error('The selected model has no compatible browser runtime');
      return { ...selection, session: { ...match.session, voice: selection.voice } };
    };
    return {
      ...structuredClone(preferences),
      primary: capture(preferences.primary),
      secondary: preferences.secondary ? capture(preferences.secondary) : null,
    };
  },
  validateSelection: async (selection) => {
    const available = browserSelections(await loadTtsCatalog()).find(
      (candidate) =>
        candidate.engine === selection.engine &&
        candidate.model_id === selection.model_id &&
        (!selection.session || candidate.session?.runtime === selection.session.runtime),
    );
    if (!available) throw new Error('The selected model has no compatible browser audio runtime.');
  },
  inspect: (file) => embeddedConverter.inspect(file),
  create: async (chapters, preferences, language, policyState) => {
    await initWasm();
    let session: ConversionSession;
    try {
      session = new ConversionSession(
        JSON.stringify(chapters),
        JSON.stringify(preferences),
        language,
      );
    } catch (error) {
      throw new BrowserTtsPreparationError(String(error));
    }
    if (policyState) {
      if (
        !('restore_policy_state_json' in session) ||
        typeof session.restore_policy_state_json !== 'function'
      ) {
        session.free();
        throw new Error('The embedded converter cannot restore the saved session policy');
      }
      try {
        session.restore_policy_state_json(policyState);
      } catch (error) {
        session.free();
        throw error;
      }
    }
    return session;
  },
  ...createBrowserSynthesis(),
};
