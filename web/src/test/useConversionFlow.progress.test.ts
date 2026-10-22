import { act, renderHook, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { useConversionFlow } from '../hooks/useConversionFlow';
import type { ConversionClient } from '../services/ConversionService';
import type { ConversionFormValues, JobSnapshot } from '../types/conversion';
import { createProvidersWrapper } from './testUtils';
import { conversionCache } from '../services/ConversionCache';

describe('useConversionFlow progress', () => {
  beforeEach(() => {
    // Isolate localStorage from real data
    localStorage.clear();
  });

  const file = new File(['data'], 'book.epub', {
    type: 'application/epub+zip',
  });

  const request: ConversionFormValues = {
    file,
    engine: 'edge',
    footnoteMode: 'inline',
  };

  it('records chapter progress updates from snapshot', async () => {
    const submit = vi.fn().mockResolvedValue({ jobId: '999' });
    const poll = vi
      .fn()
      .mockImplementation(
        async (_jobId: string, options?: { onSnapshot?: (snapshot: JobSnapshot) => void }) => {
          options?.onSnapshot?.({
            jobId: '999',
            state: 'running',
            events: [],
            chapterProgress: [
              { index: 1, name: 'Ch 1', status: 'completed', engine: 'edge' },
              { index: 2, name: 'Ch 2', status: 'processing', engine: 'edge' },
            ],
          });
          return {
            jobId: '999',
            state: 'finished',
            outputs: [],
            chapterProgress: [
              { index: 1, name: 'Ch 1', status: 'completed', engine: 'edge' },
              { index: 2, name: 'Ch 2', status: 'completed', engine: 'edge' },
            ],
          } satisfies JobSnapshot;
        },
      );

    const client: ConversionClient = { submit, fetch: vi.fn(), poll };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    await act(async () => {
      await result.current.submit(request);
    });

    expect(result.current.state.phase).toBe('success');
    const progress = result.current.state.summary?.chapterProgress;
    expect(progress).toBeDefined();
    expect(progress?.length).toBe(2);
    expect(progress?.[0].status).toBe('completed');
  });

  it('decrements ETA between snapshots while polling', async () => {
    vi.useFakeTimers();
    let finishPoll: (() => void) | null = null;
    const submit = vi.fn().mockResolvedValue({ jobId: 'eta-123' });
    const poll = vi.fn().mockImplementation(
      async (_jobId: string, options?: { onSnapshot?: (snapshot: JobSnapshot) => void }) =>
        new Promise<JobSnapshot>((resolve) => {
          options?.onSnapshot?.({
            jobId: 'eta-123',
            state: 'running',
            etaSeconds: 5,
            progressPercent: 20,
          });
          finishPoll = () =>
            resolve({
              jobId: 'eta-123',
              state: 'finished',
              outputs: [],
              progressPercent: 100,
            } satisfies JobSnapshot);
        }),
    );

    const client: ConversionClient = { submit, fetch: vi.fn(), poll };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    let submitPromise: Promise<void> | undefined;
    await act(async () => {
      submitPromise = result.current.submit(request);
      await Promise.resolve();
    });

    expect(result.current.state.phase).toBe('polling');
    expect(result.current.state.etaSeconds).toBe(5);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(1000);
    });

    expect(result.current.state.etaSeconds).toBe(4);

    await act(async () => {
      finishPoll?.();
      await submitPromise;
    });

    vi.useRealTimers();
  });

  it('estimates ETA from current WPM and remaining book words', async () => {
    const submit = vi.fn().mockResolvedValue({ jobId: 'eta-wpm' });
    let finishPoll: (() => void) | null = null;
    const poll = vi.fn().mockImplementation(
      async (_jobId: string, options?: { onSnapshot?: (snapshot: JobSnapshot) => void }) =>
        new Promise<JobSnapshot>((resolve) => {
          options?.onSnapshot?.({
            jobId: 'eta-wpm',
            state: 'running',
            progressPercent: 45,
            chapterProgress: [
              {
                index: 1,
                name: 'Chapter 1',
                status: 'completed',
                chars: 600,
                charsProcessed: 600,
                wordCount: 120,
                charsPerSecond: 10,
              },
              {
                index: 2,
                name: 'Chapter 2',
                status: 'processing',
                chars: 500,
                charsProcessed: 250,
                wordCount: 100,
                charsPerSecond: 10,
              },
              {
                index: 3,
                name: 'Chapter 3',
                status: 'pending',
                chars: 400,
                wordCount: 80,
              },
            ],
          });
          finishPoll = () =>
            resolve({
              jobId: 'eta-wpm',
              state: 'finished',
              outputs: [],
              progressPercent: 100,
            } satisfies JobSnapshot);
        }),
    );

    const client: ConversionClient = { submit, fetch: vi.fn(), poll };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    let submitPromise: Promise<void> | undefined;
    await act(async () => {
      submitPromise = result.current.submit(request);
      await Promise.resolve();
    });

    expect(result.current.state.etaSeconds).toBe(65);

    await act(async () => {
      finishPoll?.();
      await submitPromise;
    });
  });

  it('hydrates next job metadata from the initial fetch before poll completes', async () => {
    const submit = vi.fn().mockResolvedValue({ jobId: 'next-1' });
    const fetch = vi.fn().mockResolvedValue({
      jobId: 'next-1',
      state: 'running',
      bookTitle: 'Fetched Book',
      bookAuthor: 'Fetched Author',
      progressPercent: 12,
      chaptersCompleted: 1,
      chaptersTotal: 8,
    } satisfies JobSnapshot);
    const poll = vi.fn().mockResolvedValue({
      jobId: 'next-1',
      state: 'finished',
      outputs: [],
      progressPercent: 100,
    } satisfies JobSnapshot);

    const client: ConversionClient = { submit, fetch, poll };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    await act(async () => {
      await result.current.submit(request);
    });

    expect(fetch).toHaveBeenCalledWith('next-1');
    expect(result.current.state.bookTitle).toBe('Fetched Book');
    expect(result.current.state.bookAuthor).toBe('Fetched Author');
    expect(result.current.state.summary?.chaptersCompleted).toBe(1);
    expect(result.current.state.summary?.chaptersTotal).toBe(8);
  });

  it('surfaces multiple download assets from finished snapshot', async () => {
    const submit = vi.fn().mockResolvedValue({ jobId: 'multi' });
    const poll = vi.fn().mockResolvedValue({
      jobId: 'multi',
      state: 'finished',
      outputs: [
        { name: 'ch-1.mp3', url: '/audio/ch-1.mp3' },
        { name: 'ch-2.mp3', url: '/audio/ch-2.mp3' },
        { name: 'book.zip', url: '/audio/book.zip' },
      ],
    } satisfies JobSnapshot);

    const client: ConversionClient = { submit, fetch: vi.fn(), poll };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    await act(async () => {
      await result.current.submit(request);
    });

    expect(result.current.state.phase).toBe('success');
    expect(result.current.state.downloads).toHaveLength(3);
    const names = result.current.state.downloads.map((d) => d.name);
    expect(names).toContain('ch-1.mp3');
    expect(names).toContain('book.zip');
  });

  it('persists the newest snapshot rather than a stale render during SSE updates', async () => {
    let releasePoll: (() => void) | undefined;
    const submit = vi.fn().mockResolvedValue({ jobId: 'stale-cache' });
    const poll = vi
      .fn()
      .mockImplementation(
        async (_jobId: string, options?: { onSnapshot?: (snapshot: JobSnapshot) => void }) => {
          options?.onSnapshot?.({
            jobId: 'stale-cache',
            state: 'running',
            progressPercent: 10,
          });
          options?.onSnapshot?.({
            jobId: 'stale-cache',
            state: 'running',
            progressPercent: 65,
          });
          return new Promise<JobSnapshot>((resolve) => {
            releasePoll = () =>
              resolve({
                jobId: 'stale-cache',
                state: 'finished',
                outputs: [],
                progressPercent: 100,
              });
          });
        },
      );
    const client: ConversionClient = {
      submit,
      fetch: vi.fn().mockRejectedValue(new Error('initial unavailable')),
      poll,
    };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    let submitPromise: Promise<void>;
    await act(async () => {
      await Promise.resolve();
    });
    await act(async () => {
      submitPromise = result.current.submit(request);
      await waitFor(() => expect(poll).toHaveBeenCalled());
      await waitFor(() =>
        expect(conversionCache.load('stale-cache')?.state.summary?.progressPercent).toBe(65),
      );
      releasePoll?.();
      await submitPromise;
    });
  });

  it('does not let a delayed HTTP snapshot regress SSE progress', async () => {
    vi.useFakeTimers();
    let releasePoll: (() => void) | undefined;
    const submit = vi.fn().mockResolvedValue({ jobId: 'delayed-http' });
    const fetch = vi.fn().mockResolvedValue({
      jobId: 'delayed-http',
      state: 'running',
      progressPercent: 20,
    } satisfies JobSnapshot);
    const poll = vi
      .fn()
      .mockImplementation(
        async (_jobId: string, options?: { onSnapshot?: (snapshot: JobSnapshot) => void }) => {
          options?.onSnapshot?.({
            jobId: 'delayed-http',
            state: 'running',
            progressPercent: 80,
          });
          return new Promise<JobSnapshot>((resolve) => {
            releasePoll = () =>
              resolve({
                jobId: 'delayed-http',
                state: 'finished',
                outputs: [],
                progressPercent: 100,
              });
          });
        },
      );
    const client: ConversionClient = { submit, fetch, poll };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    await act(async () => {
      await Promise.resolve();
    });
    await act(async () => {
      const promise = result.current.submit(request);
      await vi.waitFor(() => expect(poll).toHaveBeenCalled());
      await Promise.resolve();
      await Promise.resolve();
      await vi.advanceTimersByTimeAsync(2500);
      await vi.waitFor(() =>
        expect(
          conversionCache.load('delayed-http')?.state.summary?.progressPercent,
        ).toBeGreaterThanOrEqual(80),
      );
      releasePoll?.();
      await promise;
    });
    expect(fetch).toHaveBeenCalledTimes(1);
    vi.useRealTimers();
  });
});
