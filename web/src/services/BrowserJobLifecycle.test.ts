import { beforeEach, describe, expect, it, vi } from 'vitest';
vi.mock('../wasm/converter_wasm', () => ({
  default: vi.fn(),
  ConversionSession: vi.fn(),
  inspect_epub: vi.fn(),
}));
import { BrowserConversionClient } from './BrowserConversionClient';
import type { BrowserRuntime, BrowserSession } from './BrowserConversionRuntime';
import { BrowserJobRepository } from './BrowserJobRepository';
import { MemoryBrowserJobStore, type BrowserJobStore } from './BrowserJobStore';
import { faber } from './TtsPreferences';
import type { ConversionFormValues } from '../types/conversion';

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((accept, fail) => {
    resolve = accept;
    reject = fail;
  });
  return { promise, resolve, reject };
}
const preferences = { primary: faber, secondary: null, allow_online_fallback: false };
const document = {
  bookTitle: 'Book',
  chapters: [{ index: 0, name: 'Chapter', text: 'Owned text', charCount: 10 }],
};
function request(): ConversionFormValues {
  return {
    file: new File(['epub'], 'book.epub'),
    engine: 'piper',
    footnoteMode: 'inline',
    tts_preferences: preferences,
  };
}
function session(text: string): BrowserSession {
  let accepted = false;
  return {
    next_segment: vi.fn(() =>
      accepted
        ? 'null'
        : JSON.stringify({
            chapter: 0,
            index: 0,
            total: 1,
            text,
            selection: faber,
            fallback_used: false,
          }),
    ),
    provider_failed: vi.fn(),
    accept_audio: vi.fn(() => {
      accepted = true;
      return true;
    }),
    chapter_audio: vi.fn(() => new Uint8Array([1, 2])),
    cancel: vi.fn(),
    free: vi.fn(),
  };
}
beforeEach(() => {
  let identity = 0;
  URL.createObjectURL = vi.fn(() => `blob:owned-${++identity}`);
  URL.revokeObjectURL = vi.fn();
});

describe('browser job ownership boundaries', () => {
  it('retires a cancelled session created late before leasing the runtime to another job', async () => {
    const creating = deferred<BrowserSession>();
    const entered = deferred<void>();
    const oldSession = session('old text');
    const freshSession = session('fresh text');
    const runtime: BrowserRuntime = {
      inspect: vi.fn(async () => document),
      create: vi
        .fn()
        .mockImplementationOnce(() => {
          entered.resolve();
          return creating.promise;
        })
        .mockResolvedValueOnce(freshSession),
      synthesize: vi.fn(async () => new Uint8Array([3])),
      cancelSynthesis: vi.fn(),
    };
    const client = new BrowserConversionClient(runtime, new MemoryBrowserJobStore());
    const old = await client.submit(request());
    await entered.promise;
    await client.cancel(old.jobId);
    const fresh = await client.submit(request());
    expect(runtime.create).toHaveBeenCalledOnce();
    expect(runtime.cancelSynthesis).not.toHaveBeenCalled();
    creating.resolve(oldSession);
    expect((await client.poll(fresh.jobId, { intervalMs: 1 })).state).toBe('finished');
    expect((await client.fetch(old.jobId)).state).toBe('cancelled');
    expect((await client.fetch(old.jobId)).outputs).toEqual([]);
    expect(await client.getChapterManifest(old.jobId, 0)).toBeNull();
    expect(oldSession.cancel).toHaveBeenCalledOnce();
    expect(oldSession.free).toHaveBeenCalledOnce();
    expect(oldSession.accept_audio).not.toHaveBeenCalled();
    expect(freshSession.cancel).not.toHaveBeenCalled();
    expect(freshSession.free).toHaveBeenCalledOnce();
    expect(runtime.synthesize).toHaveBeenCalledExactlyOnceWith('fresh text', faber);
  });

  it('does not advertise a completed chapter until its audio transaction commits', async () => {
    const publishing = deferred<void>();
    const commit = deferred<void>();
    const durable = new MemoryBrowserJobStore();
    const storage: BrowserJobStore = {
      list: () => durable.list(),
      remove: (id) => durable.remove(id),
      save: async (job) => {
        if (job.audio.length && !job.snapshot.outputs?.length && job.snapshot.state === 'running') {
          publishing.resolve();
          await commit.promise;
        }
        await durable.save(job);
      },
    };
    const active = session('text');
    const runtime: BrowserRuntime = {
      inspect: vi.fn(async () => document),
      create: vi.fn(async () => active),
      synthesize: vi.fn(async () => new Uint8Array([3])),
    };
    const client = new BrowserConversionClient(runtime, storage);
    const { jobId } = await client.submit(request());
    await publishing.promise;
    const pending = await client.fetch(jobId);
    expect(pending.state).toBe('running');
    expect(pending.outputs).toEqual([]);
    expect(pending.chapterProgress?.[0].downloadUrl).toBeUndefined();
    expect((await durable.list())[0].audio).toEqual([]);
    commit.reject(new Error('Audio transaction failed'));
    const failed = await client.poll(jobId, { intervalMs: 1 });
    expect(failed.state).toBe('failed');
    expect(failed.error).toContain('Audio transaction failed');
    expect(failed.outputs).toEqual([]);
    expect(failed.chaptersCompleted).toBe(0);
    expect(active.free).toHaveBeenCalledOnce();
  });

  it('reconciles concurrent callers once and persists only durable audio identity', async () => {
    const store = new MemoryBrowserJobStore();
    await store.save({
      jobId: 'restored',
      snapshot: {
        jobId: 'restored',
        state: 'running',
        outputs: [{ name: 'chapter-1.mp3', url: 'blob:expired' }],
        chapterProgress: [
          {
            index: 0,
            name: 'Chapter',
            chars: 10,
            status: 'processing',
            downloadUrl: 'blob:expired',
          },
        ],
      },
      document: { ...document, jobId: 'restored' },
      preferences,
      language: 'pt-BR',
      audio: [{ chapterIndex: 0, name: 'chapter-1.mp3', blob: new Blob(['audio']) }],
    });
    const list = vi.spyOn(store, 'list');
    const repository = new BrowserJobRepository(store);
    await Promise.all([repository.ensureRestored(), repository.ensureRestored()]);
    expect(list).toHaveBeenCalledOnce();
    const restored = repository.get('restored');
    expect(restored.snapshot.state).toBe('interrupted');
    expect(restored.snapshot.outputs?.[0].url).toBe('blob:owned-1');
    expect(restored.snapshot.chapterProgress?.[0].downloadUrl).toBe('blob:owned-1');
    expect(restored.chunks.get(0)?.chunks[0].url).toBe('blob:owned-1');
    expect(restored.audio.get(0)?.name).toBe('chapter-1.mp3');
    const saved = (await store.list())[0];
    expect(saved.snapshot.state).toBe('interrupted');
    expect(saved.snapshot.outputs?.[0].url).toBe('');
    expect(saved.snapshot.chapterProgress?.[0].downloadUrl).toBeUndefined();
    await repository.remove(restored);
    expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:owned-1');
    expect(await store.list()).toEqual([]);
    expect(() => repository.get('restored')).toThrow('Browser job not found');
  });
});
