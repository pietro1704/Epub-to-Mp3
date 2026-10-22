import { useCallback, useEffect } from 'react';
import { RestartOptions } from '../services/ConversionService';
import { conversionCache } from '../services/ConversionCache';
import { resolveApiUrl } from '../config';
import { isNetworkError } from './conversion_runtime_health';
import type { ConversionStateScope } from './useConversionState';
import type { ConversionSnapshotsScope } from './useConversionSnapshots';
import type { ConversionRunSessionScope } from './useConversionRunSession';
import type { ConversionQueueScope } from './useConversionQueue';

type ConversionControlsInput = Pick<
  ConversionStateScope,
  | 'abortRef'
  | 'state'
  | 'startTimeRef'
  | 'entryFactoryRef'
  | 't'
  | 'dispatch'
  | 'jobQueueRef'
  | 'queueActiveRef'
  | 'setQueuePaused'
  | 'processedCountRef'
  | 'api'
  | 'skipModeRef'
  | 'apiAvailable'
  | 'setCachedJobs'
  | 'syncQueueSnapshot'
  | 'beginRestartGrace'
  | 'setRecentJobs'
> &
  Pick<ConversionSnapshotsScope, 'clearCancelledJob' | 'markApiOnline' | 'markApiOffline'> &
  Pick<ConversionRunSessionScope, 'reset'> &
  Pick<ConversionQueueScope, 'drainQueue'>;

export function useConversionControls({
  abortRef,
  state,
  startTimeRef,
  entryFactoryRef,
  t,
  dispatch,
  clearCancelledJob,
  jobQueueRef,
  queueActiveRef,
  setQueuePaused,
  processedCountRef,
  api,
  skipModeRef,
  drainQueue,
  apiAvailable,
  setCachedJobs,
  markApiOnline,
  markApiOffline,
  syncQueueSnapshot,
  beginRestartGrace,
  reset,
  setRecentJobs,
}: ConversionControlsInput) {
  useEffect(() => {
    return () => {
      abortRef.current?.abort();
    };
  }, []);

  const cancel = useCallback(async (): Promise<boolean> => {
    if (state.phase === 'idle' || state.phase === 'success' || state.phase === 'error') {
      return false;
    }
    const controller = abortRef.current;
    if (controller && typeof controller.abort === 'function') {
      controller.abort();
    }
    abortRef.current = null;
    startTimeRef.current = null;

    const entry = entryFactoryRef.current(t.flow.cancelled);
    dispatch({
      type: 'cancelled',
      error: t.flow.cancelled,
      entry,
    });

    if (state.jobId) {
      clearCancelledJob(state.jobId);
    }

    // Pause the queue instead of clearing it
    if (jobQueueRef.current.length > 0 || queueActiveRef.current) {
      setQueuePaused(true);
    }
    processedCountRef.current = 0;

    const jobId = state.jobId;
    const cancelFn = api?.cancel;
    const removeFn = api?.removeJob;
    if (jobId && !removeFn && typeof cancelFn === 'function') {
      void (async () => {
        try {
          await cancelFn.call(api, jobId);
        } catch (error) {
          const message =
            error instanceof Error && error.message ? error.message : t.flow.cancelFailed('');
          dispatch({
            type: 'append-entry',
            entry: entryFactoryRef.current(t.flow.cancelFailed(message)),
          });
        }
      })();
    }

    return true;
  }, [api, clearCancelledJob, setQueuePaused, state.jobId, state.phase, t]);

  const skipCurrent = useCallback(async (): Promise<boolean> => {
    if (state.phase === 'idle' || state.phase === 'success' || state.phase === 'error') {
      return false;
    }

    // Check if there's a queue to continue with
    if (jobQueueRef.current.length === 0) {
      // No queue, just cancel normally
      return cancel();
    }

    console.log(
      '[skipCurrent] Skipping current job. Queue has',
      jobQueueRef.current.length,
      'jobs. Queue active:',
      queueActiveRef.current,
    );

    // Set skip mode flag so drainQueue knows not to pause
    skipModeRef.current = true;

    const controller = abortRef.current;
    if (controller && typeof controller.abort === 'function') {
      controller.abort();
    }
    abortRef.current = null;
    startTimeRef.current = null;

    const entry = entryFactoryRef.current(
      t.flow.skipped || 'Current conversion skipped, moving to next',
    );
    dispatch({
      type: 'cancelled',
      error: t.flow.skipped || 'Skipped',
      entry,
    });

    const jobId = state.jobId;
    const cancelFn = api?.cancel;
    const removeFn = api?.removeJob;
    if (jobId) {
      if (!removeFn && typeof cancelFn === 'function') {
        void (async () => {
          try {
            await cancelFn.call(api, jobId);
          } catch (error) {
            console.warn('[skipCurrent] Failed to cancel job on backend:', error);
          } finally {
            clearCancelledJob(jobId);
          }
        })();
      } else {
        clearCancelledJob(jobId);
      }
    }

    // If drainQueue is not active, we need to start it manually
    if (!queueActiveRef.current) {
      console.log('[skipCurrent] Queue not active, starting drain');
      dispatch({
        type: 'append-entry',
        entry: entryFactoryRef.current(
          `⏭️ Skipping to next queued book (${jobQueueRef.current.length} remaining)`,
        ),
      });
      // Give time for the cancel to propagate
      await new Promise((resolve) => setTimeout(resolve, 100));
      void drainQueue();
    } else {
      console.log('[skipCurrent] Queue already active, will continue automatically');
      dispatch({
        type: 'append-entry',
        entry: entryFactoryRef.current(
          `⏭️ Skipping to next queued book (${jobQueueRef.current.length} remaining)`,
        ),
      });
    }

    return true;
  }, [api, cancel, clearCancelledJob, drainQueue, state.jobId, state.phase, t]);

  const cancelJobById = useCallback(
    async (jobId: string) => {
      const removeFn = api?.removeJob;
      if (!jobId || !apiAvailable) {
        clearCancelledJob(jobId);
        return;
      }
      if (removeFn) {
        clearCancelledJob(jobId);
        return;
      }
      if (!api.cancel) {
        clearCancelledJob(jobId);
        return;
      }
      try {
        await api.cancel(jobId);
      } catch (error) {
        console.warn('[useConversionFlow] Failed to cancel cached job', jobId, error);
      } finally {
        clearCancelledJob(jobId);
      }
    },
    [api, apiAvailable, clearCancelledJob],
  );

  const removeCachedJob = useCallback(
    (jobId: string) => {
      setCachedJobs((prev) => prev.filter((job) => job.jobId !== jobId));
      conversionCache.remove(jobId);
      const removeFn = api?.removeJob;
      if (jobId && removeFn && apiAvailable) {
        void (async () => {
          try {
            await removeFn.call(api, jobId);
          } catch (error) {
            console.warn('[useConversionFlow] Failed to remove job on backend', jobId, error);
          }
        })();
      }
    },
    [api, apiAvailable],
  );

  const uploadFile = useCallback(
    async (file: File) => {
      if (!apiAvailable) {
        throw new Error(t.flow.backendOffline);
      }
      if (!api.upload) {
        throw new Error('Upload not supported by current client');
      }
      try {
        const response = await api.upload(file);
        markApiOnline();
        dispatch({
          type: 'update-meta',
          details: {
            bookTitle: response.bookTitle,
            bookAuthor: response.bookAuthor,
            coverUrl: response.coverUrl,
          },
        });
        return response;
      } catch (error) {
        if (isNetworkError(error)) {
          markApiOffline();
        }
        throw error;
      }
    },
    [api, apiAvailable, markApiOffline, markApiOnline, t],
  );

  const resumeQueue = useCallback(() => {
    if (jobQueueRef.current.length === 0) {
      return;
    }
    setQueuePaused(false);
    processedCountRef.current = 0;
    void drainQueue();
  }, [drainQueue, setQueuePaused]);

  const clearQueue = useCallback(() => {
    jobQueueRef.current = [];
    conversionCache.clearPendingBatch();
    setQueuePaused(false);
    processedCountRef.current = 0;
    syncQueueSnapshot();
  }, [setQueuePaused, syncQueueSnapshot]);

  const reorderQueue = useCallback(
    (fromIndex: number, toIndex: number) => {
      const queue = jobQueueRef.current;
      if (queue.length < 2) {
        return;
      }
      if (fromIndex < 0 || fromIndex >= queue.length) {
        return;
      }
      const target = Math.max(0, Math.min(queue.length - 1, toIndex));
      if (fromIndex === target) {
        return;
      }
      const [item] = queue.splice(fromIndex, 1);
      queue.splice(target, 0, item);
      syncQueueSnapshot();
    },
    [syncQueueSnapshot],
  );

  const restartBackend = useCallback(
    async (options?: RestartOptions) => {
      if (!api.restartBackend) {
        throw new Error('Restart not supported in this client');
      }
      beginRestartGrace();
      reset();
      clearQueue();
      conversionCache.clearAll();
      setCachedJobs([]);
      setRecentJobs([]);
      await api.restartBackend(options);

      // Poll for backend health and auto-reload when ready
      const pollInterval = 2000; // 2 seconds
      const maxAttempts = 30; // 60 seconds max wait
      let attempts = 0;

      const checkHealth = async (): Promise<boolean> => {
        try {
          const response = await fetch(resolveApiUrl('/api/health'));
          if (response.ok) {
            const data = await response.json();
            return data.status === 'healthy';
          }
        } catch {
          // Server not ready yet
        }
        return false;
      };

      const pollForHealth = async () => {
        attempts++;
        const isHealthy = await checkHealth();
        if (isHealthy) {
          // Backend is ready, reload the page
          console.log('[Restart] Backend is healthy, reloading page...');
          window.location.reload();
        } else if (attempts < maxAttempts) {
          setTimeout(pollForHealth, pollInterval);
        } else {
          console.warn('[Restart] Backend did not become healthy in time');
          // Still try to reload in case it's working
          window.location.reload();
        }
      };

      // Start polling after a short delay to allow backend to shut down
      setTimeout(pollForHealth, 3000);
    },
    [api, beginRestartGrace, clearQueue, reset],
  );

  return {
    cancel,
    skipCurrent,
    cancelJobById,
    removeCachedJob,
    uploadFile,
    resumeQueue,
    clearQueue,
    reorderQueue,
    restartBackend,
  };
}

export type ConversionControlsScope = ReturnType<typeof useConversionControls>;
