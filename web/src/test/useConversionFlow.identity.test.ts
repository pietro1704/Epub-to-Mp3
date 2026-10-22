import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { useConversionFlow } from '../hooks/useConversionFlow';
import type { ConversionClient, PollOptions } from '../services/ConversionService';
import { conversionCache } from '../services/ConversionCache';
import type { ConversionFormValues, JobSnapshot } from '../types/conversion';
import { createProvidersWrapper } from './testUtils';

const request: ConversionFormValues = {
  file: new File(['book'], 'identity.epub'),
  engine: 'piper',
  footnoteMode: 'inline',
};

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((accept, fail) => {
    resolve = accept;
    reject = fail;
  });
  return { promise, resolve, reject };
}

describe('conversion run identity', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it.each(['user', 'backend'] as const)(
    'does not inherit skip intent after reset when a new batch is cancelled by %s',
    async (cancelledBy) => {
      const oldSubmit = deferred<{ jobId: string }>();
      const newSubmit = deferred<{ jobId: string }>();
      const next = { ...request, fileName: 'new-next.epub', bookTitle: 'New next book' };
      const client: ConversionClient = {
        mode: 'embedded',
        submit: vi
          .fn()
          .mockReturnValueOnce(oldSubmit.promise)
          .mockReturnValueOnce(newSubmit.promise)
          .mockResolvedValue({ jobId: 'unexpected-next' }),
        fetch: vi.fn(),
        poll: vi.fn(async (jobId) => ({ jobId, state: 'cancelled' })),
      };
      const { result } = renderHook(() => useConversionFlow(client), {
        wrapper: createProvidersWrapper('en'),
      });
      let oldRun!: Promise<void>;
      act(() => {
        oldRun = result.current.submit(request, { batchQueue: [request] });
      });
      await waitFor(() => expect(client.submit).toHaveBeenCalledOnce());
      await act(async () => {
        expect(await result.current.skipCurrent()).toBe(true);
      });
      act(() => {
        result.current.reset();
      });
      await act(async () => {
        oldSubmit.resolve({ jobId: 'discarded-job' });
        await oldRun;
      });
      let newRun!: Promise<void>;
      act(() => {
        newRun = result.current.submit(request, { batchQueue: [next] });
      });
      await waitFor(() => expect(client.submit).toHaveBeenCalledTimes(2));
      if (cancelledBy === 'user') {
        await act(async () => {
          expect(await result.current.cancel()).toBe(true);
        });
      }
      await act(async () => {
        newSubmit.resolve({ jobId: 'new-cancelled-job' });
        await newRun;
      });
      expect(client.submit).toHaveBeenCalledTimes(2);
      expect(result.current.queuePaused).toBe(true);
      expect(result.current.queue).toEqual([next]);
      expect(result.current.state.error).toBeTruthy();
      expect(conversionCache.loadPendingBatch()).toEqual([
        expect.objectContaining({ bookTitle: 'New next book' }),
      ]);
    },
  );

  it.each(['success', 'failure'] as const)(
    'preserves a newer conversion after an earlier submit finishes with %s',
    async (outcome) => {
      const earlier = deferred<{ jobId: string }>();
      const client: ConversionClient = {
        mode: 'embedded',
        submit: vi
          .fn()
          .mockReturnValueOnce(earlier.promise)
          .mockResolvedValueOnce({ jobId: 'new-job' }),
        fetch: vi.fn(),
        poll: vi.fn().mockResolvedValue({ jobId: 'new-job', state: 'finished' }),
      };
      const { result } = renderHook(() => useConversionFlow(client), {
        wrapper: createProvidersWrapper('en'),
      });
      let earlierRun!: Promise<void>;
      act(() => {
        earlierRun = result.current.submit(request);
      });
      await waitFor(() => expect(client.submit).toHaveBeenCalledOnce());
      act(() => {
        result.current.reset();
      });
      await act(async () => {
        await result.current.submit(request);
      });
      expect(result.current.state.phase).toBe('success');
      expect(result.current.state.jobId).toBe('new-job');
      await act(async () => {
        if (outcome === 'success') earlier.resolve({ jobId: 'old-job' });
        else earlier.reject(new Error('Late failure from old request'));
        await earlierRun;
      });
      expect(result.current.state.phase).toBe('success');
      expect(result.current.state.jobId).toBe('new-job');
      expect(result.current.state.error).toBeUndefined();
      expect(client.poll).toHaveBeenCalledOnce();
      expect(conversionCache.load('old-job')).toBeNull();
      expect(result.current.queue).toEqual([]);
    },
  );

  it('ignores callbacks and completion from a poll invalidated by reset', async () => {
    const terminal = deferred<JobSnapshot>();
    let observation!: PollOptions;
    const client: ConversionClient = {
      mode: 'embedded',
      submit: vi.fn().mockResolvedValue({ jobId: 'old-job' }),
      fetch: vi.fn(),
      poll: vi.fn((_jobId, options) => {
        observation = options ?? {};
        return terminal.promise;
      }),
    };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });
    let run!: Promise<void>;
    act(() => {
      run = result.current.submit(request);
    });
    await waitFor(() => expect(client.poll).toHaveBeenCalledOnce());
    act(() => {
      result.current.reset();
    });
    const retained = conversionCache.load('old-job');
    await act(async () => {
      observation.onSnapshot?.({
        jobId: 'old-job',
        state: 'running',
        bookTitle: 'Stale title',
        events: ['Stale event'],
      });
      observation.onStreamStatus?.('healthy');
      terminal.resolve({ jobId: 'old-job', state: 'finished' });
      await run;
    });
    expect(result.current.state.phase).toBe('idle');
    expect(result.current.state.jobId).toBeUndefined();
    expect(result.current.state.log).toEqual([]);
    expect(result.current.state.bookTitle).toBeUndefined();
    expect(conversionCache.load('old-job')).toEqual(retained);
  });
  it('keeps cancellation authoritative while submit is pending', async () => {
    const pending = deferred<{ jobId: string }>();
    const client: ConversionClient = {
      mode: 'embedded',
      submit: vi.fn(() => pending.promise),
      fetch: vi.fn(),
      poll: vi.fn().mockResolvedValue({ jobId: 'cancelled-job', state: 'finished' }),
    };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });
    let run!: Promise<void>;
    act(() => {
      run = result.current.submit(request);
    });
    await waitFor(() => expect(client.submit).toHaveBeenCalledOnce());
    await act(async () => {
      expect(await result.current.cancel()).toBe(true);
    });
    await act(async () => {
      pending.resolve({ jobId: 'cancelled-job' });
      await run;
    });
    expect(result.current.state.phase).toBe('idle');
    expect(result.current.state.error).toBeTruthy();
    expect(result.current.state.jobId).toBeUndefined();
    expect(client.poll).not.toHaveBeenCalled();
    expect(conversionCache.load('cancelled-job')).toBeNull();
  });

  it('ignores a resumed job fetch that resolves after reset', async () => {
    const initial = deferred<JobSnapshot>();
    const client: ConversionClient = {
      mode: 'embedded',
      submit: vi.fn(),
      fetch: vi.fn(() => initial.promise),
      poll: vi.fn().mockResolvedValue({ jobId: 'resumed-job', state: 'finished' }),
    };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });
    let run!: Promise<void>;
    act(() => {
      run = result.current.resume('resumed-job');
    });
    await waitFor(() => expect(client.fetch).toHaveBeenCalledOnce());
    act(() => {
      result.current.reset();
    });
    await act(async () => {
      initial.resolve({ jobId: 'resumed-job', state: 'running', bookTitle: 'Stale resume' });
      await run;
    });
    expect(result.current.state.phase).toBe('idle');
    expect(result.current.state.log).toEqual([]);
    expect(result.current.state.bookTitle).toBeUndefined();
    expect(client.poll).not.toHaveBeenCalled();
  });
});
