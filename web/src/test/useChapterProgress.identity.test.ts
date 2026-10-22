import { act, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useChapterProgress } from '../components/useChapterProgress';
import { conversionClient } from '../services/ConversionService';
import type { ChapterStreamManifest } from '../types/conversion';
import { createProvidersWrapper } from './testUtils';

const entries = [{ index: 1, name: 'Chapter', status: 'completed' as const }];
const manifest = (text: string): ChapterStreamManifest => ({
  chunks: [
    { index: 1, url: '/audio/1.mp3', text: `${text} second` },
    { index: 0, url: '/audio/0.mp3', text: `${text} first` },
  ],
});
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((accept, fail) => {
    resolve = accept;
    reject = fail;
  });
  return { promise, resolve, reject };
}
async function textOf(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error);
    reader.readAsText(blob);
  });
}
beforeEach(() => {
  localStorage.clear();
  URL.createObjectURL = vi.fn(() => 'blob:download');
  URL.revokeObjectURL = vi.fn();
  vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => undefined);
});
afterEach(() => {
  vi.restoreAllMocks();
});

describe('chapter progress document ownership', () => {
  it('includes newly fetched ordered segment text on the first download', async () => {
    vi.spyOn(conversionClient, 'getChapterManifest').mockResolvedValue(manifest('Fresh'));
    const { result } = renderHook(() => useChapterProgress({ entries, jobId: 'book' }), {
      wrapper: createProvidersWrapper('en'),
    });
    await act(async () => {
      await result.current.handleDownloadText();
    });
    const blob = vi.mocked(URL.createObjectURL).mock.calls[0][0] as Blob;
    expect(await textOf(blob)).toBe('1. Chapter\n\nFresh first\nFresh second');
    expect(HTMLAnchorElement.prototype.click).toHaveBeenCalledOnce();
    expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:download');
  });

  it.each(['success', 'failure'] as const)(
    'ignores an old job manifest %s while the new job owns the chapter',
    async (outcome) => {
      const pending = deferred<ChapterStreamManifest | null>();
      vi.spyOn(conversionClient, 'getChapterManifest')
        .mockReturnValueOnce(pending.promise)
        .mockResolvedValue(manifest('New'));
      const { result, rerender } = renderHook(
        ({ jobId }) => useChapterProgress({ entries, jobId }),
        {
          initialProps: { jobId: 'old' },
          wrapper: createProvidersWrapper('en'),
        },
      );
      let oldFetch!: Promise<unknown>;
      act(() => {
        oldFetch = result.current.fetchManifest(1);
      });
      rerender({ jobId: 'new' });
      await act(async () => {
        await result.current.fetchManifest(1);
      });
      await act(async () => {
        if (outcome === 'success') pending.resolve(manifest('Old'));
        else pending.reject(new Error('Old request failed'));
        await oldFetch;
      });
      expect(result.current.manifests[1]).toEqual(manifest('New'));
      expect(result.current.manifestErrors[1]).toBeNull();
      expect(result.current.manifestLoading[1]).toBe(false);
    },
  );

  it('clears cached manifests when the component changes jobs', async () => {
    vi.spyOn(conversionClient, 'getChapterManifest').mockResolvedValue(manifest('Old'));
    const { result, rerender } = renderHook(({ jobId }) => useChapterProgress({ entries, jobId }), {
      initialProps: { jobId: 'old' },
      wrapper: createProvidersWrapper('en'),
    });
    await act(async () => {
      await result.current.fetchManifest(1);
    });
    expect(result.current.manifests[1]).toEqual(manifest('Old'));
    rerender({ jobId: 'new' });
    expect(result.current.manifests).toEqual({});
  });

  it.each(['job change', 'unmount'] as const)(
    'does not export an old document after %s',
    async (transition) => {
      const pending = deferred<ChapterStreamManifest | null>();
      vi.spyOn(conversionClient, 'getChapterManifest').mockReturnValue(pending.promise);
      const { result, rerender, unmount } = renderHook(
        ({ jobId }) => useChapterProgress({ entries, jobId }),
        {
          initialProps: { jobId: 'old' },
          wrapper: createProvidersWrapper('en'),
        },
      );
      let download!: Promise<void>;
      act(() => {
        download = result.current.handleDownloadText();
      });
      if (transition === 'job change') rerender({ jobId: 'new' });
      else unmount();
      await act(async () => {
        pending.resolve(manifest('Old'));
        await download;
      });
      expect(URL.createObjectURL).not.toHaveBeenCalled();
      expect(HTMLAnchorElement.prototype.click).not.toHaveBeenCalled();
    },
  );
});
