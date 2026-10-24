import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
vi.mock('../wasm/converter_wasm', () => ({
  default: vi.fn(),
  ConversionSession: vi.fn(),
  inspect_epub: vi.fn(),
}));
import {
  BrowserConversionClient,
  createBrowserSynthesis,
  type BrowserRuntime,
} from './BrowserConversionClient';
import { BrowserTtsPreparationError } from './BrowserTtsFailure';
import { cancelPiper } from './BrowserPiper';
import { faber, edge, system } from './TtsPreferences';
import { MemoryBrowserJobStore } from './BrowserJobStore';
import type { ConversionFormValues } from '../types/conversion';
const request = (): ConversionFormValues => ({
  file: new File(['fixture'], 'fixture.epub'),
  engine: 'piper',
  footnoteMode: 'inline',
  tts_preferences: { primary: { ...faber }, secondary: null, allow_online_fallback: false },
});
function fixture() {
  let cursor = 0;
  const session = {
    next_segment: vi.fn(() =>
      cursor
        ? 'null'
        : JSON.stringify({
            chapter: 1,
            index: 0,
            total: 1,
            text: 'Texto',
            selection: faber,
            fallback_used: false,
          }),
    ),
    provider_failed: vi.fn(),
    accept_audio: vi.fn(() => {
      cursor++;
      return true;
    }),
    chapter_audio: vi.fn(() => new Uint8Array([1, 2])),
    cancel: vi.fn(),
    free: vi.fn(),
  };
  const runtime: BrowserRuntime = {
    inspect: vi.fn(async () => ({
      bookTitle: 'Fixture',
      chapters: [0, 1].map((index) => ({
        index,
        name: `Chapter ${index}`,
        text: 'Texto',
        charCount: 5,
      })),
    })),
    create: vi.fn(async () => session),
    synthesize: vi.fn(async () => new Uint8Array([1, 2])),
  };
  return {
    runtime,
    session,
    client: new BrowserConversionClient(runtime, new MemoryBrowserJobStore()),
  };
}
beforeEach(() => {
  localStorage.clear();
  vi.stubGlobal(
    'fetch',
    vi.fn(() => {
      throw new Error('No network allowed');
    }),
  );
  URL.createObjectURL = vi.fn(() => 'blob:fixture');
  URL.revokeObjectURL = vi.fn();
});
afterEach(() => {
  cancelPiper();
  vi.unstubAllGlobals();
});
describe('browser conversion boundary', () => {
  it.each([true, false])(
    'keeps preparation failure separate from MP3 success and respects native recovery=%s',
    async (recovery) => {
      const { client, runtime, session } = fixture();
      vi.mocked(runtime.create).mockRejectedValue(
        new BrowserTtsPreparationError('Language is unavailable in this runtime'),
      );
      const values = request();
      values.language = 'en-US';
      if (recovery) values.tts_preferences!.policy_version = 2;
      const { jobId } = await client.submit(values);
      const failed = await client.poll(jobId, { intervalMs: 1 });
      expect(failed.state).toBe('failed');
      expect(failed.outputs).toEqual([]);
      expect(await client.getNativePlaybackPolicy(jobId)).toEqual(
        recovery ? { language: 'en-US', voice: null } : null,
      );
      expect(session.accept_audio).not.toHaveBeenCalled();
      expect(runtime.synthesize).not.toHaveBeenCalled();
    },
  );
  it('does not treat corrupt saved session state as a provider failure', async () => {
    const { client, runtime } = fixture();
    vi.mocked(runtime.create).mockRejectedValue(new Error('Corrupt saved policy'));
    const values = request();
    values.tts_preferences!.policy_version = 2;
    const { jobId } = await client.submit(values);
    await client.poll(jobId, { intervalMs: 1 });
    expect(await client.getNativePlaybackPolicy(jobId)).toBeNull();
  });
  it('admits another compatible catalog model and rejects unavailable runtime selections before queuing', async () => {
    const { client, runtime } = fixture();
    runtime.validateSelection = vi.fn(async (selection) => {
      if (selection.model_id === 'unavailable') throw new Error('Runtime unavailable');
    });
    const values = request();
    values.tts_preferences!.primary = { ...faber, model_id: 'pt_BR-edresson-low' };
    const { jobId } = await client.submit(values);
    expect((await client.fetch(jobId)).voice).toBe('pt_BR-edresson-low');
    expect(runtime.validateSelection).toHaveBeenCalledWith(values.tts_preferences!.primary);
    values.tts_preferences!.primary = { ...faber, model_id: 'unavailable' };
    await expect(client.submit(values)).rejects.toThrow('Runtime unavailable');
  });
  it('exposes captured native listening policy after Piper failure without accepting fake audio', async () => {
    const { client, runtime, session } = fixture();
    vi.mocked(runtime.synthesize).mockRejectedValue(new Error('Faber model missing'));
    const values = request();
    values.tts_preferences = {
      policy_version: 2,
      primary: faber,
      secondary: system,
      allow_online_fallback: false,
    };
    const { jobId } = await client.submit(values);
    values.tts_preferences.secondary = null;
    const failed = await client.poll(jobId, { intervalMs: 1 });
    expect(failed.state).toBe('failed');
    expect(failed.outputs).toEqual([]);
    expect(session.accept_audio).not.toHaveBeenCalled();
    expect(session.provider_failed).not.toHaveBeenCalled();
    expect(runtime.synthesize).toHaveBeenCalledOnce();
    expect(await client.getNativePlaybackPolicy(jobId)).toEqual({ language: 'pt-BR', voice: null });
    expect(await client.getChapterManifest(jobId, 1)).toBeNull();
  });
  it('never enables native listening for an explicitly strict job', async () => {
    const { client, runtime } = fixture();
    vi.mocked(runtime.synthesize).mockRejectedValue(new Error('Faber model missing'));
    const { jobId } = await client.submit(request());
    await client.poll(jobId, { intervalMs: 1 });
    expect(await client.getNativePlaybackPolicy(jobId)).toBeNull();
  });

  it('does not start inference after cancellation during model preflight or contaminate a new job', async () => {
    let release!: () => void;
    let entered!: () => void;
    const blocked = new Promise<void>((resolve) => {
      release = resolve;
    });
    const preparing = new Promise<void>((resolve) => {
      entered = resolve;
    });
    let preparations = 0;
    const prepare = vi.fn(async () => {
      if (++preparations === 1) {
        entered();
        await blocked;
      }
    });
    const messages: string[] = [];
    class WorkerFixture {
      onmessage?: (event: {
        data: {
          version: number;
          requestId: number;
          modelId: string;
          format: string;
          audio: ArrayBuffer;
        };
      }) => void;
      onerror?: (event: { message: string }) => void;
      terminate = vi.fn();
      postMessage({
        text,
        requestId,
        modelId,
      }: {
        text: string;
        requestId: number;
        modelId: string;
      }) {
        messages.push(text);
        queueMicrotask(() =>
          this.onmessage?.({
            data: {
              version: 2,
              requestId,
              modelId,
              format: 'mp3',
              audio: new Uint8Array([1, 2]).buffer,
            },
          }),
        );
      }
    }
    vi.stubGlobal('Worker', WorkerFixture);
    const { runtime, session } = fixture();
    Object.assign(runtime, createBrowserSynthesis(prepare));
    const client = new BrowserConversionClient(runtime, new MemoryBrowserJobStore());
    const first = await client.submit(request());
    await preparing;
    await client.cancel(first.jobId);
    release();
    // A second job waits for the cancelled job's preparation to settle.
    const second = await client.submit(request());
    const finished = await client.poll(second.jobId, { intervalMs: 1 });
    const cancelled = await client.fetch(first.jobId);
    expect(first.jobId).not.toBe(second.jobId);
    expect(cancelled.state).toBe('cancelled');
    expect(cancelled.outputs).toEqual([]);
    expect(await client.getChapterManifest(first.jobId, 1)).toBeNull();
    expect(session.provider_failed).not.toHaveBeenCalled();
    expect(finished.state).toBe('finished');
    expect(session.accept_audio).toHaveBeenCalledOnce();
    // Only the fresh identity may start a worker or publish encoded audio.
    expect(messages).toHaveLength(1);
    expect(URL.createObjectURL).toHaveBeenCalledTimes(2);
  });

  it('keeps chapter selection and immutable policy through Rust-session I/O', async () => {
    const { client, runtime, session } = fixture();
    const values = request();
    values.chapters = '2';
    const { jobId } = await client.submit(values);
    values.tts_preferences!.primary = { ...edge };
    const result = await client.poll(jobId, { intervalMs: 1 });
    expect(result.state).toBe('finished');
    expect(runtime.create).toHaveBeenCalledWith(
      [expect.objectContaining({ index: 1 })],
      expect.objectContaining({ primary: faber }),
      'pt-BR',
    );
    expect(session.accept_audio).toHaveBeenCalledTimes(1);
    expect((await client.getChapterManifest(jobId, 1))?.chunks).toHaveLength(1);
    expect(result.outputs?.[0].name).toBe('chapter-2.mp3');
    expect(fetch).not.toHaveBeenCalled();
  });
  it('rejects unavailable Edge and unsupported options without hiding them', async () => {
    const { client, runtime } = fixture();
    const values = request();
    values.tts_preferences!.primary = { ...edge };
    await expect(client.submit(values)).rejects.toThrow('Edge is unavailable');
    expect(runtime.create).not.toHaveBeenCalled();
    await expect(client.submit({ ...request(), sections: '2' })).rejects.toThrow(
      'advanced conversion options',
    );
    await expect(client.submit({ ...request(), enableCharacterVoices: true })).rejects.toThrow(
      'advanced conversion options',
    );
    await expect(client.submit({ ...request(), formattingCues: true })).rejects.toThrow(
      'advanced conversion options',
    );
  });
  it('leaves completed state and artifacts intact when cancellation arrives late', async () => {
    const { client } = fixture();
    const { jobId } = await client.submit(request());
    const finished = await client.poll(jobId, { intervalMs: 1 });
    expect(finished.state).toBe('finished');
    expect(await client.cancel(jobId)).toEqual({ status: 'finished' });
    expect(await client.fetch(jobId)).toEqual(finished);
  });
  it('restores completed MP3s and resumes only unfinished chapters with the saved voice', async () => {
    const { runtime } = fixture();
    const store = new MemoryBrowserJobStore();
    const document = await runtime.inspect(request().file!);
    const jobId = 'interrupted-book';
    await store.save({
      jobId,
      document: { ...document, jobId },
      language: 'pt-BR',
      preferences: { primary: { ...faber }, secondary: null, allow_online_fallback: false },
      snapshot: {
        jobId,
        state: 'running',
        chaptersTotal: 2,
        chaptersCompleted: 1,
        outputs: [{ name: 'chapter-1.mp3', url: 'blob:expired' }],
        chapterProgress: [
          { index: 0, name: 'Chapter 0', chars: 5, status: 'completed' },
          { index: 1, name: 'Chapter 1', chars: 5, status: 'processing' },
        ],
      },
      audio: [
        {
          chapterIndex: 0,
          name: 'chapter-1.mp3',
          blob: new Blob([new Uint8Array([3, 4])], { type: 'audio/mpeg' }),
        },
      ],
    });
    localStorage.setItem(
      'ebook-tts.preferences.v1',
      JSON.stringify({ primary: edge, secondary: null, allow_online_fallback: false }),
    );
    const restored = new BrowserConversionClient(runtime, store);
    expect(await restored.getResumableJobs()).toEqual([
      expect.objectContaining({
        jobId,
        state: 'interrupted',
        voice: 'pt_BR-faber-medium',
        chaptersCompleted: 1,
      }),
    ]);
    expect((await restored.fetch(jobId)).outputs?.[0].url).toBe('blob:fixture');
    expect((await restored.getChapterManifest(jobId, 0))?.chunks).toHaveLength(1);
    await restored.resume(jobId);
    const finished = await restored.poll(jobId, { intervalMs: 1 });
    expect(runtime.create).toHaveBeenCalledWith(
      [expect.objectContaining({ index: 0 }), expect.objectContaining({ index: 1 })],
      expect.objectContaining({ primary: faber }),
      'pt-BR',
    );
    expect(finished.outputs?.map((output) => output.name)).toEqual([
      'chapter-1.mp3',
      'chapter-2.mp3',
    ]);
    expect(runtime.synthesize).toHaveBeenCalledTimes(1);
    const reopened = new BrowserConversionClient(runtime, store);
    expect((await reopened.fetch(jobId)).state).toBe('finished');
    expect(await reopened.getResumableJobs()).toEqual([]);
    await reopened.removeJob(jobId);
    expect(await new BrowserConversionClient(runtime, store).getRecentJobs()).toEqual([]);
  });
  it('refuses to start conversion when durable storage cannot commit', async () => {
    const { runtime } = fixture();
    const client = new BrowserConversionClient(runtime, {
      list: async () => [],
      remove: async () => undefined,
      save: async () => {
        throw new Error('Local audio storage is full');
      },
    });
    await expect(client.submit(request())).rejects.toThrow('Local audio storage is full');
    expect(runtime.create).not.toHaveBeenCalled();
    expect(await client.getRecentJobs()).toEqual([]);
  });
  it('cancels before creating or publishing queued work', async () => {
    const { client, session } = fixture();
    const { jobId } = await client.submit(request());
    await client.cancel(jobId);
    expect((await client.poll(jobId)).state).toBe('cancelled');
    expect(session.accept_audio).not.toHaveBeenCalled();
  });
});

describe('app recovery native listening policy', () => {
  it('retains listening recovery after a configured local secondary fails without publishing MP3', async () => {
    const { client, runtime } = fixture();
    vi.mocked(runtime.synthesize).mockRejectedValue(new Error('Installed model unavailable'));
    const values = request();
    values.tts_preferences = {
      policy_version: 2,
      primary: faber,
      secondary: { engine: 'piper', model_id: 'pt_BR-edresson-low', voice: null },
      allow_online_fallback: false,
    };
    const { jobId } = await client.submit(values);
    const failed = await client.poll(jobId, { intervalMs: 1 });
    expect(failed.state).toBe('failed');
    expect(failed.outputs).toEqual([]);
    expect(await client.getNativePlaybackPolicy(jobId)).toEqual({ language: 'pt-BR', voice: null });
  });
});
