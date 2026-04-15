import {
  CSSProperties,
  lazy,
  Suspense,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import Hero from "./components/Hero";
import Layout from "./components/Layout";
import Panel from "./components/Panel";
import { invoke, isTauri, listenTauri, sendNotification } from "./lib/tauri";

// Lazy load heavy components
const ConversionForm = lazy(() => import("./components/ConversionForm"));
const DownloadsPanel = lazy(() => import("./components/DownloadsPanel"));
const StatusPanel = lazy(() => import("./components/StatusPanel"));
const RecentJobsPanel = lazy(() => import("./components/RecentJobsPanel"));
const ResumableJobsPanel = lazy(
  () => import("./components/ResumableJobsPanel"),
);
const QuickQueueAdder = lazy(() => import("./components/QuickQueueAdder"));
const ActiveConversionBanner = lazy(
  () => import("./components/ActiveConversionBanner"),
);
const ReadyDownloadsList = lazy(() =>
  import("./components/ReadyDownloadsList").then((m) => ({
    default: m.default,
  })),
);
const QueueDisplay = lazy(() => import("./components/QueueDisplay"));
const SystemStatsPanel = lazy(() => import("./components/SystemStatsPanel"));
const TelemetryPanel = lazy(() => import("./components/TelemetryPanel"));
const ConversionHistoryPanel = lazy(
  () => import("./components/ConversionHistoryPanel"),
);
const ConfirmDialog = lazy(() => import("./components/ConfirmDialog"));
import { useConversionFlow } from "./hooks/useConversionFlow";
import { useSystemStats } from "./hooks/useSystemStats";
import { useI18n, useTranslations } from "./i18n/I18nProvider";
import type { ConversionClient } from "./services/ConversionService";
import type {
  ConversionFormValues,
  ConversionState,
  RecentJobEntry,
  SubmitBatchOptions,
  ConversionTemplate,
} from "./types/conversion";
import type { ReadyDownloadJob } from "./components/ReadyDownloadsList";
import { formatEta } from "./utils/formatEta";
import { resolveApiUrl } from "./config";
import { reportUiIssue } from "./services/uiIssueMonitor";

// Loading fallback component
const ComponentFallback = () => <div style={{ minHeight: "100px" }} />;

type HfNotificationVariant = "info" | "success" | "error";

interface HfNotificationEntry {
  id: number;
  title: string;
  body?: string;
  variant: HfNotificationVariant;
}

interface HfNotificationPayload {
  title: string;
  body?: string;
  variant?: HfNotificationVariant;
  durationMs?: number;
}

const HIDDEN_RECENT_KEY = "ebook-tts-hidden-recent";
const HIDDEN_RESUMABLE_KEY = "ebook-tts-hidden-resumable";

export interface AppProps {
  client?: ConversionClient;
}

function StartupLogView({ lines }: { lines: string[] }): JSX.Element {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (ref.current) {
      ref.current.scrollTop = ref.current.scrollHeight;
    }
  }, [lines]);
  return (
    <div className="startup-log-panel__log" ref={ref}>
      {lines.map((l, i) => (
        <div key={i} className="startup-log-panel__line">
          {l}
        </div>
      ))}
    </div>
  );
}

export default function App(props?: AppProps): JSX.Element {
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
  const statsPollInterval = isHelpOpen ? 5000 : 0;
  const apiHealthLabel = useMemo(() => {
    const url = resolveApiUrl("/api/health");
    if (url.startsWith("http")) {
      return url;
    }
    if (typeof window === "undefined") {
      return url;
    }
    const prefix = url.startsWith("/") ? "" : "/";
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
    ],
  );
  const [formVersion, setFormVersion] = useState(0);
  const [activeTab, setActiveTab] = useState<
    "setup" | "progress" | "downloads"
  >("setup");
  const [userSelectedTab, setUserSelectedTab] = useState(false);
  const [showRawLog, setShowRawLog] = useState(false);
  const [viewingRecentJob, setViewingRecentJob] =
    useState<RecentJobEntry | null>(null);
  const [repeatConfig, setRepeatConfig] = useState<ConversionTemplate | null>(
    null,
  );
  const [batchHistory, setBatchHistory] = useState<RecentJobEntry[]>([]);
  const [queuePlanTotal, setQueuePlanTotal] = useState(0);
  const lastCompletedJobIdRef = useRef<string | null>(null);
  const manualDownloadOverrideRef = useRef(false);
  const lastPhaseRef = useRef<ConversionState["phase"]>(state.phase);
  const notifiedBatchJobsRef = useRef<Set<string>>(new Set());
  const [pendingUploads, setPendingUploads] = useState(0);
  const hfNotificationCounterRef = useRef(0);
  const [isHfSpace, setIsHfSpace] = useState(false);
  const [hfNotifications, setHfNotifications] = useState<HfNotificationEntry[]>(
    [],
  );
  const [isRestartingBackend, setIsRestartingBackend] = useState(false);
  const [restartDialog, setRestartDialog] = useState<
    "confirm" | "cache" | "finished" | null
  >(null);
  // Tauri-specific: tracks whether the Python sidecar failed to start.
  const [tauriEngineError, setTauriEngineError] = useState<string | null>(null);
  const [tauriStarting, setTauriStarting] = useState<boolean>(isTauri());
  const [tauriStartupLog, setTauriStartupLog] = useState<string[]>([]);
  const didRestartRef = useRef(false);
  const handleTauriStartupReadyRef = useRef<() => void>(() => {});
  const [startupLogsExpanded, setStartupLogsExpanded] =
    useState<boolean>(false);
  const restartOptionsRef = useRef({ keepCache: false, keepFinished: false });
  const [hiddenRecentIds, setHiddenRecentIds] = useState<Set<string>>(() => {
    if (typeof window === "undefined") {
      return new Set();
    }
    try {
      const stored = localStorage.getItem(HIDDEN_RECENT_KEY);
      if (!stored) return new Set();
      const parsed = JSON.parse(stored);
      if (Array.isArray(parsed)) {
        return new Set(parsed.filter((id) => typeof id === "string"));
      }
    } catch (_error) {}
    return new Set();
  });
  const [hiddenResumableIds, setHiddenResumableIds] = useState<Set<string>>(
    () => {
      if (typeof window === "undefined") {
        return new Set();
      }
      try {
        const stored = localStorage.getItem(HIDDEN_RESUMABLE_KEY);
        if (!stored) return new Set();
        const parsed = JSON.parse(stored);
        if (Array.isArray(parsed)) {
          return new Set(parsed.filter((id) => typeof id === "string"));
        }
      } catch (_error) {}
      return new Set();
    },
  );

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    localStorage.setItem(
      HIDDEN_RECENT_KEY,
      JSON.stringify(Array.from(hiddenRecentIds)),
    );
  }, [hiddenRecentIds]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    localStorage.setItem(
      HIDDEN_RESUMABLE_KEY,
      JSON.stringify(Array.from(hiddenResumableIds)),
    );
  }, [hiddenResumableIds]);

  // Listen for Tauri sidecar startup events (no-op in browser).
  useEffect(() => {
    if (!isTauri()) return;
    const cleanups: Array<() => void> = [];
    (async () => {
      cleanups.push(
        await listenTauri("tauri-server-restarting", () => {
          // Sidecar crashed and is being auto-restarted — show startup panel.
          setTauriStarting(true);
          setTauriEngineError(null);
        }),
      );
      cleanups.push(
        await listenTauri("tauri-startup-error", (payload) => {
          setTauriStarting(false);
          setTauriEngineError(
            typeof payload === "string"
              ? payload
              : "Failed to start conversion engine",
          );
        }),
      );
      cleanups.push(
        await listenTauri("tauri-startup-timeout", () => {
          setTauriStarting(false);
          setTauriEngineError(
            "Engine took too long to start. Check Server Logs or restart the app.",
          );
        }),
      );
      cleanups.push(
        await listenTauri("tauri-startup-ready", () => {
          handleTauriStartupReadyRef.current();
        }),
      );
      cleanups.push(
        await listenTauri("tauri-startup-loading", () => {
          setTauriStarting(true);
        }),
      );
      cleanups.push(
        await listenTauri("tauri-server-log", (line) => {
          if (typeof line === "string") {
            setTauriStartupLog((prev) => {
              const next = [...prev, line];
              return next.length > 200 ? next.slice(-200) : next;
            });
          }
        }),
      );
      // Fetch any logs that were buffered before this listener was registered.
      try {
        const buffered = await invoke<string[]>("get_server_logs");
        if (buffered.length > 0) {
          setTauriStartupLog((prev) => {
            const combined = [...prev, ...buffered];
            return combined.length > 200 ? combined.slice(-200) : combined;
          });
        }
      } catch {
        // Not critical — ignore
      }
    })();
    return () => cleanups.forEach((u) => u());
  }, []);

  // Poll buffered server logs every 2 s while startup is in progress.
  // Also check if the server is already up (handles race where tauri-startup-ready
  // fired before the listener was registered).
  useEffect(() => {
    if (!isTauri() || !tauriStarting) return;
    const id = setInterval(async () => {
      // Fetch buffered logs from Rust
      try {
        const lines = await invoke<string[]>("get_server_logs");
        if (lines.length > 0) {
          setTauriStartupLog(lines.length > 200 ? lines.slice(-200) : lines);
        }
      } catch (e) {
        setTauriStartupLog((prev) => [
          ...prev,
          `[startup] invoke error: ${String(e)}`,
        ]);
      }
      // If server is already responding, mark as ready (race-condition guard)
      try {
        const r = await fetch("http://127.0.0.1:47860/api/health", {
          signal: AbortSignal.timeout(800),
        });
        if (r.ok) {
          handleTauriStartupReadyRef.current();
        }
      } catch {
        // not up yet
      }
    }, 2000);
    return () => clearInterval(id);
  }, [tauriStarting]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }

    const handleError = (event: ErrorEvent) => {
      reportUiIssue("app", "Unhandled UI error", {
        severity: "error",
        details: event.message || "Unknown browser error",
      });
    };

    const handleRejection = (event: PromiseRejectionEvent) => {
      const reason =
        typeof event.reason === "string"
          ? event.reason
          : event.reason instanceof Error
            ? event.reason.message
            : "Unknown rejection";
      reportUiIssue("app", "Unhandled async UI error", {
        severity: "error",
        details: reason,
      });
    };

    window.addEventListener("error", handleError);
    window.addEventListener("unhandledrejection", handleRejection);
    return () => {
      window.removeEventListener("error", handleError);
      window.removeEventListener("unhandledrejection", handleRejection);
    };
  }, []);

  const formLocked =
    state.phase === "submitting" || state.phase === "cancelling";
  const showUploadingStatus = pendingUploads > 0 && state.phase === "idle";
  const statusLabelOverride = showUploadingStatus
    ? t.status.uploadingFiles
    : t.status.phases[state.phase];
  const hasDownloads =
    Array.isArray(state.downloads) && state.downloads.length > 0;
  const canViewProgress =
    showUploadingStatus ||
    state.phase !== "idle" ||
    state.log.length > 0 ||
    Boolean(state.summary) ||
    Boolean(state.error) ||
    Boolean(state.jobId);
  const canViewDownloads =
    hasDownloads ||
    state.phase === "success" ||
    Boolean(
      viewingRecentJob &&
      (viewingRecentJob.outputs?.length || viewingRecentJob.downloadUrl),
    );
  const clearRecentJobView = useCallback(() => {
    manualDownloadOverrideRef.current = true;
    setViewingRecentJob(null);
  }, []);

  const handleReset = useCallback(() => {
    reset();
    setFormVersion((value) => value + 1);
    setActiveTab("setup");
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
    (tabId: "setup" | "progress" | "downloads") => {
      const allowed =
        tabId === "setup"
          ? true
          : tabId === "progress"
            ? canViewProgress
            : canViewDownloads;
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
    setActiveTab("downloads");
    setUserSelectedTab(true);
  }, []);

  const handleSubmitIntent = useCallback(() => {
    setActiveTab("progress");
    setUserSelectedTab(false);
  }, []);

  const handleQueueJobsAdded = useCallback((count: number) => {
    if (count > 0) {
      setQueuePlanTotal((prev) => prev + count);
    }
  }, []);

  const handleFormSubmit = useCallback(
    async (values: ConversionFormValues, options?: SubmitBatchOptions) => {
      setActiveTab("progress");
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
        coquiChunkChars: values.coquiChunkChars,
        coquiMaxWorkers: values.coquiMaxWorkers,
        coquiSafeMode: values.coquiSafeMode,
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
      if (state.phase === "idle") {
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
    if (typeof window !== "undefined" && typeof window.confirm === "function") {
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
    if (typeof window !== "undefined" && typeof window.confirm === "function") {
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

  const displayedDownloads = useMemo(() => {
    if (viewingRecentJob) {
      if (
        Array.isArray(viewingRecentJob.outputs) &&
        viewingRecentJob.outputs.length > 0
      ) {
        return viewingRecentJob.outputs;
      }
      if (viewingRecentJob.downloadUrl) {
        const fallbackName =
          viewingRecentJob.fileName ||
          `${viewingRecentJob.bookTitle || "book"}.zip`;
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
      if (!code) return "";
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
    if (
      !viewingRecentJob ||
      !viewingRecentJob.outputs ||
      viewingRecentJob.outputs.length === 0
    ) {
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
    const register = (
      job: RecentJobEntry | null | undefined,
      source: "current" | "recent",
    ) => {
      if (!job) return;
      const hasOutputs = Array.isArray(job.outputs) && job.outputs.length > 0;
      const hasDownload =
        hasOutputs || Boolean(job.downloadUrl) || Boolean(job.hasOutputs);
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
    recentJobs.forEach((job) => register(job, "recent"));
    batchHistory.forEach((job) => register(job, "current"));

    return Array.from(dedup.values()).sort(
      (a, b) => (b.savedAtMs ?? 0) - (a.savedAtMs ?? 0),
    );
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
    const activeJobCount =
      state.phase === "polling" || state.phase === "submitting" ? 1 : 0;
    if (activeJobCount === 0) return undefined;
    return queuePlanTotal > 0
      ? queuePlanTotal - queueForDisplay.length
      : undefined;
  }, [queueForDisplay.length, queuePlanTotal, state.phase]);

  const queueTotal = useMemo(() => {
    const activeJobCount =
      state.phase === "polling" || state.phase === "submitting" ? 1 : 0;
    if (activeJobCount === 0) return undefined;
    return queuePlanTotal > 1 ? queuePlanTotal : undefined;
  }, [queuePlanTotal, state.phase]);

  const canCancelJob = Boolean(
    state.jobId && (state.phase === "polling" || state.phase === "cancelling"),
  );
  const canSkipJob = Boolean(
    state.jobId && state.phase === "polling" && queue.length > 0,
  );
  const cancelDisabled = state.phase === "cancelling";
  const activeEtaDisplay = formatEta(state.phase, state.etaSeconds, locale, t);
  const showActiveConversion =
    activeTab === "setup" && (state.phase !== "idle" || showUploadingStatus);
  const canShowQueueAdder = Boolean(repeatConfig && state.phase !== "idle");

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    const host = window.location.hostname.toLowerCase();
    const hfMatch =
      host.endsWith(".hf.space") || host.includes("huggingface.co");
    setIsHfSpace(hfMatch);
  }, []);

  const dismissHfNotification = useCallback((id: number) => {
    setHfNotifications((prev) => prev.filter((entry) => entry.id !== id));
  }, []);

  const pushHfNotification = useCallback(
    (payload: HfNotificationPayload) => {
      if (!isHfSpace) {
        return false;
      }
      hfNotificationCounterRef.current += 1;
      const id = hfNotificationCounterRef.current;
      const entry: HfNotificationEntry = {
        id,
        title: payload.title,
        body: payload.body,
        variant: payload.variant ?? "info",
      };
      setHfNotifications((prev) => [...prev, entry]);
      if (typeof window !== "undefined") {
        window.setTimeout(
          () => dismissHfNotification(id),
          payload.durationMs ?? 5000,
        );
      }
      return true;
    },
    [dismissHfNotification, isHfSpace],
  );

  const notifyUser = useCallback(
    (title: string, body: string, variant: HfNotificationVariant = "info") => {
      if (
        typeof window !== "undefined" &&
        "Notification" in window &&
        Notification.permission === "granted"
      ) {
        new Notification(title, { body });
        return;
      }
      if (isHfSpace) {
        pushHfNotification({ title, body, variant });
      }
    },
    [isHfSpace, pushHfNotification],
  );

  // Filter recent jobs to show only completed ones
  const completedRecentJobs = useMemo(() => {
    return recentJobs.filter(
      (job) =>
        job.state === "finished" &&
        job.hasOutputs &&
        !hiddenRecentIds.has(job.jobId),
    );
  }, [hiddenRecentIds, recentJobs]);

  useEffect(() => {
    const activeJobCount =
      state.phase === "polling" || state.phase === "submitting" ? 1 : 0;
    if (queuePlanTotal === 0 && queueForDisplay.length + activeJobCount > 0) {
      setQueuePlanTotal(queueForDisplay.length + activeJobCount);
    }
  }, [queueForDisplay.length, queuePlanTotal, state.phase]);

  const currentJobForQueue = useMemo(() => {
    if (state.phase !== "polling" && state.phase !== "submitting") {
      return undefined;
    }
    return {
      fileName: state.bookTitle,
      bookTitle: state.bookTitle,
    };
  }, [state.phase, state.bookTitle]);

  const visibleCachedJobs = useMemo(
    () => cachedJobs.filter((job) => !hiddenResumableIds.has(job.jobId)),
    [cachedJobs, hiddenResumableIds],
  );

  const renderQueueDisplay = useCallback(
    (style?: CSSProperties) => {
      if (!currentJobForQueue && queueForDisplay.length === 0) {
        return null;
      }
      const activeJobCount =
        state.phase === "polling" || state.phase === "submitting" ? 1 : 0;
      const currentProgressFraction = activeJobCount
        ? Math.min(1, Math.max(0, (state.summary?.progressPercent ?? 0) / 100))
        : 0;
      const pendingJobs = queueForDisplay.length;
      const totalJobs = queuePlanTotal || pendingJobs + activeJobCount;
      const completedJobs = Math.max(
        0,
        totalJobs - (pendingJobs + activeJobCount),
      );
      const overallPercent =
        totalJobs > 0
          ? ((completedJobs + currentProgressFraction) / totalJobs) * 100
          : null;

      return (
        <div style={{ margin: "1.5rem 0", ...style }}>
          <Suspense fallback={<ComponentFallback />}>
            <QueueDisplay
              currentJob={currentJobForQueue}
              queue={queueForDisplay}
              queuePaused={queuePaused}
              onResumeQueue={queuePaused ? resumeQueue : undefined}
              onClearQueue={
                queueForDisplay.length > 0
                  ? () => {
                      clearQueue();
                      setQueuePlanTotal(0);
                    }
                  : undefined
              }
              onReorderQueue={
                queueForDisplay.length > 1 ? reorderQueue : undefined
              }
              totalJobs={totalJobs}
              overallPercent={overallPercent}
            />
          </Suspense>
        </div>
      );
    },
    [
      clearQueue,
      currentJobForQueue,
      queueForDisplay,
      queuePaused,
      queuePlanTotal,
      reorderQueue,
      resumeQueue,
      setQueuePlanTotal,
      state.phase,
      state.summary?.progressPercent,
    ],
  );

  useEffect(() => {
    if (state.phase === "cancelled") {
      if (activeTab !== "setup") {
        setActiveTab("setup");
      }
      if (userSelectedTab) {
        setUserSelectedTab(false);
      }
      return;
    }
    if (userSelectedTab) {
      return;
    }
    if (
      state.phase === "success" ||
      (hasDownloads && state.phase !== "error")
    ) {
      if (activeTab !== "downloads") {
        setActiveTab("downloads");
      }
      return;
    }
    if (state.phase === "error") {
      if (activeTab !== "progress") {
        setActiveTab("progress");
      }
      return;
    }
    if (state.phase === "submitting" && activeTab !== "progress") {
      setActiveTab("progress");
      return;
    }
    if (state.phase === "polling" && activeTab !== "progress") {
      setActiveTab("progress");
    }
  }, [state.phase, hasDownloads, activeTab, userSelectedTab]);

  useEffect(() => {
    if (typeof window === "undefined" || !("Notification" in window)) {
      return;
    }
    if (Notification.permission === "default") {
      Notification.requestPermission().catch(() => {});
    }
  }, []);

  useEffect(() => {
    if (state.phase !== "success") {
      return;
    }
    if (
      !state.jobId ||
      !Array.isArray(state.downloads) ||
      state.downloads.length === 0
    ) {
      return;
    }
    if (lastCompletedJobIdRef.current === state.jobId) {
      return;
    }
    const resolvedTitle = state.bookTitle?.trim() || t.status.bookFallbackTitle;
    const mp3Count = state.downloads.filter((asset) =>
      asset.name.toLowerCase().endsWith(".mp3"),
    ).length;
    const chapterCount = mp3Count || state.summary?.chaptersCompleted || 0;
    const downloadUrl =
      state.downloads.find((asset) => asset.name.toLowerCase().endsWith(".zip"))
        ?.url ?? state.downloads[0]?.url;
    const completedAtIso = state.completedAt ?? new Date().toISOString();
    const entry: RecentJobEntry = {
      jobId: state.jobId,
      state: "finished",
      bookTitle: resolvedTitle,
      fileName: resolvedTitle,
      savedAt: completedAtIso,
      outputs: state.downloads,
      downloadUrl,
      chaptersCompleted: state.summary?.chaptersCompleted ?? chapterCount,
      chaptersTotal:
        state.summary?.chaptersTotal ?? (chapterCount || undefined),
      progressPercent: 100,
      engine: state.engine,
      voice: state.voice,
      language: state.language ?? state.summary?.detectedLanguage,
      formattingCues: state.speakFormattingCues,
      uiLanguage: state.uiLanguage,
      hasOutputs: true,
      canResume: false,
      startedAt: state.startedAt,
      completedAt: completedAtIso,
      totalDurationSeconds: state.totalDurationSeconds,
    };
    setBatchHistory((prev) => {
      const next = [entry, ...prev.filter((job) => job.jobId !== entry.jobId)];
      return next.slice(0, 5);
    });
    manualDownloadOverrideRef.current = false;
    lastCompletedJobIdRef.current = state.jobId;
    // OS notification — always in Tauri (app may be minimised or behind another window)
    if (isTauri()) {
      sendNotification(t.downloads.readyNotificationTitle, resolvedTitle);
    }
  }, [
    state.bookTitle,
    state.downloads,
    state.engine,
    state.language,
    state.phase,
    state.summary,
    state.jobId,
    state.speakFormattingCues,
    state.uiLanguage,
    state.voice,
    t.status.bookFallbackTitle,
  ]);

  useEffect(() => {
    if (!readyDownloadJobs.length) {
      return;
    }
    const currentJob = state.jobId
      ? readyDownloadJobs.find((job) => job.jobId === state.jobId)
      : undefined;
    if (state.phase === "success" && currentJob) {
      if (
        !viewingRecentJob ||
        viewingRecentJob.jobId !== currentJob.jobId ||
        manualDownloadOverrideRef.current
      ) {
        manualDownloadOverrideRef.current = false;
        setViewingRecentJob(currentJob);
      }
      return;
    }
    if (manualDownloadOverrideRef.current) {
      return;
    }
    const latest = readyDownloadJobs[0];
    if (!viewingRecentJob || viewingRecentJob.jobId !== latest.jobId) {
      setViewingRecentJob(latest);
    }
  }, [readyDownloadJobs, state.jobId, state.phase, viewingRecentJob]);

  useEffect(() => {
    if (state.phase === lastPhaseRef.current) {
      return;
    }
    if (state.phase === "error") {
      notifyUser(
        t.flow.notificationErrorTitle,
        state.error || t.flow.notificationErrorBody,
        "error",
      );
    }
    if (state.phase === "cancelled") {
      notifyUser(
        t.flow.notificationCancelTitle,
        t.flow.notificationCancelBody,
        "info",
      );
    }
    lastPhaseRef.current = state.phase;
  }, [
    notifyUser,
    state.error,
    state.phase,
    t.flow.notificationCancelBody,
    t.flow.notificationCancelTitle,
    t.flow.notificationErrorBody,
    t.flow.notificationErrorTitle,
  ]);

  useEffect(() => {
    if (!isHelpOpen) {
      return;
    }
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setIsHelpOpen(false);
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => {
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [isHelpOpen]);

  const handleRestartBackend = useCallback(() => {
    if (isRestartingBackend) {
      return;
    }
    restartOptionsRef.current = { keepCache: false, keepFinished: false };
    setRestartDialog("confirm");
  }, [isRestartingBackend]);

  const handleRestartDialogConfirm = useCallback(async () => {
    if (restartDialog === "confirm") {
      setRestartDialog("cache");
    } else if (restartDialog === "cache") {
      restartOptionsRef.current.keepCache = true;
      setRestartDialog("finished");
    } else if (restartDialog === "finished") {
      restartOptionsRef.current.keepFinished = true;
      setRestartDialog(null);
      try {
        setIsRestartingBackend(true);
        await restartBackend({
          keep_cache: restartOptionsRef.current.keepCache,
          keep_finished: restartOptionsRef.current.keepFinished,
        });
        notifyUser(
          t.layout.restartNotifyTitle,
          t.layout.restartNotifyBody,
          "info",
        );
      } catch (error) {
        console.error("[App] Failed to restart backend:", error);
        setIsRestartingBackend(false);
        notifyUser(
          t.layout.restartNotifyTitle,
          t.layout.restartErrorBody,
          "error",
        );
      }
    }
  }, [
    restartDialog,
    notifyUser,
    restartBackend,
    t.layout.restartNotifyTitle,
    t.layout.restartNotifyBody,
    t.layout.restartErrorBody,
  ]);

  const handleRestartDialogCancel = useCallback(async () => {
    if (restartDialog === "confirm") {
      setRestartDialog(null);
    } else if (restartDialog === "cache") {
      restartOptionsRef.current.keepCache = false;
      setRestartDialog("finished");
    } else if (restartDialog === "finished") {
      restartOptionsRef.current.keepFinished = false;
      setRestartDialog(null);
      try {
        setIsRestartingBackend(true);
        await restartBackend({
          keep_cache: restartOptionsRef.current.keepCache,
          keep_finished: restartOptionsRef.current.keepFinished,
        });
        notifyUser(
          t.layout.restartNotifyTitle,
          t.layout.restartNotifyBody,
          "info",
        );
      } catch (error) {
        console.error("[App] Failed to restart backend:", error);
        setIsRestartingBackend(false);
        notifyUser(
          t.layout.restartNotifyTitle,
          t.layout.restartErrorBody,
          "error",
        );
      }
    }
  }, [
    restartDialog,
    notifyUser,
    restartBackend,
    t.layout.restartNotifyTitle,
    t.layout.restartNotifyBody,
    t.layout.restartErrorBody,
  ]);

  const handleRestartDialogClose = useCallback(() => {
    setRestartDialog(null);
  }, []);

  useEffect(() => {
    batchHistory.forEach((job) => {
      if (!job.jobId || notifiedBatchJobsRef.current.has(job.jobId)) {
        return;
      }
      notifiedBatchJobsRef.current.add(job.jobId);
      const body = job.bookTitle
        ? t.downloads.readyNotificationBody(job.bookTitle)
        : t.downloads.readyNotificationBodyFallback;
      notifyUser(t.downloads.readyNotificationTitle, body, "success");
    });
  }, [
    batchHistory,
    notifyUser,
    t.downloads.readyNotificationBody,
    t.downloads.readyNotificationBodyFallback,
    t.downloads.readyNotificationTitle,
  ]);

  const tabs = useMemo(
    () => [
      {
        id: "setup" as const,
        label: t.tabs.setup.label,
        description: t.tabs.setup.description,
        content: (
          <Panel
            title={t.tabs.setup.panelTitle}
            description={t.tabs.setup.panelDescription}
            footer={
              activeTab === "setup" &&
              (state.phase !== "idle" || showUploadingStatus) && (
                <div
                  style={{
                    display: "flex",
                    justifyContent: "flex-end",
                    gap: "0.5rem",
                  }}
                >
                  <button
                    type="button"
                    className="button-secondary"
                    onClick={() => handleTabChange("progress")}
                  >
                    Ver Progresso →
                  </button>
                </div>
              )
            }
          >
            {renderQueueDisplay()}
            {showActiveConversion && (
              <Suspense fallback={<ComponentFallback />}>
                <ActiveConversionBanner
                  phase={state.phase}
                  statusLabel={statusLabelOverride}
                  jobLabel={
                    state.jobId ? t.status.jobLabel(state.jobId) : undefined
                  }
                  bookTitle={
                    state.bookTitle?.trim() || t.status.bookFallbackTitle
                  }
                  bookAuthor={state.bookAuthor?.trim()}
                  etaLabel={t.activeConversion.etaLabel}
                  etaValue={activeEtaDisplay}
                  currentLabel={t.activeConversion.currentLabel}
                  engineLabel={t.activeConversion.engineLabel}
                  voiceLabel={t.activeConversion.voiceLabel}
                  languageLabel={t.activeConversion.languageLabel}
                  engineValue={currentEngine}
                  voiceValue={currentVoice}
                  languageValue={currentLanguageLabel}
                  description={t.activeConversion.description}
                  queueHint={t.activeConversion.queueHint}
                  viewLabel={t.activeConversion.viewProgress}
                  cancelLabel={t.activeConversion.cancel}
                  skipLabel={t.activeConversion.skip}
                  onViewProgress={() => handleTabChange("progress")}
                  onCancel={handleCancelClick}
                  onSkip={handleSkipClick}
                  canCancel={canCancelJob}
                  canSkip={canSkipJob}
                  cancelDisabled={cancelDisabled}
                  summary={state.summary}
                />
                {canShowQueueAdder && repeatConfig && (
                  <QuickQueueAdder
                    template={repeatConfig}
                    enqueue={enqueue}
                    phase={state.phase}
                    uploadFile={uploadFile}
                    onJobsAdded={handleQueueJobsAdded}
                  />
                )}
              </Suspense>
            )}
            <Suspense fallback={<ComponentFallback />}>
              <ConversionForm
                key={formVersion}
                isSubmitting={formLocked}
                onSubmit={handleFormSubmit}
                onUploadFile={uploadFile}
                onUploadStateChange={setPendingUploads}
                onSubmitIntent={handleSubmitIntent}
                currentJob={{
                  jobId: state.jobId,
                  phase: state.phase,
                  bookTitle: state.bookTitle,
                  engine: currentEngine || undefined,
                  voice: currentVoice || undefined,
                  language: currentLanguageLabel || undefined,
                  formattingCues:
                    typeof state.speakFormattingCues === "boolean"
                      ? state.speakFormattingCues
                      : repeatConfig?.formattingCues,
                }}
              />
            </Suspense>
          </Panel>
        ),
      },
      {
        id: "progress" as const,
        label: t.tabs.progress.label,
        description: t.tabs.progress.description,
        content: (
          <Panel
            title={t.tabs.progress.panelTitle}
            description={t.tabs.progress.panelDescription}
            footer={
              activeTab === "progress" && (
                <div
                  style={{
                    display: "flex",
                    justifyContent: "space-between",
                    gap: "0.5rem",
                  }}
                >
                  <button
                    type="button"
                    className="button-secondary"
                    onClick={() => handleTabChange("setup")}
                  >
                    {t.tabs.progress.backButton}
                  </button>
                  {state.phase === "success" && (
                    <button
                      type="button"
                      className="button-secondary"
                      onClick={() => handleTabChange("downloads")}
                    >
                      {t.tabs.progress.viewDownloads}
                    </button>
                  )}
                </div>
              )
            }
          >
            {renderQueueDisplay()}
            <Suspense fallback={<ComponentFallback />}>
              <StatusPanel
                entries={state.log}
                rawLog={state.rawLog}
                phase={state.phase}
                phaseLabelOverride={statusLabelOverride}
                jobId={state.jobId}
                error={state.error}
                errorCategory={state.errorCategory}
                etaSeconds={state.etaSeconds}
                showRawLog={showRawLog}
                onToggleRawLog={() => setShowRawLog((value) => !value)}
                summary={state.summary}
                cliCommand={state.cliCommand}
                onCancel={state.jobId ? handleCancelClick : undefined}
                onSkip={state.jobId ? handleSkipClick : undefined}
                canCancel={canCancelJob}
                canSkip={canSkipJob}
                cancelDisabled={cancelDisabled}
                bookTitle={state.bookTitle}
                bookAuthor={state.bookAuthor}
                coverUrl={state.coverUrl}
              />
            </Suspense>
            {canShowQueueAdder && repeatConfig && (
              <Suspense fallback={<ComponentFallback />}>
                <QuickQueueAdder
                  template={repeatConfig}
                  enqueue={enqueue}
                  phase={state.phase}
                  uploadFile={uploadFile}
                  onJobsAdded={handleQueueJobsAdded}
                />
              </Suspense>
            )}
          </Panel>
        ),
      },
      {
        id: "downloads" as const,
        label: t.tabs.downloads.label,
        description: t.tabs.downloads.description,
        content: (
          <Panel
            title={t.tabs.downloads.panelTitle}
            description={t.tabs.downloads.panelDescription}
            footer={
              activeTab === "downloads" && (
                <div
                  style={{
                    display: "flex",
                    justifyContent: "space-between",
                    gap: "0.5rem",
                  }}
                >
                  <button
                    type="button"
                    className="button-secondary"
                    onClick={() => handleTabChange("progress")}
                  >
                    {t.tabs.downloads.backButton}
                  </button>
                  {(state.phase === "polling" ||
                    state.phase === "submitting") && (
                    <button
                      type="button"
                      className="button-primary"
                      onClick={() => {
                        setUserSelectedTab(false);
                        handleTabChange("progress");
                      }}
                    >
                      {t.tabs.downloads.followConversion}
                    </button>
                  )}
                </div>
              )
            }
          >
            {renderQueueDisplay()}
            {readyDownloadJobs.length > 0 && (
              <Suspense fallback={<ComponentFallback />}>
                <ReadyDownloadsList
                  jobs={readyDownloadJobs}
                  activeJobId={viewingRecentJob?.jobId}
                  onSelect={handleSelectReadyDownload}
                  onRemove={handleRemoveRecentJob}
                />
              </Suspense>
            )}
            <Suspense fallback={<ComponentFallback />}>
              <DownloadsPanel
                downloads={displayedDownloads}
                phase={state.phase}
                onReset={handleReset}
                isBusy={isBusy}
                cliCommand={state.cliCommand}
                log={state.log}
                rawLog={state.rawLog}
                showRawLog={showRawLog}
                context={downloadsContext}
                shareTitle={shareDownloadTitle}
              />
            </Suspense>
          </Panel>
        ),
      },
    ],
    [
      activeTab,
      displayedDownloads,
      downloadsContext,
      enqueue,
      formVersion,
      handleFormSubmit,
      handleRemoveRecentJob,
      handleReset,
      handleSelectReadyDownload,
      handleTabChange,
      isBusy,
      readyDownloadJobs,
      repeatConfig,
      shareDownloadTitle,
      showRawLog,
      state.bookAuthor,
      state.bookTitle,
      state.cliCommand,
      state.coverUrl,
      state.downloads,
      state.error,
      state.errorCategory,
      state.etaSeconds,
      state.jobId,
      state.log,
      state.phase,
      state.rawLog,
      state.summary,
      statusLabelOverride,
      setUserSelectedTab,
      t,
      viewingRecentJob,
    ],
  );

  const handleResumeJob = useCallback(
    (jobId: string) => {
      console.log("[App] Resuming job:", jobId);
      setActiveTab("progress");
      clearRecentJobView();
      resume(jobId);
    },
    [clearRecentJobView, resume],
  );

  const handleViewRecentJobOutputs = useCallback(
    (job: RecentJobEntry) => {
      manualDownloadOverrideRef.current = true;
      if (job.outputs && job.outputs.length > 0) {
        setViewingRecentJob(job);
      } else {
        clearRecentJobView();
      }
      setActiveTab("downloads");
      setUserSelectedTab(true);
    },
    [clearRecentJobView, setActiveTab, setUserSelectedTab, setViewingRecentJob],
  );

  const handleRemoveResumableJob = useCallback(
    (jobId: string) => {
      setHiddenResumableIds((prev) => {
        const next = new Set(prev);
        next.add(jobId);
        return next;
      });
      removeCachedJob(jobId);
    },
    [removeCachedJob],
  );

  const showSetupPanels = activeTab === "setup" && state.phase === "idle";
  // In Tauri mode the banner is replaced by a more specific engine error message.
  const showOfflineBanner =
    showSetupPanels && healthStatus === "fail" && !isTauri();

  return (
    <Layout>
      <Hero
        title={state.bookTitle}
        author={state.bookAuthor}
        coverUrl={state.coverUrl}
        summary={state.summary}
        etaSeconds={state.etaSeconds}
        phase={state.phase}
        engineLabel={currentEngine}
        voiceLabel={currentVoice}
        languageLabel={currentLanguageLabel}
        queuePosition={queuePosition}
        queueTotal={queueTotal}
      />
      <div className="help-toggle">
        <button
          type="button"
          onClick={() => setIsHelpOpen(true)}
          aria-expanded={isHelpOpen}
          aria-controls="help-drawer"
        >
          {t.layout.helpToggle}
        </button>
      </div>
      {showOfflineBanner && (
        <div className="api-offline-banner" role="alert">
          <strong>{t.flow.backendOffline}</strong>
          <span>{t.flow.backendOfflineBanner}</span>
          <span>API: {apiHealthLabel}</span>
        </div>
      )}
      {isTauri() && tauriStarting && showSetupPanels && (
        <div className="startup-log-panel" role="status">
          <div className="startup-log-panel__header">
            <span className="startup-log-panel__spinner" aria-hidden="true" />
            <strong>Starting conversion engine…</strong>
            <span className="startup-log-panel__hint">
              {tauriStartupLog.length === 0
                ? "First launch may download ffmpeg (~60 MB)"
                : tauriStartupLog[tauriStartupLog.length - 1]}
            </span>
            <button
              type="button"
              className="startup-log-panel__toggle"
              onClick={() => setStartupLogsExpanded((v) => !v)}
              aria-expanded={startupLogsExpanded}
            >
              {startupLogsExpanded ? "Hide logs ▲" : "Show logs ▼"}
            </button>
          </div>
          {startupLogsExpanded && (
            <StartupLogView
              lines={
                tauriStartupLog.length > 0
                  ? tauriStartupLog
                  : ["Waiting for conversion engine to start…"]
              }
            />
          )}
        </div>
      )}
      {isTauri() && !tauriStarting && tauriEngineError && showSetupPanels && (
        <div className="api-offline-banner" role="alert">
          <strong>Conversion engine error</strong>
          <span>{tauriEngineError}</span>
          <span>
            Rebuild the sidecar:{" "}
            <code>
              mise run desktop:sidecar &amp;&amp; mise run desktop:build
            </code>
          </span>
        </div>
      )}
      {showSetupPanels &&
        savedBatch &&
        savedBatch.length > 0 &&
        (() => {
          const resumableCount = savedBatch.filter(
            (item: ConversionFormValues) =>
              item.file instanceof File || Boolean(item.uploadId),
          ).length;
          const needsReuploadCount = savedBatch.length - resumableCount;
          return (
            <div
              style={{
                display: "flex",
                flexDirection: "column",
                gap: "0.4rem",
                padding: "0.75rem 1rem",
                marginBottom: "1rem",
                background: "var(--color-surface-raised, #f0f4ff)",
                border: "1px solid var(--color-border, #c8d4f0)",
                borderRadius: "8px",
              }}
            >
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "space-between",
                  gap: "0.75rem",
                }}
              >
                <span style={{ fontSize: "0.9rem" }}>
                  {t.tabs.setup.savedBatchTitle(savedBatch.length)}
                </span>
                <div style={{ display: "flex", gap: "0.5rem" }}>
                  {resumableCount > 0 && (
                    <button
                      type="button"
                      className="button-primary"
                      onClick={() => resumeBatch(savedBatch)}
                    >
                      {t.tabs.setup.savedBatchResume}
                    </button>
                  )}
                  <button
                    type="button"
                    className="button-secondary"
                    onClick={dismissSavedBatch}
                  >
                    {t.tabs.setup.savedBatchDismiss}
                  </button>
                </div>
              </div>
              {needsReuploadCount > 0 && (
                <span
                  style={{
                    fontSize: "0.8rem",
                    color: "var(--color-warning, #b45309)",
                  }}
                >
                  {t.tabs.setup.savedBatchNeedsReupload(needsReuploadCount)}
                </span>
              )}
            </div>
          );
        })()}
      {showSetupPanels &&
        (cachedJobsLoading || visibleCachedJobs.length > 0) && (
          <Suspense fallback={<ComponentFallback />}>
            <ResumableJobsPanel
              jobs={visibleCachedJobs}
              onResume={handleResumeJob}
              onRemove={handleRemoveResumableJob}
              queueDisplay={renderQueueDisplay({ margin: "0.75rem 0 0" })}
              loading={cachedJobsLoading}
            />
          </Suspense>
        )}
      {showSetupPanels && completedRecentJobs.length > 0 && (
        <>
          <Suspense fallback={<ComponentFallback />}>
            <RecentJobsPanel
              jobs={completedRecentJobs}
              onViewOutputs={handleViewRecentJobOutputs}
              onRemoveJob={handleRemoveRecentJob}
            />
          </Suspense>
          {renderQueueDisplay({ marginTop: "1rem" })}
        </>
      )}
      {showSetupPanels && (
        <Suspense fallback={null}>
          <ConversionHistoryPanel />
        </Suspense>
      )}
      <section className="tabs">
        <div className="tabs__list" role="tablist" aria-label="Conversion flow">
          {tabs.map((tab) => {
            const buttonId = `tab-${tab.id}`;
            const panelId = `panel-${tab.id}`;
            const isActive = activeTab === tab.id;
            const isDisabled =
              tab.id === "setup"
                ? false
                : tab.id === "progress"
                  ? !canViewProgress
                  : !canViewDownloads;
            return (
              <button
                key={tab.id}
                id={buttonId}
                type="button"
                role="tab"
                className={`tabs__trigger${isActive ? " tabs__trigger--active" : ""}${isDisabled ? " tabs__trigger--disabled" : ""}`}
                aria-selected={isActive}
                aria-controls={panelId}
                onClick={() => handleTabChange(tab.id)}
                disabled={isDisabled}
                aria-disabled={isDisabled}
              >
                <div className="tabs__header">
                  <span className="tabs__label">{tab.label}</span>
                  {tab.id === "progress" &&
                    (state.phase === "polling" ||
                      state.phase === "submitting") &&
                    t.tabs.progress.activeBadge && (
                      <span className="tabs__badge">
                        {t.tabs.progress.activeBadge}
                      </span>
                    )}
                </div>
                <span className="tabs__description">{tab.description}</span>
              </button>
            );
          })}
        </div>
        <div className="tabs__panels">
          {tabs.map((tab) => {
            const panelId = `panel-${tab.id}`;
            const buttonId = `tab-${tab.id}`;
            const isHidden = activeTab !== tab.id;
            return (
              <div
                key={tab.id}
                role="tabpanel"
                id={panelId}
                aria-labelledby={buttonId}
                hidden={isHidden}
                className="tabs__panel"
              >
                {tab.content}
              </div>
            );
          })}
        </div>
      </section>
      {isHelpOpen && (
        <div
          className="help-drawer__overlay"
          role="button"
          tabIndex={0}
          aria-label={t.layout.helpClose}
          onClick={() => setIsHelpOpen(false)}
          onKeyDown={(event) => {
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault();
              setIsHelpOpen(false);
            }
          }}
        />
      )}
      <aside
        id="help-drawer"
        className={`help-drawer${isHelpOpen ? " help-drawer--open" : ""}`}
        aria-hidden={!isHelpOpen}
      >
        <div className="help-drawer__header">
          <strong>{t.layout.helpTitle}</strong>
          <button
            type="button"
            className="help-drawer__close"
            onClick={() => setIsHelpOpen(false)}
            aria-label={t.layout.helpClose}
          >
            ×
          </button>
        </div>
        <Suspense fallback={<ComponentFallback />}>
          <SystemStatsPanel
            stats={systemStats}
            labels={systemStatsLabels}
            hasError={systemStatsError}
            isLoading={systemStatsLoading}
            updatedAt={systemStatsUpdatedAt}
            nextRetryMs={systemStatsNextRetry}
          />
        </Suspense>
        <Suspense fallback={<ComponentFallback />}>
          <TelemetryPanel locale={locale === "pt" ? "pt" : "en"} />
        </Suspense>
        <div className="system-control">
          <div className="system-control__text">
            <strong>{t.layout.restartTitle}</strong>
            <p>{t.layout.restartDescription}</p>
          </div>
          <button
            type="button"
            className="button-danger"
            onClick={handleRestartBackend}
            disabled={isRestartingBackend}
          >
            {isRestartingBackend
              ? t.layout.restartProgress
              : t.layout.restartButton}
          </button>
        </div>
      </aside>
      {isHfSpace && hfNotifications.length > 0 && (
        <div
          className="hf-notifications"
          role="region"
          aria-live="polite"
          aria-atomic="false"
        >
          {hfNotifications.map((notification) => (
            <div
              key={notification.id}
              className={`hf-notification hf-notification--${notification.variant}`}
              role="status"
            >
              <button
                type="button"
                className="hf-notification__close"
                onClick={() => dismissHfNotification(notification.id)}
                aria-label={t.layout.closeNotification}
              >
                ×
              </button>
              <div className="hf-notification__title">{notification.title}</div>
              {notification.body && (
                <div className="hf-notification__body">{notification.body}</div>
              )}
            </div>
          ))}
        </div>
      )}

      {/* Restart backend dialogs */}
      <Suspense fallback={null}>
        <ConfirmDialog
          open={restartDialog === "confirm"}
          title={t.layout.restartTitle}
          message={t.layout.restartConfirm}
          confirmLabel={t.layout.restartConfirmYes}
          cancelLabel={t.layout.restartConfirmNo}
          onConfirm={handleRestartDialogConfirm}
          onCancel={handleRestartDialogCancel}
          variant="danger"
        />
        <ConfirmDialog
          open={restartDialog === "cache"}
          title={t.layout.restartKeepCacheTitle}
          message={t.layout.restartKeepCacheConfirm}
          confirmLabel={t.layout.restartKeepCacheYes}
          cancelLabel={t.layout.restartKeepCacheNo}
          onConfirm={handleRestartDialogConfirm}
          onCancel={handleRestartDialogCancel}
          onClose={handleRestartDialogClose}
          showCloseButton
        />
        <ConfirmDialog
          open={restartDialog === "finished"}
          title={t.layout.restartKeepFinishedTitle}
          message={t.layout.restartKeepFinishedConfirm}
          confirmLabel={t.layout.restartKeepFinishedYes}
          cancelLabel={t.layout.restartKeepFinishedNo}
          onConfirm={handleRestartDialogConfirm}
          onCancel={handleRestartDialogCancel}
          onClose={handleRestartDialogClose}
          showCloseButton
        />
      </Suspense>
    </Layout>
  );
}
