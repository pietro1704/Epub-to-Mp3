import { act, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useChapterStreamSession } from '../components/useChapterStreamSession';
import { conversionClient } from '../services/ConversionService';
import { latencyObservations } from '../services/LatencyObservation';
import type { ChapterStreamManifest } from '../types/conversion';
import { createProvidersWrapper } from './testUtils';

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((accept, fail) => {
    resolve = accept;
    reject = fail;
  });
  return { promise, resolve, reject };
}
const chapters = [
  { index: 1, name: 'First', status: 'completed' as const },
  { index: 2, name: 'Second', status: 'completed' as const },
];
const manifest = (jobId: string, chapterIndex: number, text: string): ChapterStreamManifest => ({
  jobId,
  chapterIndex,
  chunks: [{ index: 0, url: `/audio/${text}.mp3`, text }],
});
const outcomes = ['success', 'missing', 'failure'] as const;
function settle(
  pending: ReturnType<typeof deferred<ChapterStreamManifest | null>>,
  outcome: (typeof outcomes)[number],
) {
  if (outcome === 'failure') pending.reject(new Error('Obsolete fetch failed'));
  else pending.resolve(outcome === 'success' ? manifest('old', 1, 'obsolete') : null);
}
beforeEach(() => {
  localStorage.clear();
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

for (const transition of ['chapter', 'job'] as const) {
  describe(`streaming identity after ${transition} change`, () => {
    it.each(outcomes)(
      'ignores obsolete manifest %s after the new context publishes',
      async (outcome) => {
        const pending = deferred<ChapterStreamManifest | null>();
        const fresh = manifest(
          transition === 'job' ? 'fresh' : 'old',
          transition === 'chapter' ? 2 : 1,
          'fresh',
        );
        const fetchManifest = vi
          .spyOn(conversionClient, 'getChapterManifest')
          .mockReturnValueOnce(pending.promise)
          .mockResolvedValue(fresh);
        const { result, rerender } = renderHook(
          ({ jobId }) => useChapterStreamSession({ jobId, chapters }),
          {
            initialProps: { jobId: 'old' },
            wrapper: createProvidersWrapper('en'),
          },
        );
        act(() => {
          result.current.handleStart();
        });
        expect(fetchManifest).toHaveBeenCalledWith('old', 1);
        await act(async () => {
          if (transition === 'job') rerender({ jobId: 'fresh' });
          else result.current.handleChapterJump(2);
        });
        expect(result.current.src).toBe('/audio/fresh.mp3');
        const timerCount = vi.getTimerCount();
        await act(async () => {
          settle(pending, outcome);
        });
        expect(result.current.manifest).toEqual(fresh);
        expect(result.current.src).toBe('/audio/fresh.mp3');
        expect(result.current.currentSegmentText).toBe('fresh');
        expect(result.current.waiting).toBe(false);
        expect(vi.getTimerCount()).toBe(timerCount);
      },
    );
  });
}

describe('streaming lease retirement', () => {
  it.each(outcomes)(
    'does not publish or schedule an obsolete %s after unmount',
    async (outcome) => {
      const pending = deferred<ChapterStreamManifest | null>();
      vi.spyOn(conversionClient, 'getChapterManifest').mockReturnValue(pending.promise);
      const record = vi.spyOn(latencyObservations, 'record');
      const { result, unmount } = renderHook(
        () => useChapterStreamSession({ jobId: 'old', chapters }),
        {
          wrapper: createProvidersWrapper('en'),
        },
      );
      act(() => {
        result.current.handleStart();
      });
      unmount();
      record.mockClear();
      const timerCount = vi.getTimerCount();
      await act(async () => {
        settle(pending, outcome);
      });
      expect(record).not.toHaveBeenCalled();
      expect(vi.getTimerCount()).toBe(timerCount);
    },
  );
});
