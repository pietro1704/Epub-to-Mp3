import { useCallback } from 'react';
import { conversionCache } from '../services/ConversionCache';
import { ConversionFormValues } from '../types/conversion';
import type { ConversionStateScope } from './useConversionState';
import type { ConversionSnapshotsScope } from './useConversionSnapshots';
import type { ConversionRunSessionScope } from './useConversionRunSession';
import type { ConversionQueueScope } from './useConversionQueue';
import type { ConversionResumeScope } from './useConversionResume';
import type { ConversionControlsScope } from './useConversionControls';

type ConversionIntentsInput = Pick<
  ConversionStateScope,
  | 'state'
  | 'setSavedBatch'
  | 'cachedJobs'
  | 'cachedJobsLoading'
  | 'recentJobs'
  | 'apiAvailable'
  | 'healthStatus'
  | 'queueSnapshot'
  | 'queuePaused'
  | 'savedBatch'
> &
  Pick<ConversionSnapshotsScope, 'markApiOnline'> &
  Pick<ConversionRunSessionScope, 'reset'> &
  Pick<ConversionQueueScope, 'submit' | 'enqueue'> &
  Pick<ConversionResumeScope, 'resume'> &
  Pick<
    ConversionControlsScope,
    | 'cancel'
    | 'skipCurrent'
    | 'cancelJobById'
    | 'removeCachedJob'
    | 'uploadFile'
    | 'resumeQueue'
    | 'clearQueue'
    | 'reorderQueue'
    | 'restartBackend'
  >;

export function useConversionIntents({
  state,
  setSavedBatch,
  submit,
  enqueue,
  resume,
  reset,
  cancel,
  skipCurrent,
  cancelJobById,
  removeCachedJob,
  uploadFile,
  cachedJobs,
  cachedJobsLoading,
  recentJobs,
  apiAvailable,
  healthStatus,
  markApiOnline,
  queueSnapshot,
  queuePaused,
  resumeQueue,
  clearQueue,
  reorderQueue,
  restartBackend,
  savedBatch,
}: ConversionIntentsInput) {
  const isBusy =
    state.phase === 'submitting' || state.phase === 'polling' || state.phase === 'cancelling';

  const resumeBatch = useCallback(
    async (queue: ConversionFormValues[]) => {
      if (!queue.length) return;
      // Items whose File was lost during serialisation and have no uploadId
      // cannot be converted — skip them silently.
      const resumable = queue.filter((item) => item.file instanceof File || Boolean(item.uploadId));
      conversionCache.clearPendingBatch();
      setSavedBatch(null);
      if (!resumable.length) return;
      const [first, ...rest] = resumable;
      await submit(first, rest.length ? { batchQueue: rest } : undefined);
    },
    [submit],
  );

  const dismissSavedBatch = useCallback(() => {
    conversionCache.clearPendingBatch();
    setSavedBatch(null);
  }, []);

  return {
    state,
    submit,
    enqueue,
    resume,
    reset,
    cancel,
    skipCurrent,
    cancelJobById,
    removeCachedJob,
    uploadFile,
    isBusy,
    cachedJobs,
    cachedJobsLoading,
    recentJobs,
    apiAvailable,
    healthStatus,
    notifyServerReady: markApiOnline,
    queue: queueSnapshot,
    queuePaused,
    resumeQueue,
    clearQueue,
    reorderQueue,
    restartBackend,
    savedBatch,
    resumeBatch,
    dismissSavedBatch,
  };
}

export type ConversionIntentsScope = ReturnType<typeof useConversionIntents>;
