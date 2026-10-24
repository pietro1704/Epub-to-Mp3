import { beforeEach, describe, expect, it, vi } from 'vitest';
import { BrowserJobExecution } from './BrowserJobExecution';
import { BrowserJobRepository } from './BrowserJobRepository';
import { MemoryBrowserJobStore } from './BrowserJobStore';
import type { BrowserRuntime, BrowserSession } from './BrowserConversionRuntime';
import type { BrowserConversionJob } from './browser_conversion_job';
import { faber } from './TtsPreferences';
vi.mock('./BrowserAudioIdentity', () => ({ sealBrowserAudio: vi.fn(async () => 'sealed') }));
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((yes) => {
    resolve = yes;
  });
  return { promise, resolve };
}
function fixture() {
  const store = new MemoryBrowserJobStore();
  const repository = new BrowserJobRepository(store);
  const job: BrowserConversionJob = {
    snapshot: {
      jobId: 'listen',
      state: 'queued',
      outputs: [],
      chapterProgress: [0, 1].map((index) => ({ index, name: `${index}`, status: 'pending' })),
    },
    document: {
      jobId: 'listen',
      chapters: [0, 1].map((index) => ({ index, name: `${index}`, text: 'á🙂Text', charCount: 6 })),
    },
    preferences: {
      primary: faber,
      secondary: { ...faber, model_id: 'pt_BR-edresson-low' },
      allow_online_fallback: false,
    },
    language: 'pt-BR',
    audio: new Map(),
    chunks: new Map(),
    done: Promise.resolve(),
  };
  let generation = 0;
  let emitted = false;
  const session: BrowserSession = {
    next_segment: vi.fn(() =>
      emitted
        ? 'null'
        : JSON.stringify({
            session_id: `session-${generation}`,
            chapter: 0,
            index: 0,
            total: 1,
            text: generation ? 'Text' : 'á🙂Text',
            selection: faber,
          }),
    ),
    set_listening_position_json_v2: vi.fn(() => {
      generation++;
      emitted = false;
    }),
    provider_failed: vi.fn(),
    accept_audio: vi.fn(() => {
      emitted = true;
      return true;
    }),
    chapter_audio: vi.fn(() => new Uint8Array([1, 2])),
    cancel: vi.fn(),
    free: vi.fn(),
  };
  const runtime: BrowserRuntime = {
    inspect: vi.fn(),
    create: vi.fn(async () => session),
    synthesize: vi.fn(async () => new Uint8Array([1, 2])),
    cancelSynthesis: vi.fn(),
  };
  return {
    store,
    repository,
    job,
    session,
    runtime,
    execution: new BrowserJobExecution(runtime, repository),
  };
}
beforeEach(() => {
  URL.createObjectURL = vi.fn(() => 'blob:fixture');
  URL.revokeObjectURL = vi.fn();
});
describe('listening synthesis leases', () => {
  for (const phase of ['primary', 'secondary'] as const) {
    for (const transition of ['seek', 'cancel'] as const) {
      it(`rejects late ${phase} success after ${transition}`, async () => {
        const { job, repository, runtime, session, execution } = fixture();
        const started = deferred<void>();
        const pending = deferred<Uint8Array>();
        if (phase === 'secondary')
          vi.mocked(runtime.synthesize).mockRejectedValueOnce(new Error('Primary unavailable'));
        vi.mocked(runtime.synthesize).mockImplementationOnce(async () => {
          started.resolve();
          return pending.promise;
        });
        await repository.ensureRestored();
        await repository.commitNew(job);
        execution.enqueue(job);
        await started.promise;
        if (transition === 'seek') await execution.listenFrom('listen', 0, 2);
        else await execution.cancel('listen');
        pending.resolve(new Uint8Array([9]));
        await job.done;
        expect(session.accept_audio).toHaveBeenCalledTimes(transition === 'seek' ? 1 : 0);
        expect(job.snapshot.state).toBe(transition === 'seek' ? 'finished' : 'cancelled');
        const chunks = job.chunks.get(0)?.chunks ?? [];
        expect(chunks).toHaveLength(transition === 'seek' ? 1 : 0);
        if (transition === 'seek') expect(chunks[0].text).toBe('Text');
      });
    }
  }
  it('retires accepted partial chunks and their byte ranges on seek', async () => {
    const { job, repository, runtime, session, execution } = fixture();
    let cursor = 0;
    let retired = false;
    session.next_segment = vi.fn(() =>
      cursor === (retired ? 1 : 2)
        ? 'null'
        : JSON.stringify({
            session_id: retired ? 'new' : 'old',
            chapter: 0,
            index: cursor,
            total: 2,
            text: 'Text',
            selection: faber,
          }),
    );
    session.accept_audio = vi.fn(() => {
      cursor++;
      return retired || cursor === 2;
    });
    session.set_listening_position_json_v2 = vi.fn(() => {
      retired = true;
      cursor = 0;
    });
    const started = deferred<void>();
    const pending = deferred<Uint8Array>();
    vi.mocked(runtime.synthesize)
      .mockResolvedValueOnce(new Uint8Array([1, 2]))
      .mockImplementationOnce(async () => {
        started.resolve();
        return pending.promise;
      });
    await repository.ensureRestored();
    await repository.commitNew(job);
    execution.enqueue(job);
    await started.promise;
    expect(job.chunks.get(0)?.chunks).toHaveLength(1);
    await execution.listenFrom('listen', 0, 2);
    pending.resolve(new Uint8Array([9]));
    await job.done;
    expect(session.accept_audio).toHaveBeenCalledTimes(2);
    expect(job.audio.get(0)?.chunks).toEqual([
      expect.objectContaining({ byteOffset: 0, byteLength: 2, index: 0 }),
    ]);
    expect(job.audio.get(0)?.textOffset).toBe(2);
  });
  it('continues a seek accepted while the previous generation commits terminal state', async () => {
    const { store, repository, job, session, execution } = fixture();
    const finishing = deferred<void>();
    const release = deferred<void>();
    const save = store.save.bind(store);
    let delayed = false;
    vi.spyOn(store, 'save').mockImplementation(async (snapshot) => {
      if (snapshot.snapshot.state === 'finished' && !delayed) {
        delayed = true;
        finishing.resolve();
        await release.promise;
      }
      await save(snapshot);
    });
    await repository.ensureRestored();
    await repository.commitNew(job);
    execution.enqueue(job);
    await finishing.promise;
    await execution.listenFrom('listen', 0, 2);
    release.resolve();
    await job.done;
    expect(session.accept_audio).toHaveBeenCalledTimes(2);
    expect(job.audio.get(0)?.textOffset).toBe(2);
    expect(job.snapshot.state).toBe('finished');
    expect((await store.list())[0].listeningPosition?.text_offset).toBe(2);
  });
});
