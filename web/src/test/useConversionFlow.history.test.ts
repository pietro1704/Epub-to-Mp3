import { act, renderHook } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { useConversionFlow } from '../hooks/useConversionFlow';
import type { ConversionClient } from '../services/ConversionService';
import { createProvidersWrapper } from './testUtils';
import { conversionCache } from '../services/ConversionCache';

describe('useConversionFlow history', () => {
  beforeEach(() => {
    // Isolate localStorage from real data
    localStorage.clear();
  });

  it('keeps local-cache jobs visible across phases when backend returns an empty list', async () => {
    conversionCache.save('interrupted-job', 'interrupted.epub', {
      phase: 'error',
      log: [],
      downloads: [],
      rawLog: [],
    });
    conversionCache.save('finished-job', 'done.epub', {
      phase: 'success',
      log: [],
      downloads: [{ name: 'ch-1.mp3', url: '/audio/ch-1.mp3' }],
      rawLog: [],
    });

    const getResumableJobs = vi.fn().mockResolvedValue([]);

    const client: ConversionClient = {
      submit: vi.fn(),
      fetch: vi.fn(),
      poll: vi.fn(),
      getResumableJobs,
    };

    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    const ids = result.current.cachedJobs.map((j) => j.jobId);
    expect(ids).toContain('interrupted-job');
    expect(ids).toContain('finished-job');
  });

  it('restores a terminal (success) cached job without hitting the backend', async () => {
    conversionCache.save('done-123', 'finished.epub', {
      phase: 'success',
      log: [],
      downloads: [{ name: 'ch-1.mp3', url: '/audio/ch-1.mp3' }],
      rawLog: [],
      bookTitle: 'Completed Book',
    });

    const fetchMock = vi.fn();
    const client: ConversionClient = {
      submit: vi.fn(),
      fetch: fetchMock,
      poll: vi.fn(),
      getResumableJobs: vi.fn().mockResolvedValue([]),
    };

    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    await act(async () => {
      await result.current.resume('done-123');
    });

    expect(fetchMock).not.toHaveBeenCalled();
    expect(result.current.state.phase).toBe('success');
    expect(result.current.state.downloads).toHaveLength(1);
    expect(result.current.state.bookTitle).toBe('Completed Book');
  });

  it('merges interrupted local-only cache jobs with backend resumable jobs', async () => {
    conversionCache.save('local-ghost', 'ghost.epub', {
      phase: 'polling',
      log: [],
      downloads: [],
      rawLog: [],
    });

    const getResumableJobs = vi.fn().mockResolvedValue([
      {
        jobId: 'backend-job',
        fileName: 'backend.epub',
        bookTitle: 'Backend Book',
        savedAt: new Date().toISOString(),
        engine: 'edge',
      },
    ]);

    const client: ConversionClient = {
      submit: vi.fn(),
      fetch: vi.fn(),
      poll: vi.fn(),
      getResumableJobs,
    };

    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });

    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    const ids = result.current.cachedJobs.map((j) => j.jobId);
    expect(ids).toContain('backend-job');
    expect(ids).toContain('local-ghost');
  });

  it('restartBackend clears cached state and reloads after health check succeeds', async () => {
    vi.useFakeTimers();
    const restartBackend = vi.fn().mockResolvedValue({ status: 'restarting' });
    const healthFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: vi.fn().mockResolvedValue({ status: 'healthy' }),
    });
    vi.stubGlobal('fetch', healthFetch);
    const reloadMock = vi.fn();
    const originalLocation = window.location;
    Object.defineProperty(window, 'location', {
      configurable: true,
      value: { ...originalLocation, reload: reloadMock },
    });
    conversionCache.save('cached-job', 'book.epub', {
      phase: 'success',
      log: [],
      downloads: [],
      rawLog: [],
    });
    conversionCache.savePendingBatch([
      {
        file: null,
        uploadId: 'queued-upload',
        fileName: 'queued.epub',
        engine: 'edge',
        footnoteMode: 'inline',
      },
    ]);
    const client: ConversionClient = {
      submit: vi.fn(),
      fetch: vi.fn(),
      poll: vi.fn(),
      restartBackend,
    };
    const { result } = renderHook(() => useConversionFlow(client), {
      wrapper: createProvidersWrapper('en'),
    });
    await act(async () => {
      await result.current.restartBackend({ keep_cache: true });
    });
    expect(restartBackend).toHaveBeenCalledWith({ keep_cache: true });
    expect(conversionCache.load('cached-job')).toBeNull();
    expect(conversionCache.loadPendingBatch()).toBeNull();
    expect(result.current.cachedJobs).toEqual([]);
    expect(result.current.recentJobs).toEqual([]);
    expect(result.current.healthStatus).toBe('restarting');
    await act(async () => {
      await vi.advanceTimersByTimeAsync(3000);
    });
    expect(healthFetch).toHaveBeenCalled();
    expect(reloadMock).toHaveBeenCalledTimes(1);
    Object.defineProperty(window, 'location', {
      configurable: true,
      value: originalLocation,
    });
    vi.useRealTimers();
  });
});
