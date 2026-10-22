import { act, renderHook } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { useConversionFlow } from '../hooks/useConversionFlow';
import type { ConversionClient } from '../services/ConversionService';
import type { ConversionFormValues, JobSnapshot } from '../types/conversion';
import { createProvidersWrapper } from './testUtils';
import { conversionCache } from '../services/ConversionCache';

describe('useConversionFlow queue', () => {
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

  it('keeps queued upload metadata visible while the next job starts', async () => {
    const submit = vi
      .fn()
      .mockResolvedValueOnce({ jobId: 'job-1' })
      .mockResolvedValueOnce({ jobId: 'job-2' });
    const poll = vi
      .fn()
      .mockResolvedValueOnce({
        jobId: 'job-1',
        state: 'finished',
        outputs: [],
      } satisfies JobSnapshot)
      .mockImplementationOnce(
        async (_jobId: string, options?: { onSnapshot?: (snapshot: JobSnapshot) => void }) => {
          options?.onSnapshot?.({
            jobId: 'job-2',
            state: 'running',
            events: ['Starting queued upload'],
            progressPercent: 10,
          });
          return {
            jobId: 'job-2',
            state: 'finished',
            outputs: [],
            progressPercent: 100,
          } satisfies JobSnapshot;
        },
      );

    const client: ConversionClient = {
      submit,
      fetch: vi.fn(),
      poll,
    };

    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    await act(async () => {
      await result.current.submit(request, {
        batchQueue: [
          {
            file: null,
            fileName: 'queued.epub',
            uploadId: 'upload-queued',
            bookTitle: 'Queued Book',
            bookAuthor: 'Queued Author',
            coverUrl: '/covers/queued.jpg',
            engine: 'edge',
            footnoteMode: 'inline',
          },
        ],
      });
    });

    expect(submit).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        file: null,
        uploadId: 'upload-queued',
        bookTitle: 'Queued Book',
        bookAuthor: 'Queued Author',
        coverUrl: '/covers/queued.jpg',
      }),
    );
    expect(result.current.state.phase).toBe('success');
    expect(result.current.state.bookTitle).toBe('Queued Book');
    expect(result.current.state.bookAuthor).toBe('Queued Author');
    expect(result.current.state.coverUrl).toBe('/covers/queued.jpg');
  });

  it('saves pending batch to localStorage during drainQueue and clears on completion', async () => {
    const saveSpy = vi.spyOn(conversionCache, 'savePendingBatch');
    const clearSpy = vi.spyOn(conversionCache, 'clearPendingBatch');

    const submit = vi.fn().mockResolvedValue({ jobId: 'persist' });
    const poll = vi.fn().mockResolvedValue({
      jobId: 'persist',
      state: 'finished',
      outputs: [],
    } satisfies JobSnapshot);

    const client: ConversionClient = { submit, fetch: vi.fn(), poll };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    await act(async () => {
      await result.current.submit(request);
    });

    // savePendingBatch called at least once (on submit + before each job)
    expect(saveSpy).toHaveBeenCalled();
    // clearPendingBatch called after queue drains
    expect(clearSpy).toHaveBeenCalled();
  });
});
