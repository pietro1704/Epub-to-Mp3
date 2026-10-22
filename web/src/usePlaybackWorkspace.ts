import { useCallback, useEffect, useMemo } from 'react';
import type { RecentJobEntry } from './types/conversion';
import type { ReadyDownloadJob } from './components/ReadyDownloadsList';
import { formatEta } from './utils/formatEta';
import type { ApplicationStateScope } from './useApplicationState';
import type { WorkspaceIntentsScope } from './useWorkspaceIntents';

type PlaybackWorkspaceInput = Pick<
  ApplicationStateScope,
  | 'viewingRecentJob'
  | 'state'
  | 't'
  | 'recentJobs'
  | 'batchHistory'
  | 'repeatConfig'
  | 'queue'
  | 'queuePlanTotal'
  | 'locale'
  | 'activeTab'
  | 'setIsHfSpace'
> &
  Pick<WorkspaceIntentsScope, 'clearRecentJobView' | 'showUploadingStatus'>;

export function usePlaybackWorkspace({
  viewingRecentJob,
  state,
  t,
  clearRecentJobView,
  recentJobs,
  batchHistory,
  repeatConfig,
  queue,
  queuePlanTotal,
  locale,
  activeTab,
  showUploadingStatus,
  setIsHfSpace,
}: PlaybackWorkspaceInput) {
  const displayedDownloads = useMemo(() => {
    if (viewingRecentJob) {
      if (Array.isArray(viewingRecentJob.outputs) && viewingRecentJob.outputs.length > 0) {
        return viewingRecentJob.outputs;
      }
      if (viewingRecentJob.downloadUrl) {
        const fallbackName =
          viewingRecentJob.fileName || `${viewingRecentJob.bookTitle || 'book'}.zip`;
        return [
          {
            name: fallbackName,
            url: viewingRecentJob.downloadUrl,
          },
        ];
      }
    }
    return state.downloads;
  }, [state.downloads, viewingRecentJob]);

  const shareDownloadTitle = useMemo(() => {
    if (viewingRecentJob?.bookTitle) {
      return viewingRecentJob.bookTitle;
    }
    if (state.bookTitle) {
      return state.bookTitle;
    }
    return t.status.bookFallbackTitle;
  }, [state.bookTitle, t.status.bookFallbackTitle, viewingRecentJob]);

  const formatLanguageLabel = useCallback(
    (code?: string | null) => {
      if (!code) return '';
      const options = t.form.languageOptions ?? {};
      if (options[code as keyof typeof options]) {
        return options[code as keyof typeof options];
      }
      const normalized = code.toLowerCase();
      if (options[normalized as keyof typeof options]) {
        return options[normalized as keyof typeof options];
      }
      const [base] = normalized.split(/[-_]/);
      if (base && options[base as keyof typeof options]) {
        return options[base as keyof typeof options];
      }
      return code.toUpperCase();
    },
    [t.form.languageOptions],
  );

  const downloadsContext = useMemo(() => {
    if (!viewingRecentJob || !viewingRecentJob.outputs || viewingRecentJob.outputs.length === 0) {
      return undefined;
    }
    return {
      title: t.downloads.viewingJobTitle(viewingRecentJob.bookTitle),
      subtitle: t.downloads.viewingJobSubtitle,
      actionLabel: t.downloads.viewingJobBackToCurrent,
      onAction: clearRecentJobView,
    };
  }, [clearRecentJobView, t.downloads, viewingRecentJob]);

  const readyDownloadJobs = useMemo<ReadyDownloadJob[]>(() => {
    const dedup = new Map<string, ReadyDownloadJob>();
    const register = (job: RecentJobEntry | null | undefined, source: 'current' | 'recent') => {
      if (!job) return;
      const hasOutputs = Array.isArray(job.outputs) && job.outputs.length > 0;
      const hasDownload = hasOutputs || Boolean(job.downloadUrl) || Boolean(job.hasOutputs);
      if (!hasDownload) {
        return;
      }
      const savedAtMs = job.savedAt ? Date.parse(job.savedAt) : Date.now();
      const entry: ReadyDownloadJob = {
        ...job,
        source,
        savedAtMs: Number.isNaN(savedAtMs) ? Date.now() : savedAtMs,
      };
      if (!dedup.has(entry.jobId)) {
        dedup.set(entry.jobId, entry);
      }
    };

    // Register recent jobs first so current jobs override them
    // Jobs in current session should not have remove button
    recentJobs.forEach((job) => register(job, 'recent'));
    batchHistory.forEach((job) => register(job, 'current'));

    return Array.from(dedup.values()).sort((a, b) => (b.savedAtMs ?? 0) - (a.savedAtMs ?? 0));
  }, [batchHistory, recentJobs]);

  const currentEngine = state.engine ?? repeatConfig?.engine;

  const currentVoice = state.voice ?? repeatConfig?.voice;

  const currentLanguageLabel = formatLanguageLabel(
    state.summary?.detectedLanguage ?? state.language ?? repeatConfig?.language,
  );

  // Format queue for display (MUST be declared before queuePosition)
  const queueForDisplay = useMemo(() => {
    return queue.map((item) => ({
      fileName: item.file?.name || item.fileName,
      bookTitle: item.file?.name || item.fileName,
      engine: item.engine,
      voice: item.voice,
    }));
  }, [queue]);

  // Calculate queue position for display
  const queuePosition = useMemo(() => {
    const activeJobCount = state.phase === 'polling' || state.phase === 'submitting' ? 1 : 0;
    if (activeJobCount === 0) return undefined;
    return queuePlanTotal > 0 ? queuePlanTotal - queueForDisplay.length : undefined;
  }, [queueForDisplay.length, queuePlanTotal, state.phase]);

  const queueTotal = useMemo(() => {
    const activeJobCount = state.phase === 'polling' || state.phase === 'submitting' ? 1 : 0;
    if (activeJobCount === 0) return undefined;
    return queuePlanTotal > 1 ? queuePlanTotal : undefined;
  }, [queuePlanTotal, state.phase]);

  const canCancelJob = Boolean(
    state.jobId && (state.phase === 'polling' || state.phase === 'cancelling'),
  );

  const canSkipJob = Boolean(state.jobId && state.phase === 'polling' && queue.length > 0);

  const cancelDisabled = state.phase === 'cancelling';

  const activeEtaDisplay = formatEta(state.phase, state.etaSeconds, locale, t);

  const showActiveConversion =
    activeTab === 'setup' && (state.phase !== 'idle' || showUploadingStatus);

  const canShowQueueAdder = Boolean(repeatConfig && state.phase !== 'idle');

  useEffect(() => {
    if (typeof window === 'undefined') {
      return;
    }
    const host = window.location.hostname.toLowerCase();
    const hfMatch = host.endsWith('.hf.space') || host.includes('huggingface.co');
    setIsHfSpace(hfMatch);
  }, []);

  return {
    queueForDisplay,
    readyDownloadJobs,
    showActiveConversion,
    activeEtaDisplay,
    currentEngine,
    currentVoice,
    currentLanguageLabel,
    canCancelJob,
    canSkipJob,
    cancelDisabled,
    canShowQueueAdder,
    displayedDownloads,
    downloadsContext,
    shareDownloadTitle,
    queuePosition,
    queueTotal,
  };
}

export type PlaybackWorkspaceScope = ReturnType<typeof usePlaybackWorkspace>;
