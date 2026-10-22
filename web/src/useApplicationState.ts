import { useEffect, useMemo, useRef, useState } from 'react';
import { isTauri } from './lib/tauri';
import { useConversionFlow } from './hooks/useConversionFlow';
import { useSystemStats } from './hooks/useSystemStats';
import { useI18n, useTranslations } from './i18n/I18nProvider';
import { conversionClient } from './services/ConversionService';
import type { ConversionState, RecentJobEntry, ConversionTemplate } from './types/conversion';
import { resolveApiUrl } from './config';
import {
  HfNotificationEntry,
  HIDDEN_RECENT_KEY,
  HIDDEN_RESUMABLE_KEY,
} from './ApplicationPresentation';
import type { AppProps } from './application_contract';

type ApplicationStateInput = { props?: AppProps };

export function useApplicationState({ props }: ApplicationStateInput) {
  const { client } = props ?? {};

  const {
    state,
    submit,
    enqueue,
    resume,
    reset,
    cancel,
    skipCurrent,
    isBusy,
    cachedJobs,
    cachedJobsLoading,
    removeCachedJob,
    uploadFile,
    recentJobs,
    healthStatus,
    notifyServerReady,
    queue,
    queuePaused,
    resumeQueue,
    clearQueue,
    reorderQueue,
    restartBackend,
    savedBatch,
    resumeBatch,
    dismissSavedBatch,
  } = useConversionFlow(client);

  const t = useTranslations();

  const { locale } = useI18n();

  const [isHelpOpen, setIsHelpOpen] = useState(false);

  const hasBackendDiagnostics = (client ?? conversionClient).mode === 'http';

  const statsPollInterval = isHelpOpen && hasBackendDiagnostics ? 5000 : 0;

  const apiHealthLabel = useMemo(() => {
    const url = resolveApiUrl('/api/health');
    if (url.startsWith('http')) {
      return url;
    }
    if (typeof window === 'undefined') {
      return url;
    }
    const prefix = url.startsWith('/') ? '' : '/';
    return `${window.location.origin}${prefix}${url}`;
  }, []);

  const {
    data: systemStats,
    error: systemStatsError,
    loading: systemStatsLoading,
    lastUpdated: systemStatsUpdatedAt,
    nextRetryMs: systemStatsNextRetry,
  } = useSystemStats(statsPollInterval);

  const systemStatsLabels = useMemo(
    () => ({
      title: t.layout.statsTitle,
      loading: t.layout.statsLoading,
      error: t.layout.statsError,
      uptime: t.layout.statsUptime,
      cpu: t.layout.statsCpu,
      memory: t.layout.statsMemory,
      queue: t.layout.statsQueue,
      running: t.layout.statsRunning,
      workers: t.layout.statsWorkers,
      recommendation: t.layout.statsRecommendation,
      gpu: t.layout.statsGpu,
      offline: t.layout.statsOffline,
      lastUpdated: t.layout.statsLastUpdated,
      retrying: t.layout.statsRetrying,
      target: t.layout.statsTarget,
      gpuUsage: t.layout.statsGpuUsage,
      gpuVram: t.layout.statsGpuVram,
      gpuTemp: t.layout.statsGpuTemp,
    }),
    [
      t.layout.statsCpu,
      t.layout.statsGpu,
      t.layout.statsLoading,
      t.layout.statsMemory,
      t.layout.statsQueue,
      t.layout.statsRecommendation,
      t.layout.statsRunning,
      t.layout.statsTitle,
      t.layout.statsUptime,
      t.layout.statsOffline,
      t.layout.statsLastUpdated,
      t.layout.statsRetrying,
      t.layout.statsTarget,
      t.layout.statsGpuUsage,
      t.layout.statsGpuVram,
      t.layout.statsGpuTemp,
      t.layout.statsError,
    ],
  );

  const telemetryLabels = useMemo(
    () => ({
      title: t.layout.telemetryTitle,
      description: t.layout.telemetryDescription,
      refresh: t.layout.telemetryRefresh,
      refreshing: t.layout.telemetryRefreshing,
      errorGeneric: t.layout.telemetryErrorGeneric,
      emptyState: t.layout.telemetryEmptyState,
      engineHeader: t.layout.telemetryEngineHeader,
      samplesHeader: t.layout.telemetrySamplesHeader,
      avgHeader: t.layout.telemetryAvgHeader,
      minHeader: t.layout.telemetryMinHeader,
      maxHeader: t.layout.telemetryMaxHeader,
      rankedLabel: t.layout.telemetryRankedLabel,
      timelineTitle: t.layout.telemetryTimelineTitle,
      timelineEmpty: t.layout.telemetryTimelineEmpty,
      timelineLatest: t.layout.telemetryTimelineLatest,
      // v0.3.25: lang breakdown. Strings are inlined here rather than
      // routed through ``t.layout`` because the panel is auxiliary and
      // adding three i18n keys per locale just for a debug breakdown is
      // not worth the churn.
      byLanguageTitle: locale === 'pt' ? 'Por idioma' : 'By language',
      byLanguageEmpty:
        locale === 'pt'
          ? 'Sem amostras com idioma registrado ainda.'
          : 'No language-tagged samples yet.',
      languageHeader: locale === 'pt' ? 'Idioma' : 'Lang',
      totalSamples: t.layout.telemetryTotalSamples,
      updatedAt: t.layout.telemetryUpdatedAt,
    }),
    [
      t.layout.telemetryTitle,
      t.layout.telemetryDescription,
      t.layout.telemetryRefresh,
      t.layout.telemetryRefreshing,
      t.layout.telemetryErrorGeneric,
      t.layout.telemetryEmptyState,
      t.layout.telemetryEngineHeader,
      t.layout.telemetrySamplesHeader,
      t.layout.telemetryAvgHeader,
      t.layout.telemetryMinHeader,
      t.layout.telemetryMaxHeader,
      t.layout.telemetryRankedLabel,
      t.layout.telemetryTimelineTitle,
      t.layout.telemetryTimelineEmpty,
      t.layout.telemetryTimelineLatest,
      t.layout.telemetryTotalSamples,
      t.layout.telemetryUpdatedAt,
      locale,
    ],
  );

  const [formVersion, setFormVersion] = useState(0);

  const [activeTab, setActiveTab] = useState<'setup' | 'progress' | 'downloads'>('setup');

  const [userSelectedTab, setUserSelectedTab] = useState(false);

  const [showRawLog, setShowRawLog] = useState(false);

  const [viewingRecentJob, setViewingRecentJob] = useState<RecentJobEntry | null>(null);

  const [repeatConfig, setRepeatConfig] = useState<ConversionTemplate | null>(null);

  const [batchHistory, setBatchHistory] = useState<RecentJobEntry[]>([]);

  const [queuePlanTotal, setQueuePlanTotal] = useState(0);

  const lastCompletedJobIdRef = useRef<string | null>(null);

  const manualDownloadOverrideRef = useRef(false);

  const lastPhaseRef = useRef<ConversionState['phase']>(state.phase);

  const notifiedBatchJobsRef = useRef<Set<string>>(new Set());

  const [pendingUploads, setPendingUploads] = useState(0);

  const hfNotificationCounterRef = useRef(0);

  const [isHfSpace, setIsHfSpace] = useState(false);

  const [hfNotifications, setHfNotifications] = useState<HfNotificationEntry[]>([]);

  const [isRestartingBackend, setIsRestartingBackend] = useState(false);

  const [restartDialog, setRestartDialog] = useState<'confirm' | 'cache' | 'finished' | null>(null);

  // Tauri-specific: tracks whether the Python sidecar failed to start.
  const [tauriEngineError, setTauriEngineError] = useState<string | null>(null);

  const [tauriStarting, setTauriStarting] = useState<boolean>(isTauri());

  const [tauriStartupLog, setTauriStartupLog] = useState<string[]>([]);

  const didRestartRef = useRef(false);

  const handleTauriStartupReadyRef = useRef<() => void>(() => {});

  const [startupLogsExpanded, setStartupLogsExpanded] = useState<boolean>(false);

  const restartOptionsRef = useRef({ keepCache: false, keepFinished: false });

  const [hiddenRecentIds, setHiddenRecentIds] = useState<Set<string>>(() => {
    if (typeof window === 'undefined') {
      return new Set();
    }
    try {
      const stored = localStorage.getItem(HIDDEN_RECENT_KEY);
      if (!stored) return new Set();
      const parsed = JSON.parse(stored);
      if (Array.isArray(parsed)) {
        return new Set(parsed.filter((id) => typeof id === 'string'));
      }
    } catch (_error) {}
    return new Set();
  });

  const [hiddenResumableIds, setHiddenResumableIds] = useState<Set<string>>(() => {
    if (typeof window === 'undefined') {
      return new Set();
    }
    try {
      const stored = localStorage.getItem(HIDDEN_RESUMABLE_KEY);
      if (!stored) return new Set();
      const parsed = JSON.parse(stored);
      if (Array.isArray(parsed)) {
        return new Set(parsed.filter((id) => typeof id === 'string'));
      }
    } catch (_error) {}
    return new Set();
  });

  useEffect(() => {
    if (typeof window === 'undefined') {
      return;
    }
    localStorage.setItem(HIDDEN_RECENT_KEY, JSON.stringify(Array.from(hiddenRecentIds)));
  }, [hiddenRecentIds]);

  useEffect(() => {
    if (typeof window === 'undefined') {
      return;
    }
    localStorage.setItem(HIDDEN_RESUMABLE_KEY, JSON.stringify(Array.from(hiddenResumableIds)));
  }, [hiddenResumableIds]);

  return {
    setTauriStarting,
    setTauriEngineError,
    handleTauriStartupReadyRef,
    setTauriStartupLog,
    tauriStarting,
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
    didRestartRef,
    notifyServerReady,
    setRepeatConfig,
    locale,
    submit,
    enqueue,
    cancel,
    skipCurrent,
    setHiddenRecentIds,
    removeCachedJob,
    recentJobs,
    batchHistory,
    repeatConfig,
    queue,
    queuePlanTotal,
    activeTab,
    setIsHfSpace,
    setHfNotifications,
    isHfSpace,
    hfNotificationCounterRef,
    hiddenRecentIds,
    cachedJobs,
    hiddenResumableIds,
    queuePaused,
    resumeQueue,
    clearQueue,
    reorderQueue,
    userSelectedTab,
    lastPhaseRef,
    isHelpOpen,
    setIsHelpOpen,
    isRestartingBackend,
    restartOptionsRef,
    setRestartDialog,
    restartDialog,
    setIsRestartingBackend,
    restartBackend,
    notifiedBatchJobsRef,
    uploadFile,
    formVersion,
    setPendingUploads,
    showRawLog,
    isBusy,
    resume,
    setHiddenResumableIds,
    healthStatus,
    apiHealthLabel,
    tauriStartupLog,
    setStartupLogsExpanded,
    startupLogsExpanded,
    tauriEngineError,
    savedBatch,
    resumeBatch,
    dismissSavedBatch,
    cachedJobsLoading,
    hasBackendDiagnostics,
    systemStats,
    systemStatsLabels,
    systemStatsError,
    systemStatsLoading,
    systemStatsUpdatedAt,
    systemStatsNextRetry,
    telemetryLabels,
    hfNotifications,
  };
}

export type ApplicationStateScope = ReturnType<typeof useApplicationState>;
