import { useCallback, useEffect } from 'react';
import type { ConversionFormValues, SubmitBatchOptions } from './types/conversion';
import type { ReadyDownloadJob } from './components/ReadyDownloadsList';
import type { ApplicationStateScope } from './useApplicationState';

type WorkspaceIntentsInput = Pick<
  ApplicationStateScope,
  | 'state'
  | 'pendingUploads'
  | 't'
  | 'viewingRecentJob'
  | 'manualDownloadOverrideRef'
  | 'setViewingRecentJob'
  | 'reset'
  | 'setFormVersion'
  | 'setActiveTab'
  | 'setUserSelectedTab'
  | 'setShowRawLog'
  | 'setBatchHistory'
  | 'lastCompletedJobIdRef'
  | 'setQueuePlanTotal'
  | 'setTauriStarting'
  | 'didRestartRef'
  | 'notifyServerReady'
  | 'handleTauriStartupReadyRef'
  | 'setRepeatConfig'
  | 'locale'
  | 'submit'
  | 'enqueue'
  | 'cancel'
  | 'skipCurrent'
  | 'setHiddenRecentIds'
  | 'removeCachedJob'
>;

export function useWorkspaceIntents({
  state,
  pendingUploads,
  t,
  viewingRecentJob,
  manualDownloadOverrideRef,
  setViewingRecentJob,
  reset,
  setFormVersion,
  setActiveTab,
  setUserSelectedTab,
  setShowRawLog,
  setBatchHistory,
  lastCompletedJobIdRef,
  setQueuePlanTotal,
  setTauriStarting,
  didRestartRef,
  notifyServerReady,
  handleTauriStartupReadyRef,
  setRepeatConfig,
  locale,
  submit,
  enqueue,
  cancel,
  skipCurrent,
  setHiddenRecentIds,
  removeCachedJob,
}: WorkspaceIntentsInput) {
  const formLocked = state.phase === 'submitting' || state.phase === 'cancelling';

  const showUploadingStatus = pendingUploads > 0 && state.phase === 'idle';

  const statusLabelOverride = showUploadingStatus
    ? t.status.uploadingFiles
    : t.status.phases[state.phase];

  const hasDownloads = Array.isArray(state.downloads) && state.downloads.length > 0;

  const canViewProgress =
    showUploadingStatus ||
    state.phase !== 'idle' ||
    state.log.length > 0 ||
    Boolean(state.summary) ||
    Boolean(state.error) ||
    Boolean(state.jobId);

  const canViewDownloads =
    hasDownloads ||
    state.phase === 'success' ||
    Boolean(viewingRecentJob && (viewingRecentJob.outputs?.length || viewingRecentJob.downloadUrl));

  const clearRecentJobView = useCallback(() => {
    manualDownloadOverrideRef.current = true;
    setViewingRecentJob(null);
  }, []);

  const handleReset = useCallback(() => {
    reset();
    setFormVersion((value) => value + 1);
    setActiveTab('setup');
    setUserSelectedTab(false);
    setShowRawLog(false);
    clearRecentJobView();
    setBatchHistory([]);
    lastCompletedJobIdRef.current = null;
    setQueuePlanTotal(0);
  }, [clearRecentJobView, reset]);

  const handleTauriStartupReady = useCallback(() => {
    setTauriStarting(false);
    if (didRestartRef.current) {
      handleReset();
    }
    didRestartRef.current = true;
    notifyServerReady();
  }, [handleReset, notifyServerReady]);

  useEffect(() => {
    handleTauriStartupReadyRef.current = handleTauriStartupReady;
  }, [handleTauriStartupReady]);

  const handleTabChange = useCallback(
    (tabId: 'setup' | 'progress' | 'downloads') => {
      const allowed =
        tabId === 'setup' ? true : tabId === 'progress' ? canViewProgress : canViewDownloads;
      if (!allowed) {
        return;
      }
      setActiveTab(tabId);
      setUserSelectedTab(true);
    },
    [canViewDownloads, canViewProgress],
  );

  const handleSelectReadyDownload = useCallback((job: ReadyDownloadJob) => {
    manualDownloadOverrideRef.current = true;
    setViewingRecentJob(job);
    setActiveTab('downloads');
    setUserSelectedTab(true);
  }, []);

  const handleSubmitIntent = useCallback(() => {
    setActiveTab('progress');
    setUserSelectedTab(false);
  }, []);

  const handleQueueJobsAdded = useCallback((count: number) => {
    if (count > 0) {
      setQueuePlanTotal((prev) => prev + count);
    }
  }, []);

  const handleFormSubmit = useCallback(
    async (values: ConversionFormValues, options?: SubmitBatchOptions) => {
      setActiveTab('progress');
      setUserSelectedTab(false);
      clearRecentJobView();
      setRepeatConfig({
        engine: values.engine,
        voice: values.voice,
        model: values.model,
        chapters: values.chapters,
        sections: values.sections,
        priority: values.priority,
        footnoteMode: values.footnoteMode,
        language: values.language,
        formattingCues: values.formattingCues ?? true,
        noParallel: values.noParallel,
        maxPerformance: values.maxPerformance,
        parallelSlots: values.parallelSlots,
        chapterStallSeconds: values.chapterStallSeconds,
        edgeNetworkTier: values.edgeNetworkTier,
        edgeChunkChars: values.edgeChunkChars,
        edgeMaxSegmentSeconds: values.edgeMaxSegmentSeconds,
        edgeEnableParallel: values.edgeEnableParallel,
        edgeAutoTune: values.edgeAutoTune,
        edgeStableMode: values.edgeStableMode,
        piperMaxProcs: values.piperMaxProcs,
        bitrate: values.bitrate,
        sampleRate: values.sampleRate,
        channels: values.channels,
        clearCache: values.clearCache,
        forceReprocess: values.forceReprocess,
        filterChapters: values.filterChapters,
        verbose: values.verbose,
        useLanguageDetection: values.useLanguageDetection,
        prioritizePrimaryLanguage: values.prioritizePrimaryLanguage,
        healthCheckIntervalSeconds: values.healthCheckIntervalSeconds,
        healthCheckSlowEdgeCps: values.healthCheckSlowEdgeCps,
        healthCheckSlowCps: values.healthCheckSlowCps,
        healthCheckHighCpu: values.healthCheckHighCpu,
        healthCheckHighMem: values.healthCheckHighMem,
        healthCheckOkCpu: values.healthCheckOkCpu,
        healthCheckOkMem: values.healthCheckOkMem,
        healthCheckSlowStreak: values.healthCheckSlowStreak,
        uiLanguage: locale,
      });

      const queue = [values, ...(options?.batchQueue ?? [])].filter(Boolean);
      if (queue.length === 0) {
        return;
      }
      setQueuePlanTotal(queue.length);
      if (state.phase === 'idle') {
        const [first, ...rest] = queue;
        await submit(first, { batchQueue: rest });
        return;
      }
      await enqueue(queue);
    },
    [clearRecentJobView, enqueue, state.phase, submit],
  );

  const handleCancelClick = useCallback(() => {
    if (!state.jobId) return;
    const message = t.flow.cancelConfirm;
    if (typeof window !== 'undefined' && typeof window.confirm === 'function') {
      if (!window.confirm(message)) {
        return;
      }
    }
    void (async () => {
      await cancel();
      // Don't auto-reset after cancellation - let user see the "cancelled" state
      // User can start a new conversion to reset
    })();
  }, [cancel, state.jobId, t.flow.cancelConfirm]);

  const handleSkipClick = useCallback(() => {
    if (!state.jobId) return;
    const message = t.flow.skipConfirm;
    if (typeof window !== 'undefined' && typeof window.confirm === 'function') {
      if (!window.confirm(message)) {
        return;
      }
    }
    void (async () => {
      await skipCurrent();
    })();
  }, [skipCurrent, state.jobId, t.flow.skipConfirm]);

  const handleRemoveRecentJob = useCallback(
    (jobId: string) => {
      setHiddenRecentIds((prev) => {
        const next = new Set(prev);
        next.add(jobId);
        return next;
      });
      if (viewingRecentJob?.jobId === jobId) {
        clearRecentJobView();
      }
      // Also remove from backend cache
      removeCachedJob(jobId);
    },
    [clearRecentJobView, removeCachedJob, viewingRecentJob],
  );

  return {
    clearRecentJobView,
    showUploadingStatus,
    hasDownloads,
    handleTabChange,
    statusLabelOverride,
    handleCancelClick,
    handleSkipClick,
    handleQueueJobsAdded,
    formLocked,
    handleFormSubmit,
    handleSubmitIntent,
    handleSelectReadyDownload,
    handleRemoveRecentJob,
    handleReset,
    canViewProgress,
    canViewDownloads,
  };
}

export type WorkspaceIntentsScope = ReturnType<typeof useWorkspaceIntents>;
