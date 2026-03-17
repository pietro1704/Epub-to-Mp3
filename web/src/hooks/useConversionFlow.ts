import {
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from "react";
import {
  conversionClient,
  ConversionClient,
  RestartOptions,
  UploadResponse,
} from "../services/ConversionService";
import { conversionCache } from "../services/ConversionCache";
import {
  ConversionFormValues,
  ConversionState,
  DownloadAsset,
  StatusEntry,
  JobSnapshot,
  ConversionSummary,
  RecentJobEntry,
  SubmitBatchOptions,
} from "../types/conversion";
import { useTranslations } from "../i18n/I18nProvider";
import { resolveApiUrl } from "../config";
import { useSystemStats } from "./useSystemStats";
import type { SystemStats } from "./useSystemStats";

const resolveHealthEndpoint = (): string => resolveApiUrl("/api/health");
const RESTART_GRACE_MS = 15000;
const INITIAL_FETCH_RETRY_ATTEMPTS = 5;
const INITIAL_FETCH_RETRY_BASE_DELAY_MS = 500;
const INITIAL_FETCH_RETRY_MAX_DELAY_MS = 4000;
const sleepMs = (ms: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
type AdaptiveTolerances = {
  healthPingTimeoutMs: number;
  healthCheckFirstTimeoutMs: number;
  healthCheckTimeoutMs: number;
  healthFailureLimit: number;
  pollFailureLimit: number;
  activeSnapshotGraceMs: number;
};

const DEFAULT_TOLERANCES: AdaptiveTolerances = {
  healthPingTimeoutMs: 8000,
  healthCheckFirstTimeoutMs: 8000,
  healthCheckTimeoutMs: 5000,
  healthFailureLimit: 3,
  pollFailureLimit: 3,
  activeSnapshotGraceMs: 60000,
};

const clampNumber = (value: number, min: number, max: number): number => {
  return Math.min(max, Math.max(min, value));
};

const resolveRecentSpeed = (summary?: ConversionSummary): number | null => {
  const entries = summary?.chapterProgress;
  if (!entries || entries.length === 0) {
    return null;
  }
  for (let idx = entries.length - 1; idx >= 0; idx -= 1) {
    const speed = entries[idx]?.charsPerSecond;
    if (typeof speed === "number" && speed > 0) {
      return speed;
    }
  }
  return null;
};

const resolveTelemetrySpeed = (
  stats: SystemStats | null,
  engine?: string,
): number | null => {
  const telemetry = stats?.telemetry;
  if (!telemetry) {
    return null;
  }
  const engineKey = (engine || "").toLowerCase();
  const engineEntry = engineKey ? telemetry[engineKey] : undefined;
  const engineSpeed = engineEntry?.avg_chars_per_second;
  if (typeof engineSpeed === "number" && engineSpeed > 0) {
    return engineSpeed;
  }
  let best = 0;
  Object.values(telemetry).forEach((entry) => {
    const speed = entry?.avg_chars_per_second;
    if (typeof speed === "number" && speed > best) {
      best = speed;
    }
  });
  return best > 0 ? best : null;
};

const deriveAdaptiveTolerances = (
  stats: SystemStats | null,
  recentSpeed: number | null,
  engine?: string,
): AdaptiveTolerances => {
  if (!stats) {
    return DEFAULT_TOLERANCES;
  }
  const cpuPercent = Number(stats.cpu?.percent ?? 0);
  const memPercent = Number(stats.memory?.percent ?? 0);
  const logical = Number(stats.cpu?.logical ?? stats.cpu?.physical ?? 1);
  const totalMemBytes = Number(stats.memory?.total ?? 0);
  const totalMemGb = totalMemBytes > 0 ? totalMemBytes / 1024 ** 3 : 0;
  const gpuCount = stats.gpus?.length ?? 0;
  const inFlight = Number(stats.jobs?.inFlight ?? 0);
  const recSlots = Number(stats.recommendations?.parallelSlots ?? 0);

  const telemetrySpeed = resolveTelemetrySpeed(stats, engine);
  const speed =
    typeof recentSpeed === "number" && recentSpeed > 0
      ? recentSpeed
      : telemetrySpeed;

  let multiplier = 1.0;

  if (totalMemGb > 0 && totalMemGb < 6) {
    multiplier += 0.2;
  }
  if (totalMemGb > 0 && totalMemGb < 4) {
    multiplier += 0.2;
  }
  if (logical <= 4) {
    multiplier += 0.2;
  }
  if (logical <= 2) {
    multiplier += 0.2;
  }
  if (cpuPercent >= 85 || memPercent >= 85) {
    multiplier += 0.25;
  } else if (cpuPercent >= 70 || memPercent >= 70) {
    multiplier += 0.15;
  }
  if (inFlight > 1 || recSlots >= 6) {
    multiplier += 0.15;
  }
  if (typeof speed === "number") {
    if (speed < 60) {
      multiplier += 0.35;
    } else if (speed < 100) {
      multiplier += 0.2;
    } else if (speed > 200) {
      multiplier -= 0.1;
    }
  }
  if (gpuCount > 0 && logical >= 8 && totalMemGb >= 12) {
    multiplier -= 0.05;
  }

  multiplier = clampNumber(multiplier, 0.85, 2.8);

  const scale = (base: number, min: number, max: number): number => {
    return clampNumber(Math.round(base * multiplier), min, max);
  };

  return {
    healthPingTimeoutMs: scale(
      DEFAULT_TOLERANCES.healthPingTimeoutMs,
      6000,
      20000,
    ),
    healthCheckFirstTimeoutMs: scale(
      DEFAULT_TOLERANCES.healthCheckFirstTimeoutMs,
      6000,
      20000,
    ),
    healthCheckTimeoutMs: scale(
      DEFAULT_TOLERANCES.healthCheckTimeoutMs,
      4000,
      15000,
    ),
    healthFailureLimit: clampNumber(
      Math.round(DEFAULT_TOLERANCES.healthFailureLimit * multiplier),
      2,
      6,
    ),
    pollFailureLimit: clampNumber(
      Math.round(DEFAULT_TOLERANCES.pollFailureLimit * multiplier),
      2,
      6,
    ),
    activeSnapshotGraceMs: scale(
      DEFAULT_TOLERANCES.activeSnapshotGraceMs,
      45000,
      180000,
    ),
  };
};

const pingBackendHealth = async (
  timeoutMs: number = DEFAULT_TOLERANCES.healthPingTimeoutMs,
): Promise<boolean> => {
  const endpoint = resolveHealthEndpoint();
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    const response = await fetch(endpoint, {
      method: "GET",
      cache: "no-store",
      signal: controller.signal,
    });
    clearTimeout(timeout);
    return response.ok;
  } catch {
    return false;
  }
};

const isNetworkError = (error: unknown): boolean => {
  if (!(error instanceof Error)) {
    return false;
  }
  const status = (error as Error & { status?: number }).status;
  if (typeof status === "number") {
    return status === 429 || status >= 500;
  }
  const message = error.message.toLowerCase();
  return (
    message.includes("429") ||
    message.includes("rate limit") ||
    message.includes("too many requests") ||
    message.includes("failed to fetch") ||
    message.includes("network") ||
    message.includes("timeout")
  );
};

function buildCliCommand(values: ConversionFormValues): string {
  const parts = ["python python_app/convert"];
  const displayFileName = values.file?.name || values.fileName;
  if (displayFileName) {
    parts.push(displayFileName);
  }

  if (values.engine) {
    parts.push("--engine", values.engine);
  }

  if (values.voice) {
    parts.push("--voice", values.voice);
  }
  if (values.model) {
    parts.push("--model", values.model);
  }

  if (values.chapters) {
    parts.push("--chapter", values.chapters);
  }
  if (values.sections) {
    parts.push("--section", values.sections);
  }
  if (values.priority) {
    parts.push("--priority", values.priority);
  }

  if (typeof values.verbose === "boolean") {
    parts.push(values.verbose ? "--verbose" : "--no-verbose");
  }

  if (typeof values.formattingCues === "boolean") {
    parts.push(
      values.formattingCues ? "--formatting-cues" : "--no-formatting-cues",
    );
  }

  if (values.noParallel) {
    parts.push("--no-parallel");
  }

  if (values.filterChapters) {
    parts.push("--filter-chapters");
  }

  if (values.clearCache) {
    parts.push("--clear-cache");
  }

  if (values.footnoteMode && values.footnoteMode !== "inline") {
    if (values.footnoteMode === "skip") {
      parts.push("--no-footnote");
    } else if (values.footnoteMode === "chapter_end") {
      parts.push("--footnote-chapter-end");
    }
  }

  if (values.language) {
    parts.push("--language", values.language);
  }

  return parts.join(" ");
}

type Action =
  | { type: "reset" }
  | {
      type: "start";
      entry: StatusEntry;
      cliCommand: string;
      startedAt?: string;
    }
  | { type: "job-created"; entry: StatusEntry; jobId: string }
  | { type: "append-entry"; entry: StatusEntry }
  | {
      type: "complete";
      entry: StatusEntry;
      downloads: DownloadAsset[];
      completedAt?: string;
      totalDurationSeconds?: number;
    }
  | { type: "fail"; entry: StatusEntry; error: string; errorCategory?: string }
  | { type: "cancelling"; entry: StatusEntry }
  | {
      type: "cancelled";
      entry: StatusEntry;
      error: string;
      errorCategory?: string;
    }
  | {
      type: "update-meta";
      etaSeconds?: number | null;
      summary?: ConversionSummary;
      details?: Partial<
        Pick<
          ConversionState,
          | "bookTitle"
          | "bookAuthor"
          | "coverUrl"
          | "engine"
          | "voice"
          | "language"
          | "uiLanguage"
          | "speakFormattingCues"
        >
      >;
      rawLog?: string[];
      timestamps?: Partial<
        Pick<
          ConversionState,
          "startedAt" | "completedAt" | "totalDurationSeconds"
        >
      >;
    };

const initialState: ConversionState = {
  phase: "idle",
  log: [],
  downloads: [],
  error: undefined,
  jobId: undefined,
  etaSeconds: undefined,
  summary: undefined,
  cliCommand: undefined,
  bookTitle: undefined,
  bookAuthor: undefined,
  coverUrl: undefined,
  rawLog: [],
  engine: undefined,
  voice: undefined,
  language: undefined,
  uiLanguage: undefined,
  speakFormattingCues: undefined,
  startedAt: undefined,
  completedAt: undefined,
  totalDurationSeconds: undefined,
};

function reducer(state: ConversionState, action: Action): ConversionState {
  switch (action.type) {
    case "reset":
      return { ...initialState };
    case "start":
      return {
        ...initialState,
        phase: "submitting",
        log: [action.entry],
        cliCommand: action.cliCommand,
        startedAt: action.startedAt ?? new Date().toISOString(),
        completedAt: undefined,
        totalDurationSeconds: undefined,
        // Clear metadata from previous uploads to avoid showing wrong book cover
        bookTitle: undefined,
        bookAuthor: undefined,
        coverUrl: undefined,
      };
    case "job-created":
      return {
        ...state,
        phase: "polling",
        jobId: action.jobId,
        log: [...state.log, action.entry],
        // Clear summary from previous job to prevent mixing data
        summary: undefined,
      };
    case "append-entry":
      return {
        ...state,
        log: [...state.log, action.entry],
      };
    case "complete":
      return {
        ...state,
        phase: "success",
        downloads: action.downloads,
        log: [...state.log, action.entry],
        error: undefined,
        etaSeconds: 0,
        completedAt: action.completedAt ?? new Date().toISOString(),
        totalDurationSeconds:
          action.totalDurationSeconds ?? state.totalDurationSeconds,
        summary: state.summary
          ? {
              ...state.summary,
              progressPercent: state.summary.progressPercent ?? 100,
            }
          : state.summary,
      };
    case "fail":
      return {
        ...state,
        phase: "error",
        error: action.error,
        errorCategory: action.errorCategory,
        log: [...state.log, action.entry],
        etaSeconds: 0,
        summary: state.summary,
      };
    case "cancelling":
      return {
        ...state,
        phase: "cancelling",
        log: [...state.log, action.entry],
      };
    case "cancelled":
      return {
        ...initialState,
        phase: "idle",
        error: action.error,
        errorCategory: action.errorCategory,
        log: [...state.log, action.entry],
      };
    case "update-meta": {
      let nextSummary = state.summary;
      if (action.summary) {
        nextSummary = { ...nextSummary } as ConversionSummary;
        for (const [key, value] of Object.entries(action.summary) as [
          keyof ConversionSummary,
          unknown,
        ][]) {
          if (value !== undefined && value !== null) {
            if (!nextSummary) {
              nextSummary = {} as ConversionSummary;
            }
            (nextSummary as ConversionSummary)[key] = value as never;
          }
        }
      }
      const updatedState: ConversionState = {
        ...state,
        etaSeconds:
          typeof action.etaSeconds === "number"
            ? Math.max(0, action.etaSeconds)
            : action.etaSeconds,
        summary: nextSummary,
      };
      if (action.details) {
        if (action.details.bookTitle !== undefined)
          updatedState.bookTitle = action.details.bookTitle;
        if (action.details.bookAuthor !== undefined)
          updatedState.bookAuthor = action.details.bookAuthor;
        if (action.details.coverUrl !== undefined)
          updatedState.coverUrl = action.details.coverUrl;
        if (action.details.engine !== undefined)
          updatedState.engine = action.details.engine;
        if (action.details.voice !== undefined)
          updatedState.voice = action.details.voice;
        if (action.details.language !== undefined)
          updatedState.language = action.details.language;
        if (action.details.uiLanguage !== undefined)
          updatedState.uiLanguage = action.details.uiLanguage;
        if (action.details.speakFormattingCues !== undefined) {
          updatedState.speakFormattingCues = action.details.speakFormattingCues;
        }
      }
      if (Array.isArray(action.rawLog)) {
        updatedState.rawLog = action.rawLog;
      }
      if (action.timestamps) {
        if (action.timestamps.startedAt !== undefined)
          updatedState.startedAt =
            action.timestamps.startedAt ?? updatedState.startedAt;
        if (action.timestamps.completedAt !== undefined)
          updatedState.completedAt =
            action.timestamps.completedAt ?? updatedState.completedAt;
        if (action.timestamps.totalDurationSeconds !== undefined) {
          updatedState.totalDurationSeconds =
            typeof action.timestamps.totalDurationSeconds === "number"
              ? Math.max(0, Math.round(action.timestamps.totalDurationSeconds))
              : undefined;
        }
      }
      return updatedState;
    }
    default:
      return state;
  }
}

function createStatusEntryFactory() {
  let sequence = 0;
  return (message: string): StatusEntry => {
    sequence += 1;
    return {
      id: `status-${sequence}`,
      message,
      timestamp: new Date().toISOString(),
    };
  };
}

function estimateEtaSeconds(
  snapshot: JobSnapshot,
  startedAt: number | null,
): number | undefined {
  if (typeof snapshot.etaSeconds === "number") {
    return snapshot.etaSeconds;
  }
  let progress =
    typeof snapshot.progress === "number" ? snapshot.progress : null;
  if (
    (progress === null || progress === undefined) &&
    typeof snapshot.progressPercent === "number"
  ) {
    progress = snapshot.progressPercent / 100;
  }
  if (!startedAt || progress === null || progress <= 0 || progress >= 1) {
    return undefined;
  }
  const elapsedSeconds = (Date.now() - startedAt) / 1000;
  if (elapsedSeconds <= 0) {
    return undefined;
  }
  return elapsedSeconds * ((1 - progress) / progress);
}

export interface UseConversionFlowApi {
  state: ConversionState;
  submit: (
    values: ConversionFormValues,
    options?: SubmitBatchOptions,
  ) => Promise<void>;
  enqueue: (jobs: ConversionFormValues[]) => Promise<void>;
  resume: (jobId: string) => Promise<void>;
  reset: () => void;
  cancel: () => Promise<boolean>;
  skipCurrent: () => Promise<boolean>;
  cancelJobById: (jobId: string) => Promise<void>;
  removeCachedJob: (jobId: string) => void;
  isBusy: boolean;
  cachedJobs: Array<{
    jobId: string;
    fileName: string;
    timestamp: number;
    engine?: string;
    voice?: string;
    language?: string;
    pendingQueueCount?: number;
  }>;
  cachedJobsLoading: boolean;
  uploadFile: (file: File) => Promise<UploadResponse>;
  recentJobs: RecentJobEntry[];
  apiAvailable: boolean;
  healthStatus: "unknown" | "ok" | "fail" | "restarting";
  queue: ConversionFormValues[];
  queuePaused: boolean;
  resumeQueue: () => void;
  clearQueue: () => void;
  reorderQueue: (fromIndex: number, toIndex: number) => void;
  restartBackend: (options?: RestartOptions) => Promise<void>;
}

export function useConversionFlow(
  client?: ConversionClient,
): UseConversionFlowApi {
  const [state, dispatch] = useReducer(reducer, initialState);
  const api = useMemo(() => client ?? conversionClient, [client]);
  const abortRef = useRef<AbortController | null>(null);
  const seenEventsRef = useRef<Set<string>>(new Set());
  const entryFactoryRef = useRef(createStatusEntryFactory());
  const startTimeRef = useRef<number | null>(null);
  const fileNameRef = useRef<string>("");
  const jobQueueRef = useRef<ConversionFormValues[]>([]);
  const queueActiveRef = useRef(false);
  const processedCountRef = useRef(0);
  const skipModeRef = useRef(false);
  const t = useTranslations();
  const [cachedJobs, setCachedJobs] = useState<
    Array<{
      jobId: string;
      fileName: string;
      timestamp: number;
      engine?: string;
      voice?: string;
      language?: string;
      pendingQueueCount?: number;
    }>
  >([]);
  const [cachedJobsLoading, setCachedJobsLoading] = useState(true);
  const [recentJobs, setRecentJobs] = useState<RecentJobEntry[]>([]);
  const [apiAvailable, setApiAvailable] = useState(true);
  const [healthStatus, setHealthStatus] = useState<
    "unknown" | "ok" | "fail" | "restarting"
  >("unknown");
  const systemStats = useSystemStats(client ? 0 : 5000);
  const recentSpeed = useMemo(
    () => resolveRecentSpeed(state.summary),
    [state.summary?.chapterProgress],
  );
  const adaptiveTolerances = useMemo(
    () => deriveAdaptiveTolerances(systemStats.data, recentSpeed, state.engine),
    [systemStats.data, recentSpeed, state.engine],
  );
  const [queuePaused, setQueuePausedState] = useState(false);
  const queuePausedRef = useRef(queuePaused);
  const setQueuePaused = useCallback((value: boolean) => {
    queuePausedRef.current = value;
    setQueuePausedState(value);
  }, []);
  const adaptiveTolerancesRef = useRef<AdaptiveTolerances>(DEFAULT_TOLERANCES);
  const restartGraceRef = useRef<number | null>(null);
  const lastSnapshotAtRef = useRef<number | null>(null);
  const healthFailureCountRef = useRef(0);
  const pollFailureCountRef = useRef(0);
  const isRestartGraceActive = useCallback(() => {
    const until = restartGraceRef.current;
    return typeof until === "number" && Date.now() < until;
  }, []);
  const beginRestartGrace = useCallback(() => {
    restartGraceRef.current = Date.now() + RESTART_GRACE_MS;
    setApiAvailable(false);
    setHealthStatus("restarting");
  }, []);
  const [queueSnapshot, setQueueSnapshot] = useState<ConversionFormValues[]>(
    [],
  );
  const syncQueueSnapshot = useCallback(() => {
    setQueueSnapshot([...jobQueueRef.current]);
  }, []);
  const getQueueSnapshotForCache = () => {
    if (jobQueueRef.current.length === 0) {
      return undefined;
    }
    return jobQueueRef.current.map((entry) => {
      const { file: _file, ...rest } = entry;
      return {
        ...rest,
        file: null,
      };
    });
  };

  useEffect(() => {
    adaptiveTolerancesRef.current = adaptiveTolerances;
    healthFailureCountRef.current = Math.min(
      healthFailureCountRef.current,
      adaptiveTolerances.healthFailureLimit,
    );
    pollFailureCountRef.current = Math.min(
      pollFailureCountRef.current,
      adaptiveTolerances.pollFailureLimit,
    );
  }, [adaptiveTolerances]);

  const saveStateWithQueue = (
    jobId: string,
    fileName: string,
    baseState: ConversionState,
  ) => {
    if (!jobId) {
      return;
    }
    const pendingBatchQueue = getQueueSnapshotForCache();
    const cacheState: ConversionState = pendingBatchQueue
      ? { ...baseState, pendingBatchQueue }
      : { ...baseState, pendingBatchQueue: undefined };
    conversionCache.save(jobId, fileName, cacheState);
  };

  const markApiOnline = useCallback(() => {
    restartGraceRef.current = null;
    healthFailureCountRef.current = 0;
    pollFailureCountRef.current = 0;
    setApiAvailable(true);
    setHealthStatus("ok");
  }, []);
  const markApiOffline = useCallback(() => {
    setApiAvailable(false);
    if (isRestartGraceActive()) {
      setHealthStatus("restarting");
      return;
    }
    setHealthStatus("fail");
  }, [isRestartGraceActive]);
  const shouldMarkOffline = useCallback(() => {
    const graceMs = adaptiveTolerancesRef.current.activeSnapshotGraceMs;
    if (state.phase === "polling" || state.phase === "submitting") {
      const lastSnapshotAt = lastSnapshotAtRef.current;
      if (lastSnapshotAt && Date.now() - lastSnapshotAt < graceMs) {
        return false;
      }
    }
    return true;
  }, [state.phase]);
  const waitForBackendReady = useCallback(async () => {
    const tolerances = adaptiveTolerancesRef.current;
    const maxAttempts = Math.max(3, tolerances.healthFailureLimit + 2);
    for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
      const ok = await pingBackendHealth(tolerances.healthPingTimeoutMs);
      if (ok) {
        markApiOnline();
        return true;
      }
      const retryDelay = Math.min(
        Math.max(1500, Math.round(tolerances.healthCheckTimeoutMs * 0.8)) +
          attempt * 500,
        8000,
      );
      await new Promise((resolve) => setTimeout(resolve, retryDelay));
    }
    markApiOffline();
    return false;
  }, [markApiOffline, markApiOnline]);
  const appendSnapshotEvents = useCallback(
    (events?: string[]) => {
      if (!events || events.length === 0) {
        return;
      }
      events.forEach((event) => {
        if (!seenEventsRef.current.has(event)) {
          seenEventsRef.current.add(event);
          dispatch({
            type: "append-entry",
            entry: entryFactoryRef.current(event),
          });
        }
      });
    },
    [dispatch],
  );

  const applySnapshotMeta = useCallback(
    (snapshot: JobSnapshot, etaSeconds?: number | null) => {
      lastSnapshotAtRef.current = Date.now();
      const summaryUpdate: ConversionSummary = {};
      if (snapshot.detectedLanguage)
        summaryUpdate.detectedLanguage = snapshot.detectedLanguage;
      if (typeof snapshot.chaptersTotal === "number")
        summaryUpdate.chaptersTotal = snapshot.chaptersTotal;
      if (typeof snapshot.chaptersCompleted === "number")
        summaryUpdate.chaptersCompleted = snapshot.chaptersCompleted;
      if (snapshot.currentChapter)
        summaryUpdate.currentChapter = snapshot.currentChapter;
      if (snapshot.statusHint) summaryUpdate.statusHint = snapshot.statusHint;
      if (Array.isArray(snapshot.chapterProgress)) {
        summaryUpdate.chapterProgress = snapshot.chapterProgress.map(
          (entry) => ({ ...entry }),
        );
      }
      if (typeof snapshot.parallelSlots === "number")
        summaryUpdate.parallelSlots = snapshot.parallelSlots;
      if (typeof snapshot.parallelActive === "number")
        summaryUpdate.parallelActive = snapshot.parallelActive;
      if (snapshot.engineStatus)
        summaryUpdate.engineStatus = snapshot.engineStatus;
      const percentFromSnapshot =
        typeof snapshot.progressPercent === "number"
          ? snapshot.progressPercent
          : typeof snapshot.progress === "number"
            ? snapshot.progress * 100
            : undefined;
      if (typeof percentFromSnapshot === "number")
        summaryUpdate.progressPercent = percentFromSnapshot;

      const detailUpdate: Partial<
        Pick<
          ConversionState,
          | "bookTitle"
          | "bookAuthor"
          | "coverUrl"
          | "engine"
          | "voice"
          | "language"
          | "uiLanguage"
          | "speakFormattingCues"
        >
      > = {};
      if (snapshot.bookTitle) detailUpdate.bookTitle = snapshot.bookTitle;
      if (snapshot.bookAuthor) detailUpdate.bookAuthor = snapshot.bookAuthor;
      if (snapshot.coverUrl) detailUpdate.coverUrl = snapshot.coverUrl;
      if (snapshot.engine) detailUpdate.engine = snapshot.engine;
      if (snapshot.voice) detailUpdate.voice = snapshot.voice;
      if (snapshot.language) detailUpdate.language = snapshot.language;
      if (snapshot.uiLanguage) detailUpdate.uiLanguage = snapshot.uiLanguage;
      if (typeof snapshot.formattingCues === "boolean")
        detailUpdate.speakFormattingCues = snapshot.formattingCues;

      const hasSummary = Object.values(summaryUpdate).some(
        (value) => value !== undefined,
      );
      const hasDetails = Object.values(detailUpdate).some(
        (value) => value !== undefined,
      );
      const timestampUpdate: Partial<
        Pick<
          ConversionState,
          "startedAt" | "completedAt" | "totalDurationSeconds"
        >
      > = {};
      if (snapshot.startedAt) {
        timestampUpdate.startedAt = snapshot.startedAt;
      }
      if (snapshot.completedAt) {
        timestampUpdate.completedAt = snapshot.completedAt;
      }
      if (typeof snapshot.totalElapsedSeconds === "number") {
        timestampUpdate.totalDurationSeconds = snapshot.totalElapsedSeconds;
      }
      const hasTimestamps = Object.keys(timestampUpdate).length > 0;

      dispatch({
        type: "update-meta",
        etaSeconds,
        summary: hasSummary ? summaryUpdate : undefined,
        details: hasDetails ? detailUpdate : undefined,
        rawLog: snapshot.rawLog,
        timestamps: hasTimestamps ? timestampUpdate : undefined,
      });
    },
    [dispatch],
  );

  const clearCancelledJob = useCallback(
    (jobId: string) => {
      if (!jobId) return;
      conversionCache.remove(jobId);
      setCachedJobs((prev) =>
        prev.filter((job) => !job.jobId.startsWith(jobId)),
      );
      const removeFn = api?.removeJob;
      if (removeFn && apiAvailable) {
        void (async () => {
          try {
            await removeFn(jobId);
          } catch (error) {
            console.warn(
              "[useConversionFlow] Failed to purge cancelled job on backend",
              jobId,
              error,
            );
          }
        })();
      }
    },
    [api, apiAvailable, setCachedJobs],
  );

  useEffect(() => {
    if (client) {
      setApiAvailable(true);
      return undefined;
    }
    let cancelled = false;
    let isFirstCheck = true;
    let timeoutId: number | undefined;
    const endpoint = resolveHealthEndpoint();
    const visibleIntervalMs = 30000;
    const hiddenIntervalMs = 60000;
    const isActivePhase =
      state.phase === "polling" || state.phase === "submitting";

    const canMarkOffline = () => {
      const graceMs = adaptiveTolerancesRef.current.activeSnapshotGraceMs;
      if (!isActivePhase) {
        return true;
      }
      const lastSnapshotAt = lastSnapshotAtRef.current;
      if (!lastSnapshotAt) {
        return true;
      }
      return Date.now() - lastSnapshotAt > graceMs;
    };

    const scheduleNext = (delay: number) => {
      if (cancelled) {
        return;
      }
      timeoutId = window.setTimeout(() => check(false), delay);
    };

    const check = async (retryOnFail = false) => {
      if (cancelled) {
        return;
      }
      if (
        typeof document !== "undefined" &&
        document.visibilityState === "hidden"
      ) {
        scheduleNext(hiddenIntervalMs);
        return;
      }
      const controller = new AbortController();
      // Longer timeout on first check to avoid false negatives on page load
      const tolerances = adaptiveTolerancesRef.current;
      const timeoutMs = isFirstCheck
        ? tolerances.healthCheckFirstTimeoutMs
        : tolerances.healthCheckTimeoutMs;
      const timeout = setTimeout(() => controller.abort(), timeoutMs);
      let ok = false;
      try {
        const response = await fetch(endpoint, {
          method: "GET",
          cache: "no-store",
          signal: controller.signal,
        });
        if (!cancelled) {
          if (response.ok) {
            markApiOnline();
            ok = true;
            isFirstCheck = false;
          } else {
            healthFailureCountRef.current += 1;
            if (
              healthFailureCountRef.current >= tolerances.healthFailureLimit &&
              canMarkOffline()
            ) {
              markApiOffline();
            }
          }
        }
      } catch {
        if (!cancelled) {
          healthFailureCountRef.current += 1;
          if (
            healthFailureCountRef.current >= tolerances.healthFailureLimit &&
            canMarkOffline()
          ) {
            markApiOffline();
          }
        }
      } finally {
        clearTimeout(timeout);
      }
      if (isFirstCheck && retryOnFail && !ok) {
        scheduleNext(1000);
        return;
      }
      isFirstCheck = false;
      scheduleNext(visibleIntervalMs);
    };

    check(true); // First check with retry enabled
    return () => {
      cancelled = true;
      if (timeoutId) {
        window.clearTimeout(timeoutId);
      }
    };
  }, [client, markApiOffline, markApiOnline, state.phase]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return () => {};
    }
    if (state.phase !== "polling") {
      return () => {};
    }
    if (!state.jobId) {
      return () => {};
    }
    if (!api.fetch) {
      return () => {};
    }
    const jobId = state.jobId;
    let cancelled = false;
    let timeoutId: number | undefined;
    const intervalMs = 5000;
    const staleThresholdMs = 10000;

    const tick = async () => {
      if (cancelled) {
        return;
      }
      const lastSnapshotAt = lastSnapshotAtRef.current;
      if (lastSnapshotAt && Date.now() - lastSnapshotAt < staleThresholdMs) {
        timeoutId = window.setTimeout(tick, intervalMs);
        return;
      }
      try {
        const snapshot = await api.fetch(jobId);
        if (cancelled) {
          return;
        }
        lastSnapshotAtRef.current = Date.now();
        pollFailureCountRef.current = 0;
        appendSnapshotEvents(snapshot.events);
        const etaSeconds = estimateEtaSeconds(snapshot, startTimeRef.current);
        applySnapshotMeta(snapshot, etaSeconds);
        markApiOnline();
      } catch (error) {
        if (!cancelled && isNetworkError(error)) {
          pollFailureCountRef.current += 1;
          const tolerances = adaptiveTolerancesRef.current;
          const lastSnapshotAt = lastSnapshotAtRef.current;
          const hasRecentSnapshot =
            typeof lastSnapshotAt === "number" &&
            Date.now() - lastSnapshotAt < tolerances.activeSnapshotGraceMs;
          if (
            pollFailureCountRef.current >= tolerances.pollFailureLimit &&
            !hasRecentSnapshot
          ) {
            markApiOffline();
          }
        }
      } finally {
        if (!cancelled) {
          timeoutId = window.setTimeout(tick, intervalMs);
        }
      }
    };

    timeoutId = window.setTimeout(tick, intervalMs);
    return () => {
      cancelled = true;
      if (timeoutId) {
        window.clearTimeout(timeoutId);
      }
    };
  }, [
    api,
    applySnapshotMeta,
    appendSnapshotEvents,
    markApiOffline,
    markApiOnline,
    state.jobId,
    state.phase,
  ]);

  // Cleanup old cache on mount and load cached jobs from backend when supported
  useEffect(() => {
    const loadJobs = async () => {
      setCachedJobsLoading(true);

      const expandJobsWithQueue = (
        job: {
          jobId: string;
          fileName: string;
          timestamp: number;
          engine?: string;
          voice?: string;
          language?: string;
        },
        pendingQueue?: ConversionFormValues[],
      ) => {
        const expanded = [
          {
            jobId: job.jobId,
            fileName: job.fileName,
            timestamp: job.timestamp,
            engine: job.engine,
            voice: job.voice,
            language: job.language,
          },
        ];

        // Expand pending queue into separate resumable jobs
        if (pendingQueue && pendingQueue.length > 0) {
          pendingQueue.forEach((queuedJob, index) => {
            const queuedFileName =
              queuedJob.file?.name || queuedJob.fileName || `Book ${index + 2}`;
            expanded.push({
              jobId: `${job.jobId}_queued_${index}`,
              fileName: queuedFileName,
              timestamp: job.timestamp - (index + 1), // Slightly older timestamp for sorting
              engine: queuedJob.engine || job.engine,
              voice: queuedJob.voice || job.voice,
              language: queuedJob.language || job.language,
            });
          });
        }

        return expanded;
      };

      const localFallback = (allowMarkOffline: boolean = true) => {
        const localJobs = conversionCache.listAll();
        const expandedJobs = localJobs.flatMap((job) =>
          expandJobsWithQueue(
            {
              jobId: job.jobId,
              fileName: job.fileName,
              timestamp: job.timestamp,
              engine: job.state?.engine,
              voice: job.state?.voice,
              language:
                job.state?.language ?? job.state?.summary?.detectedLanguage,
            },
            job.state?.pendingBatchQueue,
          ),
        );
        setCachedJobs(expandedJobs);
        if (allowMarkOffline && shouldMarkOffline()) {
          markApiOffline();
        }
        setCachedJobsLoading(false);
      };

      conversionCache.cleanup();

      if (!apiAvailable || !api.getResumableJobs) {
        localFallback(false);
        return;
      }

      try {
        const backendJobs = await api.getResumableJobs();
        if (!backendJobs || backendJobs.length === 0) {
          setCachedJobs([]);
          markApiOnline();
          setCachedJobsLoading(false);
          return;
        }

        // Create a map of local cache to get pendingBatchQueue info
        const localCacheMap = new Map(
          conversionCache.listAll().map((job) => [job.jobId, job]),
        );

        const expandedJobs = backendJobs.flatMap((job) => {
          const localCache = localCacheMap.get(job.jobId);
          return expandJobsWithQueue(
            {
              jobId: job.jobId,
              fileName: job.fileName || job.bookTitle || "Unknown Book",
              timestamp: job.savedAt
                ? new Date(job.savedAt).getTime()
                : Date.now(),
              engine: job.engine,
              voice: job.voice,
              language: job.language,
            },
            localCache?.state?.pendingBatchQueue,
          );
        });

        setCachedJobs(expandedJobs);

        const backendJobIds = new Set(backendJobs.map((j) => j.jobId));
        conversionCache.listAll().forEach((localJob) => {
          if (!backendJobIds.has(localJob.jobId)) {
            conversionCache.remove(localJob.jobId);
          }
        });
        markApiOnline();
        setCachedJobsLoading(false);
      } catch (error) {
        console.warn(
          "[useConversionFlow] Failed to load resumable jobs:",
          error,
        );
        localFallback();
      }
    };

    loadJobs();
  }, [api, apiAvailable, markApiOffline, markApiOnline, shouldMarkOffline]);

  useEffect(() => {
    let cancelled = false;
    if (!api.getRecentJobs || !apiAvailable) {
      setRecentJobs([]);
      return () => {
        cancelled = true;
      };
    }
    let timeoutId: number | undefined;
    const visibleIntervalMs = 30000;
    const hiddenIntervalMs = 60000;

    const scheduleNext = (delay: number) => {
      if (cancelled) {
        return;
      }
      timeoutId = window.setTimeout(fetchRecent, delay);
    };

    const fetchRecent = async () => {
      if (cancelled) {
        return;
      }
      if (
        typeof document !== "undefined" &&
        document.visibilityState === "hidden"
      ) {
        scheduleNext(hiddenIntervalMs);
        return;
      }
      try {
        const jobs = await api.getRecentJobs?.();
        if (!cancelled && Array.isArray(jobs)) {
          setRecentJobs(jobs);
          markApiOnline();
        }
      } catch (error) {
        console.warn("[useConversionFlow] Failed to load recent jobs:", error);
        if (shouldMarkOffline()) {
          markApiOffline();
        }
      }
      scheduleNext(visibleIntervalMs);
    };
    fetchRecent();
    return () => {
      cancelled = true;
      if (timeoutId) {
        window.clearTimeout(timeoutId);
      }
    };
  }, [api, apiAvailable, markApiOffline, markApiOnline, shouldMarkOffline]);

  const resetLogAndCounters = useCallback(() => {
    entryFactoryRef.current = createStatusEntryFactory();
    seenEventsRef.current = new Set<string>();
  }, []);

  const reset = useCallback(() => {
    const controller = abortRef.current;
    if (controller && typeof controller.abort === "function") {
      controller.abort();
    }
    abortRef.current = null;
    resetLogAndCounters();
    lastSnapshotAtRef.current = null;
    startTimeRef.current = null;
    dispatch({ type: "reset" });
  }, [resetLogAndCounters]);

  const runConversion = useCallback(
    async (
      values: ConversionFormValues,
      batchMeta?: { index: number; total: number },
    ): Promise<"success" | "failed" | "cancelled"> => {
      if (!apiAvailable) {
        dispatch({
          type: "append-entry",
          entry: entryFactoryRef.current(t.flow.backendConnecting),
        });
        const ready = await waitForBackendReady();
        if (!ready) {
          dispatch({
            type: "fail",
            error: t.flow.backendOffline,
            entry: entryFactoryRef.current(t.flow.backendOfflineDetails),
          });
          return "failed";
        }
      }
      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;
      resetLogAndCounters();
      lastSnapshotAtRef.current = null;
      startTimeRef.current = Date.now();
      const startedAtIso = new Date().toISOString();
      const originalFileName = values.file?.name ?? values.fileName ?? "";
      fileNameRef.current = originalFileName;
      const requestValues =
        values.uploadId && values.uploadId.trim().length > 0
          ? { ...values, file: null }
          : values;
      const startMessage = values.uploadId
        ? t.flow.startReuse
        : t.flow.startUpload;
      const label =
        batchMeta && batchMeta.total > 1
          ? `${t.flow.batchPosition(batchMeta.index, batchMeta.total)} • ${startMessage}`
          : startMessage;

      // Generate CLI command
      const cliCommand = buildCliCommand(values);

      dispatch({
        type: "start",
        entry: entryFactoryRef.current(label),
        cliCommand,
        startedAt: startedAtIso,
      });
      try {
        const { jobId } = await api.submit(requestValues);
        markApiOnline();
        dispatch({
          type: "job-created",
          jobId,
          entry: entryFactoryRef.current(t.flow.jobCreated(jobId)),
        });

        const finalSnapshot = await api.poll(jobId, {
          signal: controller.signal,
          onSnapshot(snapshot) {
            const etaSeconds = estimateEtaSeconds(
              snapshot,
              startTimeRef.current,
            );
            applySnapshotMeta(snapshot, etaSeconds);
            appendSnapshotEvents(snapshot.events);

            // Save to cache periodically during conversion
            if (snapshot.state === "running" || snapshot.state === "queued") {
              saveStateWithQueue(jobId, fileNameRef.current, state);
            }
          },
        });

        if (finalSnapshot.state === "cancelled") {
          dispatch({
            type: "cancelled",
            error: t.flow.cancelled,
            entry: entryFactoryRef.current(t.flow.cancelled),
          });
          clearCancelledJob(jobId);
          startTimeRef.current = null;
          return "cancelled";
        }

        if (finalSnapshot.state === "failed") {
          const failureMessage = finalSnapshot.error || t.flow.defaultFailure;
          dispatch({
            type: "fail",
            error: failureMessage,
            errorCategory: finalSnapshot.errorCategory,
            entry: entryFactoryRef.current(t.flow.failure(failureMessage)),
          });
          startTimeRef.current = null;
          return "failed";
        }

        const downloads = finalSnapshot.outputs ?? [];
        // Count only MP3 files (exclude ZIP)
        const chapterCount = downloads.filter((d) =>
          d.name.toLowerCase().endsWith(".mp3"),
        ).length;

        const summaryUpdate: ConversionSummary = {};
        if (typeof finalSnapshot.chaptersCompleted === "number") {
          summaryUpdate.chaptersCompleted = finalSnapshot.chaptersCompleted;
        } else if (chapterCount > 0) {
          summaryUpdate.chaptersCompleted = chapterCount;
        }
        if (typeof finalSnapshot.chaptersTotal === "number") {
          summaryUpdate.chaptersTotal = finalSnapshot.chaptersTotal;
        } else if (chapterCount > 0) {
          summaryUpdate.chaptersTotal = chapterCount;
        }
        if (Array.isArray(finalSnapshot.chapterProgress)) {
          summaryUpdate.chapterProgress = finalSnapshot.chapterProgress.map(
            (entry) => ({
              ...entry,
            }),
          );
        }
        if (finalSnapshot.statusHint) {
          summaryUpdate.statusHint = finalSnapshot.statusHint;
        }
        if (typeof finalSnapshot.parallelSlots === "number") {
          summaryUpdate.parallelSlots = finalSnapshot.parallelSlots;
        }
        if (typeof finalSnapshot.parallelActive === "number") {
          summaryUpdate.parallelActive = finalSnapshot.parallelActive;
        }
        summaryUpdate.progressPercent = 100;
        const detailUpdate: Partial<
          Pick<ConversionState, "bookTitle" | "bookAuthor" | "coverUrl">
        > = {};
        if (finalSnapshot.bookTitle)
          detailUpdate.bookTitle = finalSnapshot.bookTitle;
        if (finalSnapshot.bookAuthor)
          detailUpdate.bookAuthor = finalSnapshot.bookAuthor;
        if (finalSnapshot.coverUrl)
          detailUpdate.coverUrl = finalSnapshot.coverUrl;
        const hasDetails = Object.values(detailUpdate).some(
          (value) => value !== undefined,
        );
        dispatch({
          type: "update-meta",
          etaSeconds: 0,
          summary: summaryUpdate,
          details: hasDetails ? detailUpdate : undefined,
          rawLog: finalSnapshot.rawLog,
        });
        const completedAtIso =
          finalSnapshot.completedAt ?? new Date().toISOString();
        const totalElapsedSeconds =
          typeof finalSnapshot.totalElapsedSeconds === "number"
            ? Math.max(0, Math.round(finalSnapshot.totalElapsedSeconds))
            : startTimeRef.current
              ? Math.max(
                  0,
                  Math.round((Date.now() - startTimeRef.current) / 1000),
                )
              : undefined;
        dispatch({
          type: "complete",
          downloads,
          entry: entryFactoryRef.current(t.flow.completion(chapterCount)),
          completedAt: completedAtIso,
          totalDurationSeconds: totalElapsedSeconds,
        });
        // Clear cache on successful completion
        conversionCache.remove(jobId);
        startTimeRef.current = null;
        return "success";
      } catch (error) {
        if (isNetworkError(error)) {
          markApiOffline();
        }
        if (error instanceof DOMException && error.name === "AbortError") {
          return "cancelled";
        }
        const message =
          error instanceof Error && error.message
            ? error.message
            : t.flow.defaultError;
        dispatch({
          type: "fail",
          error: message,
          entry: entryFactoryRef.current(t.flow.error(message)),
        });
        startTimeRef.current = null;
        return "failed";
      }
    },
    [
      api,
      apiAvailable,
      applySnapshotMeta,
      appendSnapshotEvents,
      clearCancelledJob,
      markApiOffline,
      markApiOnline,
      resetLogAndCounters,
      state,
      t,
      waitForBackendReady,
    ],
  );

  const drainQueue = useCallback(async () => {
    if (queueActiveRef.current || queuePausedRef.current) {
      console.log(
        "[drainQueue] Skipping - active:",
        queueActiveRef.current,
        "paused:",
        queuePausedRef.current,
      );
      return;
    }
    queueActiveRef.current = true;
    console.log(
      "[drainQueue] Starting queue processing. Jobs in queue:",
      jobQueueRef.current.length,
    );
    try {
      while (jobQueueRef.current.length > 0) {
        if (queuePausedRef.current) {
          console.log("[drainQueue] Queue paused, breaking");
          break;
        }
        const currentJob = jobQueueRef.current.shift();
        if (!currentJob) {
          console.log("[drainQueue] No current job, breaking");
          break;
        }
        syncQueueSnapshot();
        const currentIndex = processedCountRef.current + 1;
        const total = currentIndex + jobQueueRef.current.length;
        const meta = total > 1 ? { index: currentIndex, total } : undefined;
        console.log("[drainQueue] Processing job", currentIndex, "of", total);
        const result = await runConversion(currentJob, meta);
        console.log("[drainQueue] Job completed with result:", result);

        // Save remaining queue if there was a failure or cancellation
        if (result === "cancelled" || result === "failed") {
          if (result === "cancelled") {
            // Check if we're in skip mode
            console.log(
              "[drainQueue] Cancelled detected. Skip mode:",
              skipModeRef.current,
            );
            if (skipModeRef.current) {
              // Skip mode: don't pause queue, don't put job back, just continue
              skipModeRef.current = false; // Reset flag
              console.log(
                "[drainQueue] Skip mode: continuing to next job. Remaining:",
                jobQueueRef.current.length,
              );
              dispatch({
                type: "reset",
              });
              // Continue to next job without pausing
            } else {
              // Normal cancel: pause queue and drop current job
              console.log("[drainQueue] Normal cancel: pausing queue");
              syncQueueSnapshot();
              setQueuePaused(true);
              const remaining = jobQueueRef.current.length;
              dispatch({
                type: "append-entry",
                entry: entryFactoryRef.current(
                  t.flow.batchCancelled(remaining),
                ),
              });
              break;
            }
          }

          if (
            result === "failed" &&
            jobQueueRef.current.length > 0 &&
            state.jobId
          ) {
            // Save the remaining queue with the current job state
            saveStateWithQueue(state.jobId, fileNameRef.current, state);
          }
          // For 'failed', continue to next job in queue
        }
        processedCountRef.current += 1;
        console.log(
          "[drainQueue] Processed count:",
          processedCountRef.current,
          "Remaining jobs:",
          jobQueueRef.current.length,
        );
      }
      console.log("[drainQueue] Queue processing finished");
    } finally {
      queueActiveRef.current = false;
      if (jobQueueRef.current.length === 0) {
        setQueuePaused(false);
      }
      processedCountRef.current = 0;
      console.log(
        "[drainQueue] Cleanup complete. Queue active:",
        queueActiveRef.current,
      );
    }
  }, [
    dispatch,
    runConversion,
    setQueuePaused,
    state,
    syncQueueSnapshot,
    t.flow.batchCancelled,
  ]);

  const submit = useCallback(
    async (values: ConversionFormValues, options?: SubmitBatchOptions) => {
      const queue = [values, ...(options?.batchQueue ?? [])].filter(Boolean);
      if (queue.length === 0) {
        return;
      }
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

  const resume = useCallback(
    async (jobId: string) => {
      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;

      resetLogAndCounters();
      lastSnapshotAtRef.current = null;
      dispatch({
        type: "append-entry",
        entry: entryFactoryRef.current(
          t.flow.loadingCache || "📦 Restoring conversion data...",
        ),
      });
      const continuePendingBatch = async () => {
        if (jobQueueRef.current.length === 0) {
          return;
        }
        console.log(
          `[Resume] Continuing batch queue with ${jobQueueRef.current.length} remaining jobs`,
        );
        dispatch({
          type: "append-entry",
          entry: entryFactoryRef.current(
            `🚀 Starting queue processing: ${jobQueueRef.current.length} pending conversions`,
          ),
        });
        processedCountRef.current = 1; // Count the resumed job as processed
        setQueuePaused(false);
        await drainQueue();
      };

      // Handle queued job IDs (e.g., "job123_queued_2" -> resume from 3rd item in queue)
      let actualJobId = jobId;
      let queueStartIndex = 0;

      const queuedMatch = jobId.match(/^(.+)_queued_(\d+)$/);
      if (queuedMatch) {
        actualJobId = queuedMatch[1];
        queueStartIndex = parseInt(queuedMatch[2], 10);
        console.log(
          `[Resume] Detected queued job. Original ID: ${actualJobId}, Queue index: ${queueStartIndex}`,
        );
      }

      const cached = conversionCache.load(actualJobId);
      if (cached) {
        console.log("[useConversionFlow] Loaded cache for jobId:", jobId, {
          fileName: cached.fileName,
          bookTitle: cached.state.bookTitle,
          jobId: cached.jobId,
        });
        fileNameRef.current = cached.fileName;
        if (Array.isArray(cached.state.log)) {
          cached.state.log.forEach((entry) => {
            seenEventsRef.current.add(entry.message);
            dispatch({ type: "append-entry", entry });
          });
        }
        if (
          cached.state.summary ||
          cached.state.bookTitle ||
          cached.state.bookAuthor ||
          cached.state.coverUrl
        ) {
          dispatch({
            type: "update-meta",
            summary: cached.state.summary,
            details: {
              bookTitle: cached.state.bookTitle,
              bookAuthor: cached.state.bookAuthor,
              coverUrl: cached.state.coverUrl,
            },
            rawLog: cached.state.rawLog,
          });
        }

        // Restore batch queue if it was saved, starting from the correct position
        if (
          Array.isArray(cached.state.pendingBatchQueue) &&
          cached.state.pendingBatchQueue.length > 0
        ) {
          // If resuming a queued job, start from that position in the queue
          const queueToRestore =
            queueStartIndex > 0
              ? cached.state.pendingBatchQueue.slice(queueStartIndex)
              : cached.state.pendingBatchQueue;

          if (queueToRestore.length > 0) {
            jobQueueRef.current = queueToRestore;
            syncQueueSnapshot();
            console.log(
              `[Resume] Restored batch queue with ${queueToRestore.length} pending jobs (starting from index ${queueStartIndex})`,
            );
            dispatch({
              type: "append-entry",
              entry: entryFactoryRef.current(
                `🔄 Queue restored: ${queueToRestore.length} pending conversions will resume after this one`,
              ),
            });
          }
        }
      }

      if (!apiAvailable) {
        dispatch({
          type: "append-entry",
          entry: entryFactoryRef.current(t.flow.backendConnecting),
        });
        const ready = await waitForBackendReady();
        if (!ready) {
          dispatch({
            type: "fail",
            error: t.flow.backendOffline,
            entry: entryFactoryRef.current(t.flow.backendOfflineDetails),
          });
          startTimeRef.current = null;
          return;
        }
      }

      dispatch({
        type: "job-created",
        jobId: actualJobId,
        entry: entryFactoryRef.current(t.flow.resuming),
      });

      startTimeRef.current = Date.now();

      let initialSnapshot: JobSnapshot | null = null;
      const fetchInitialSnapshot = async (): Promise<JobSnapshot> => {
        let attempt = 0;
        while (attempt < INITIAL_FETCH_RETRY_ATTEMPTS) {
          try {
            return await api.fetch(actualJobId);
          } catch (error) {
            const isNotFoundError =
              error instanceof Error && error.message.includes("404");
            if (!isNotFoundError) {
              throw error;
            }
            attempt += 1;
            if (attempt >= INITIAL_FETCH_RETRY_ATTEMPTS) {
              throw error;
            }
            const backoff = Math.min(
              INITIAL_FETCH_RETRY_BASE_DELAY_MS *
                Math.pow(1.5, Math.max(0, attempt - 1)),
              INITIAL_FETCH_RETRY_MAX_DELAY_MS,
            );
            console.info(
              `[useConversionFlow] Job ${actualJobId} not yet persisted in backend (attempt ${attempt}/${INITIAL_FETCH_RETRY_ATTEMPTS}). Waiting ${backoff}ms before retrying.`,
            );
            await sleepMs(backoff);
          }
        }
        throw new Error("Failed to load initial conversion state");
      };
      try {
        initialSnapshot = await fetchInitialSnapshot();
        console.log(
          "[useConversionFlow] Fetched initial snapshot for jobId:",
          actualJobId,
          {
            bookTitle: initialSnapshot.bookTitle,
            state: initialSnapshot.state,
          },
        );
        markApiOnline();
      } catch (error) {
        if (error instanceof Error && error.message.includes("404")) {
          markApiOnline();
          dispatch({
            type: "fail",
            error: "Conversion not found",
            entry: entryFactoryRef.current(
              "This conversion no longer exists on the server. It may have been removed or expired.",
            ),
          });
          // Remove both the original job and any queued job variants
          setCachedJobs((prev) =>
            prev.filter((j) => !j.jobId.startsWith(actualJobId)),
          );
          conversionCache.remove(actualJobId);
          startTimeRef.current = null;
          await continuePendingBatch();
          return;
        } else if (isNetworkError(error)) {
          markApiOffline();
        }
        console.warn(
          "[useConversionFlow] Failed to fetch job from backend:",
          error,
        );
      }

      if (!initialSnapshot) {
        dispatch({
          type: "fail",
          error: "Could not recover conversion state",
          entry: entryFactoryRef.current(
            "Server returned no information about this conversion.",
          ),
        });
        startTimeRef.current = null;
        await continuePendingBatch();
        return;
      }

      if (!fileNameRef.current) {
        fileNameRef.current =
          initialSnapshot.bookTitle || cached?.fileName || "Book";
      }

      appendSnapshotEvents(initialSnapshot.events);
      applySnapshotMeta(initialSnapshot);

      if (initialSnapshot.state === "interrupted") {
        const message = initialSnapshot.error || "Conversion interrupted";
        dispatch({
          type: "fail",
          error: message,
          entry: entryFactoryRef.current(message),
        });
        setCachedJobs((prev) =>
          prev.filter((j) => !j.jobId.startsWith(actualJobId)),
        );
        conversionCache.remove(actualJobId);
        startTimeRef.current = null;
        await continuePendingBatch();
        return;
      }

      if (initialSnapshot.state === "finished") {
        const downloads = initialSnapshot.outputs ?? [];
        const chapterCount = downloads.filter((d) =>
          d.name.toLowerCase().endsWith(".mp3"),
        ).length;
        const completedAtIso =
          initialSnapshot.completedAt ??
          initialSnapshot.updatedAt ??
          new Date().toISOString();
        const totalElapsedSeconds =
          typeof initialSnapshot.totalElapsedSeconds === "number"
            ? Math.max(0, Math.round(initialSnapshot.totalElapsedSeconds))
            : undefined;
        dispatch({
          type: "complete",
          downloads,
          entry: entryFactoryRef.current(t.flow.completion(chapterCount)),
          completedAt: completedAtIso,
          totalDurationSeconds: totalElapsedSeconds,
        });
        conversionCache.remove(actualJobId);
        setCachedJobs((prev) =>
          prev.filter((j) => !j.jobId.startsWith(actualJobId)),
        );
        startTimeRef.current = null;
        await continuePendingBatch();
        return;
      }

      if (initialSnapshot.state === "failed") {
        const failureMessage = initialSnapshot.error || t.flow.defaultFailure;
        dispatch({
          type: "fail",
          error: failureMessage,
          entry: entryFactoryRef.current(t.flow.failure(failureMessage)),
        });
        setCachedJobs((prev) =>
          prev.filter((j) => !j.jobId.startsWith(actualJobId)),
        );
        conversionCache.remove(actualJobId);
        startTimeRef.current = null;
        await continuePendingBatch();
        return;
      }

      if (
        api.resume &&
        initialSnapshot.state !== "running" &&
        initialSnapshot.state !== "cancelling"
      ) {
        try {
          await api.resume(actualJobId);
          markApiOnline();
        } catch (error) {
          if (isNetworkError(error)) {
            markApiOffline();
          }
          const message =
            error instanceof Error && error.message
              ? error.message
              : t.flow.defaultFailure;
          dispatch({
            type: "fail",
            error: message,
            entry: entryFactoryRef.current(t.flow.failure(message)),
          });
          startTimeRef.current = null;
          await continuePendingBatch();
          return;
        }
      }

      try {
        const finalSnapshot = await api.poll(actualJobId, {
          signal: controller.signal,
          onSnapshot(snapshot) {
            markApiOnline();
            const etaSeconds = estimateEtaSeconds(
              snapshot,
              startTimeRef.current,
            );
            applySnapshotMeta(snapshot, etaSeconds);
            appendSnapshotEvents(snapshot.events);

            if (snapshot.state === "running" || snapshot.state === "queued") {
              saveStateWithQueue(actualJobId, fileNameRef.current, state);
            }
          },
        });

        if (finalSnapshot.state === "cancelled") {
          dispatch({
            type: "cancelled",
            error: t.flow.cancelled,
            entry: entryFactoryRef.current(t.flow.cancelled),
          });
          clearCancelledJob(actualJobId);
          startTimeRef.current = null;
          await continuePendingBatch();
          return;
        }

        if (
          finalSnapshot.state === "failed" ||
          finalSnapshot.state === "interrupted"
        ) {
          const failureMessage = finalSnapshot.error || t.flow.defaultFailure;
          dispatch({
            type: "fail",
            error: failureMessage,
            errorCategory: finalSnapshot.errorCategory,
            entry: entryFactoryRef.current(t.flow.failure(failureMessage)),
          });
          setCachedJobs((prev) =>
            prev.filter((j) => !j.jobId.startsWith(actualJobId)),
          );
          startTimeRef.current = null;
          await continuePendingBatch();
          return;
        }

        const downloads = finalSnapshot.outputs ?? [];
        const chapterCount = downloads.filter((d) =>
          d.name.toLowerCase().endsWith(".mp3"),
        ).length;
        applySnapshotMeta(finalSnapshot, 0);
        const completedAtIso =
          finalSnapshot.completedAt ?? new Date().toISOString();
        const totalElapsedSeconds =
          typeof finalSnapshot.totalElapsedSeconds === "number"
            ? Math.max(0, Math.round(finalSnapshot.totalElapsedSeconds))
            : startTimeRef.current
              ? Math.max(
                  0,
                  Math.round((Date.now() - startTimeRef.current) / 1000),
                )
              : undefined;
        dispatch({
          type: "complete",
          downloads,
          entry: entryFactoryRef.current(t.flow.completion(chapterCount)),
          completedAt: completedAtIso,
          totalDurationSeconds: totalElapsedSeconds,
        });
        conversionCache.remove(actualJobId);
        setCachedJobs((prev) =>
          prev.filter((j) => !j.jobId.startsWith(actualJobId)),
        );
        startTimeRef.current = null;

        await continuePendingBatch();
      } catch (error) {
        if (error instanceof DOMException && error.name === "AbortError") {
          return;
        }
        const message =
          error instanceof Error && error.message
            ? error.message
            : t.flow.defaultError;
        if (isNetworkError(error)) {
          markApiOffline();
        }
        dispatch({
          type: "fail",
          error: message,
          entry: entryFactoryRef.current(t.flow.error(message)),
        });
        startTimeRef.current = null;
        await continuePendingBatch();
      }
    },
    [
      api,
      apiAvailable,
      applySnapshotMeta,
      appendSnapshotEvents,
      clearCancelledJob,
      drainQueue,
      markApiOffline,
      markApiOnline,
      resetLogAndCounters,
      setCachedJobs,
      setQueuePaused,
      state,
      syncQueueSnapshot,
      t,
    ],
  );

  useEffect(() => {
    return () => {
      abortRef.current?.abort();
    };
  }, []);

  const cancel = useCallback(async (): Promise<boolean> => {
    if (
      state.phase === "idle" ||
      state.phase === "success" ||
      state.phase === "error"
    ) {
      return false;
    }
    const controller = abortRef.current;
    if (controller && typeof controller.abort === "function") {
      controller.abort();
    }
    abortRef.current = null;
    startTimeRef.current = null;

    const entry = entryFactoryRef.current(t.flow.cancelled);
    dispatch({
      type: "cancelled",
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
    if (jobId && !removeFn && typeof cancelFn === "function") {
      void (async () => {
        try {
          await cancelFn(jobId);
        } catch (error) {
          const message =
            error instanceof Error && error.message
              ? error.message
              : t.flow.cancelFailed("");
          dispatch({
            type: "append-entry",
            entry: entryFactoryRef.current(t.flow.cancelFailed(message)),
          });
        }
      })();
    }

    return true;
  }, [api, clearCancelledJob, setQueuePaused, state.jobId, state.phase, t]);

  const skipCurrent = useCallback(async (): Promise<boolean> => {
    if (
      state.phase === "idle" ||
      state.phase === "success" ||
      state.phase === "error"
    ) {
      return false;
    }

    // Check if there's a queue to continue with
    if (jobQueueRef.current.length === 0) {
      // No queue, just cancel normally
      return cancel();
    }

    console.log(
      "[skipCurrent] Skipping current job. Queue has",
      jobQueueRef.current.length,
      "jobs. Queue active:",
      queueActiveRef.current,
    );

    // Set skip mode flag so drainQueue knows not to pause
    skipModeRef.current = true;

    const controller = abortRef.current;
    if (controller && typeof controller.abort === "function") {
      controller.abort();
    }
    abortRef.current = null;
    startTimeRef.current = null;

    const entry = entryFactoryRef.current(
      t.flow.skipped || "Current conversion skipped, moving to next",
    );
    dispatch({
      type: "cancelled",
      error: t.flow.skipped || "Skipped",
      entry,
    });

    const jobId = state.jobId;
    const cancelFn = api?.cancel;
    const removeFn = api?.removeJob;
    if (jobId) {
      if (!removeFn && typeof cancelFn === "function") {
        void (async () => {
          try {
            await cancelFn(jobId);
          } catch (error) {
            console.warn(
              "[skipCurrent] Failed to cancel job on backend:",
              error,
            );
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
      console.log("[skipCurrent] Queue not active, starting drain");
      dispatch({
        type: "append-entry",
        entry: entryFactoryRef.current(
          `⏭️ Skipping to next queued book (${jobQueueRef.current.length} remaining)`,
        ),
      });
      // Give time for the cancel to propagate
      await new Promise((resolve) => setTimeout(resolve, 100));
      void drainQueue();
    } else {
      console.log(
        "[skipCurrent] Queue already active, will continue automatically",
      );
      dispatch({
        type: "append-entry",
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
        console.warn(
          "[useConversionFlow] Failed to cancel cached job",
          jobId,
          error,
        );
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
            await removeFn(jobId);
          } catch (error) {
            console.warn(
              "[useConversionFlow] Failed to remove job on backend",
              jobId,
              error,
            );
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
        throw new Error("Upload not supported by current client");
      }
      try {
        const response = await api.upload(file);
        markApiOnline();
        dispatch({
          type: "update-meta",
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
        throw new Error("Restart not supported in this client");
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
          const response = await fetch(resolveApiUrl("/api/health"));
          if (response.ok) {
            const data = await response.json();
            return data.status === "healthy";
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
          console.log("[Restart] Backend is healthy, reloading page...");
          window.location.reload();
        } else if (attempts < maxAttempts) {
          setTimeout(pollForHealth, pollInterval);
        } else {
          console.warn("[Restart] Backend did not become healthy in time");
          // Still try to reload in case it's working
          window.location.reload();
        }
      };

      // Start polling after a short delay to allow backend to shut down
      setTimeout(pollForHealth, 3000);
    },
    [api, beginRestartGrace, clearQueue, reset],
  );

  const isBusy =
    state.phase === "submitting" ||
    state.phase === "polling" ||
    state.phase === "cancelling";

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
    queue: queueSnapshot,
    queuePaused,
    resumeQueue,
    clearQueue,
    reorderQueue,
    restartBackend,
  };
}
