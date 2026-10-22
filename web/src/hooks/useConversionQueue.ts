import { useCallback } from 'react';
import { conversionCache } from '../services/ConversionCache';
import { ConversionFormValues, SubmitBatchOptions } from '../types/conversion';
import type { ConversionStateScope } from './useConversionState';
import type { ConversionRunSessionScope } from './useConversionRunSession';

type ConversionQueueInput = Pick<
  ConversionStateScope,
  | 'queueActiveRef'
  | 'queueGenerationRef'
  | 'queuePausedRef'
  | 'jobQueueRef'
  | 'syncQueueSnapshot'
  | 'processedCountRef'
  | 'skipModeRef'
  | 'dispatch'
  | 'setQueuePaused'
  | 'entryFactoryRef'
  | 't'
  | 'state'
  | 'saveStateWithQueue'
  | 'fileNameRef'
  | 'setSavedBatch'
> &
  Pick<ConversionRunSessionScope, 'runConversion'>;

export function useConversionQueue({
  queueActiveRef,
  queueGenerationRef,
  queuePausedRef,
  jobQueueRef,
  syncQueueSnapshot,
  processedCountRef,
  runConversion,
  skipModeRef,
  dispatch,
  setQueuePaused,
  entryFactoryRef,
  t,
  state,
  saveStateWithQueue,
  fileNameRef,
  setSavedBatch,
}: ConversionQueueInput) {
  const drainQueue = useCallback(async () => {
    if (queueActiveRef.current || queuePausedRef.current) {
      console.log(
        '[drainQueue] Skipping - active:',
        queueActiveRef.current,
        'paused:',
        queuePausedRef.current,
      );
      return;
    }
    queueActiveRef.current = true;
    const generation = queueGenerationRef.current;
    console.log(
      '[drainQueue] Starting queue processing. Jobs in queue:',
      jobQueueRef.current.length,
    );
    try {
      while (jobQueueRef.current.length > 0) {
        if (queuePausedRef.current) {
          console.log('[drainQueue] Queue paused, breaking');
          break;
        }
        // Persist current + remaining queue before each job starts
        conversionCache.savePendingBatch(jobQueueRef.current);
        const currentJob = jobQueueRef.current.shift();
        if (!currentJob) {
          console.log('[drainQueue] No current job, breaking');
          break;
        }
        syncQueueSnapshot();
        const currentIndex = processedCountRef.current + 1;
        const total = currentIndex + jobQueueRef.current.length;
        const meta = total > 1 ? { index: currentIndex, total } : undefined;
        console.log('[drainQueue] Processing job', currentIndex, 'of', total);
        const result = await runConversion(currentJob, meta);
        if (generation !== queueGenerationRef.current) return;
        console.log('[drainQueue] Job completed with result:', result);

        // Save remaining queue if there was a failure or cancellation
        if (result === 'cancelled' || result === 'failed') {
          if (result === 'cancelled') {
            // Check if we're in skip mode
            console.log('[drainQueue] Cancelled detected. Skip mode:', skipModeRef.current);
            if (skipModeRef.current) {
              // Skip mode: don't pause queue, don't put job back, just continue
              skipModeRef.current = false; // Reset flag
              console.log(
                '[drainQueue] Skip mode: continuing to next job. Remaining:',
                jobQueueRef.current.length,
              );
              dispatch({
                type: 'reset',
              });
              // Continue to next job without pausing
            } else {
              // Normal cancel: pause queue and drop current job.
              // Update saved batch so the cancelled book is not offered on reload.
              if (jobQueueRef.current.length > 0) {
                conversionCache.savePendingBatch(jobQueueRef.current);
              } else {
                conversionCache.clearPendingBatch();
              }
              console.log('[drainQueue] Normal cancel: pausing queue');
              syncQueueSnapshot();
              setQueuePaused(true);
              const remaining = jobQueueRef.current.length;
              dispatch({
                type: 'append-entry',
                entry: entryFactoryRef.current(t.flow.batchCancelled(remaining)),
              });
              break;
            }
          }

          if (result === 'failed' && jobQueueRef.current.length > 0 && state.jobId) {
            // Save the remaining queue with the current job state
            saveStateWithQueue(state.jobId, fileNameRef.current, state);
          }
          // For 'failed', continue to next job in queue
        }
        processedCountRef.current += 1;
        console.log(
          '[drainQueue] Processed count:',
          processedCountRef.current,
          'Remaining jobs:',
          jobQueueRef.current.length,
        );
      }
      console.log('[drainQueue] Queue processing finished');
    } finally {
      if (generation === queueGenerationRef.current) {
        queueActiveRef.current = false;
        if (jobQueueRef.current.length === 0) {
          setQueuePaused(false);
          conversionCache.clearPendingBatch();
        }
        processedCountRef.current = 0;
        console.log('[drainQueue] Cleanup complete. Queue active:', queueActiveRef.current);
      }
    }
  }, [dispatch, runConversion, setQueuePaused, state, syncQueueSnapshot, t.flow.batchCancelled]);

  const submit = useCallback(
    async (values: ConversionFormValues, options?: SubmitBatchOptions) => {
      const queue = [values, ...(options?.batchQueue ?? [])].filter(Boolean);
      if (queue.length === 0) {
        return;
      }
      conversionCache.savePendingBatch(queue);
      setSavedBatch(null);
      jobQueueRef.current = queue;
      syncQueueSnapshot();
      setQueuePaused(false);
      processedCountRef.current = 0;
      await drainQueue();
    },
    [drainQueue, setQueuePaused, syncQueueSnapshot],
  );

  const enqueue = useCallback(
    async (jobs: ConversionFormValues[]) => {
      const normalized = jobs.filter(Boolean);
      if (normalized.length === 0) {
        return;
      }
      jobQueueRef.current.push(...normalized);
      syncQueueSnapshot();
      if (!queueActiveRef.current && !queuePausedRef.current) {
        processedCountRef.current = 0;
        await drainQueue();
      }
    },
    [drainQueue, syncQueueSnapshot],
  );

  return { drainQueue, submit, enqueue };
}

export type ConversionQueueScope = ReturnType<typeof useConversionQueue>;
