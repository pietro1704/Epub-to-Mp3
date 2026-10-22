import { EngineOption } from '../types/conversion';

export interface VoiceInfo {
  name: string;
  multilingual: boolean;
  label?: string;
}

export const DEFAULT_VOICE_SUGGESTIONS: Record<string, VoiceInfo[]> = {
  edge: [
    {
      name: 'pt-BR-ThalitaMultilingualNeural',
      multilingual: true,
      label: 'Thalita – pt-BR (multilingual)',
    },
    { name: 'pt-BR-FranciscaNeural', multilingual: false },
    { name: 'en-US-JennyNeural', multilingual: false },
    { name: 'es-ES-ElviraNeural', multilingual: false },
  ],
  piper: [
    { name: 'pt_BR-faber-medium.onnx', multilingual: false },
    { name: 'en_US-lessac-medium.onnx', multilingual: false },
  ],
};

export type KnownEngine = 'edge' | 'piper';

export interface EngineInsights {
  defaultVoice: string;
  multiLingual: boolean;
  autoLanguage: boolean;
  languages: string[];
}

export const ENGINE_INFO: Record<KnownEngine, EngineInsights> = {
  edge: {
    defaultVoice: 'pt-BR-ThalitaMultilingualNeural',
    multiLingual: true,
    autoLanguage: true,
    languages: ['auto'],
  },
  piper: {
    defaultVoice: 'pt_BR-faber-medium.onnx',
    multiLingual: false,
    autoLanguage: true,
    languages: ['pt', 'en'],
  },
};

export const FALLBACK_ENGINE_META: EngineInsights = {
  defaultVoice: '',
  multiLingual: true,
  autoLanguage: true,
  languages: ['auto'],
};

export interface QueuedFileEntry {
  id: string;
  file: File;
  name: string;
  size: number;
  uploadId?: string;
  status: 'uploading' | 'ready' | 'error';
  error?: string;
  attemptId?: number;
  bookTitle?: string;
  bookAuthor?: string;
  coverUrl?: string;
  detectedLanguage?: string;
  /** Desktop only: absolute path of the source file. Retained so we can
   *  re-register an expired upload automatically without user action. */
  localPath?: string;
}

export const SUPPORTED_BOOK_EXTENSIONS = new Set(['.epub', '.pdf']);

export function getEngineMeta(engine: EngineOption): EngineInsights {
  if ((ENGINE_INFO as Record<string, EngineInsights>)[engine]) {
    return (ENGINE_INFO as Record<string, EngineInsights>)[engine];
  }
  return FALLBACK_ENGINE_META;
}
