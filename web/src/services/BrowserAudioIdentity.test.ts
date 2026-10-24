import { webcrypto } from 'node:crypto';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
vi.mock('../wasm/converter_wasm', () => ({
  default: vi.fn(),
  tts_request_cache_material_v2: (...args: string[]) => JSON.stringify(args),
}));
import { browserAudioMatches, sealBrowserAudio } from './BrowserAudioIdentity';
import type { StoredBrowserAudio, StoredBrowserJob } from './BrowserJobStore';
import { faber } from './TtsPreferences';

beforeEach(() => vi.stubGlobal('crypto', webcrypto));
afterEach(() => vi.unstubAllGlobals());
function fixture() {
  const source: Pick<StoredBrowserJob, 'document' | 'preferences' | 'language'> = {
    document: {
      jobId: 'book-job',
      bookTitle: 'Fixture',
      chapters: [{ index: 0, name: 'Chapter', text: 'á🙂 original words', charCount: 17 }],
    },
    preferences: { primary: { ...faber }, secondary: null, allow_online_fallback: false },
    language: 'pt-BR',
  };
  const audio: StoredBrowserAudio = {
    chapterIndex: 0,
    name: 'chapter-1.mp3',
    blob: new Blob([new Uint8Array([1, 2, 3])]),
    textOffset: 2,
    chunks: [{ index: 0, text: 'original words', byteOffset: 0, byteLength: 3 }],
    ttsReceipts: [
      {
        version: 2,
        session_id: 'current',
        source_index: 0,
        segment_index: 0,
        format: { encoding: 'mp3' },
        identity: {
          selection: {
            version: 2,
            provider: 'piper',
            runtime: 'piper-web',
            model_id: faber.model_id,
            model_revision: 'sha',
            voice: null,
            options: {},
          },
          runtime_revision: 'runtime-1',
          artifacts: { model: 'sha' },
          reusable: true,
        },
      },
    ],
  };
  return { source, audio };
}

it('seals source, range, model, runtime, voice, settings, receipts and exact bytes', async () => {
  const { source, audio } = fixture();
  audio.cacheIdentity = await sealBrowserAudio(source, audio);
  expect(await browserAudioMatches(source, audio)).toBe(true);
  const changedSource = structuredClone(source);
  changedSource.document.chapters[0].text = 'replaced words';
  expect(await browserAudioMatches(changedSource, audio)).toBe(false);
  const changedSettings = structuredClone(source);
  changedSettings.preferences.primary.voice = 'other';
  expect(await browserAudioMatches(changedSettings, audio)).toBe(false);
  for (const changed of [
    { ...audio, textOffset: 0 },
    { ...audio, blob: new Blob([new Uint8Array([1, 2, 4])]) },
    { ...audio, chunks: [{ index: 0, text: 'different range', byteOffset: 0, byteLength: 3 }] },
    {
      ...audio,
      ttsReceipts: audio.ttsReceipts!.map((receipt) => ({
        ...receipt,
        identity: { ...receipt.identity, runtime_revision: 'other' },
      })),
    },
  ])
    expect(await browserAudioMatches(source, changed)).toBe(false);
});

it('rejects retired sessions and prevents missing V2 metadata from downgrading to legacy', async () => {
  const { source, audio } = fixture();
  audio.ttsReceipts!.push({ ...audio.ttsReceipts![0], segment_index: 1, session_id: 'retired' });
  await expect(sealBrowserAudio(source, audio)).rejects.toThrow('retired');
  source.preferences.primary.session = audio.ttsReceipts![0].identity.selection;
  const unsealed = { chapterIndex: 0, name: 'chapter-1.mp3', blob: audio.blob };
  expect(await browserAudioMatches(source, unsealed)).toBe(false);
  const legacy = structuredClone(source);
  delete legacy.preferences.primary.session;
  expect(await browserAudioMatches(legacy, unsealed)).toBe(true);
});
