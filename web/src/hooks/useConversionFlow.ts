import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react';
import { conversionClient, ConversionClient, UploadResponse } from '../services/ConversionService';
import { conversionCache } from '../services/ConversionCache';
import {
  ConversionFormValues,
  ConversionState,
  DownloadAsset,
  StatusEntry,
  JobSnapshot,
  ConversionSummary,
  RecentJobEntry,
  SubmitBatchOptions,
} from '../types/conversion';
import { useTranslations } from '../i18n/I18nProvider';
import { API_BASE_URL } from '../config';

const isNetworkError = (error: unknown): boolean => {
  if (!(error instanceof Error)) {
    return false;
  }
  const message = error.message.toLowerCase();
  return message.includes('failed to fetch') || message.includes('network') || message.includes('timeout');
};

function buildCliCommand(values: ConversionFormValues): string {
  const parts = ['python python_app/convert'];
  const displayFileName = values.file?.name || values.fileName;
  if (displayFileName) {
    parts.push(displayFileName);
  }

  if (values.engine) {
    parts.push('--engine', values.engine);
  }

  if (values.voice) {
    parts.push('--voice', values.voice);
  }

  if (values.chapters) {
    parts.push('--chapter', values.chapters);
  }
  if (values.priority) {
    parts.push('--priority', values.priority);
  }

  if (values.footnoteMode && values.footnoteMode !== 'inline') {
    if (values.footnoteMode === 'skip') {
      parts.push('--no-footnote');
    } else if (values.footnoteMode === 'chapter_end') {
      parts.push('--footnote-chapter-end');
    }
  }

  if (values.language) {
    parts.push('--language', values.language);
  }

  return parts.join(' ');
}

type Action =
  | { type: 'reset' }
  | { type: 'start'; entry: StatusEntry; cliCommand: string }
  | { type: 'job-created'; entry: StatusEntry; jobId: string }
  | { type: 'append-entry'; entry: StatusEntry }
  | { type: 'complete'; entry: StatusEntry; downloads: DownloadAsset[] }
  | { type: 'fail'; entry: StatusEntry; error: string }
  | { type: 'cancelling'; entry: StatusEntry }
  | { type: 'cancelled'; entry: StatusEntry; error: string }
  | {
      type: 'update-meta';
      etaSeconds?: number | null;
      summary?: ConversionSummary;
      details?: Partial<Pick<ConversionState, 'bookTitle' | 'bookAuthor' | 'coverUrl' | 'engine' | 'voice' | 'language' | 'uiLanguage' | 'speakFormattingCues'>>;
      rawLog?: string[];
    };

const initialState: ConversionState = {
  phase: 'idle',
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
};

function reducer(state: ConversionState, action: Action): ConversionState {
  switch (action.type) {
    case 'reset':
      return { ...initialState };
    case 'start':
      return {
        ...initialState,
        phase: 'submitting',
        log: [action.entry],
        cliCommand: action.cliCommand,
      };
    case 'job-created':
      return {
        ...state,
        phase: 'polling',
        jobId: action.jobId,
        log: [...state.log, action.entry],
      };
    case 'append-entry':
      return {
        ...state,
        log: [...state.log, action.entry],
      };
    case 'complete':
      return {
        ...state,
        phase: 'success',
        downloads: action.downloads,
        log: [...state.log, action.entry],
        error: undefined,
        etaSeconds: 0,
        summary: state.summary
          ? { ...state.summary, progressPercent: state.summary.progressPercent ?? 100 }
          : state.summary,
      };
    case 'fail':
      return {
        ...state,
        phase: 'error',
        error: action.error,
        log: [...state.log, action.entry],
        etaSeconds: 0,
        summary: state.summary,
      };
    case 'cancelling':
      return {
        ...state,
        phase: 'cancelling',
        log: [...state.log, action.entry],
      };
    case 'cancelled':
      return {
        ...state,
        phase: 'cancelled',
        error: action.error,
        log: [...state.log, action.entry],
      };
    case 'update-meta':
      let nextSummary = state.summary;
      if (action.summary) {
        nextSummary = { ...nextSummary } as ConversionSummary;
        for (const [key, value] of Object.entries(action.summary) as [keyof ConversionSummary, unknown][]) {
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
        etaSeconds: typeof action.etaSeconds === 'number' ? Math.max(0, action.etaSeconds) : action.etaSeconds,
        summary: nextSummary,
      };
      if (action.details) {
        if (action.details.bookTitle !== undefined) updatedState.bookTitle = action.details.bookTitle;
        if (action.details.bookAuthor !== undefined) updatedState.bookAuthor = action.details.bookAuthor;
        if (action.details.coverUrl !== undefined) updatedState.coverUrl = action.details.coverUrl;
        if (action.details.engine !== undefined) updatedState.engine = action.details.engine;
        if (action.details.voice !== undefined) updatedState.voice = action.details.voice;
        if (action.details.language !== undefined) updatedState.language = action.details.language;
        if (action.details.uiLanguage !== undefined) updatedState.uiLanguage = action.details.uiLanguage;
        if (action.details.speakFormattingCues !== undefined) {
            updatedState.speakFormattingCues = action.details.speakFormattingCues;
        }
      }
      if (Array.isArray(action.rawLog)) {
        updatedState.rawLog = action.rawLog;
      }
      return updatedState;
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

function estimateEtaSeconds(snapshot: JobSnapshot, startedAt: number | null): number | undefined {
  if (typeof snapshot.etaSeconds === 'number') {
    return snapshot.etaSeconds;
  }
  let progress = typeof snapshot.progress === 'number' ? snapshot.progress : null;
  if ((progress === null || progress === undefined) && typeof snapshot.progressPercent === 'number') {
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
  submit: (values: ConversionFormValues, options?: SubmitBatchOptions) => Promise<void>;
  enqueue: (jobs: ConversionFormValues[]) => Promise<void>;
  resume: (jobId: string) => Promise<void>;
  reset: () => void;
  cancel: () => Promise<boolean>;
  cancelJobById: (jobId: string) => Promise<void>;
  removeCachedJob: (jobId: string) => void;
  isBusy: boolean;
  cachedJobs: Array<{ jobId: string; fileName: string; timestamp: number; engine?: string; voice?: string; language?: string }>;
  uploadFile: (file: File) => Promise<UploadResponse>;
  recentJobs: RecentJobEntry[];
  apiAvailable: boolean;
  healthStatus: 'unknown' | 'ok' | 'fail';
}

export function useConversionFlow(client?: ConversionClient): UseConversionFlowApi {
  const [state, dispatch] = useReducer(reducer, initialState);
  const api = useMemo(() => client ?? conversionClient, [client]);
  const abortRef = useRef<AbortController | null>(null);
  const seenEventsRef = useRef<Set<string>>(new Set());
  const entryFactoryRef = useRef(createStatusEntryFactory());
  const startTimeRef = useRef<number | null>(null);
  const fileNameRef = useRef<string>('');
  const jobQueueRef = useRef<ConversionFormValues[]>([]);
  const queueActiveRef = useRef(false);
  const processedCountRef = useRef(0);
  const t = useTranslations();
  const [cachedJobs, setCachedJobs] = useState<Array<{ jobId: string; fileName: string; timestamp: number; engine?: string; voice?: string; language?: string }>>([]);
  const [recentJobs, setRecentJobs] = useState<RecentJobEntry[]>([]);
  const [apiAvailable, setApiAvailable] = useState(true);
  const [healthStatus, setHealthStatus] = useState<'unknown' | 'ok' | 'fail'>('unknown');
  const markApiOnline = useCallback(() => {
    setApiAvailable(true);
    setHealthStatus('ok');
  }, []);
  const markApiOffline = useCallback(() => {
    setApiAvailable(false);
    setHealthStatus('fail');
  }, []);
  const appendSnapshotEvents = useCallback((events?: string[]) => {
    if (!events || events.length === 0) {
      return;
    }
    events.forEach((event) => {
      if (!seenEventsRef.current.has(event)) {
        seenEventsRef.current.add(event);
        dispatch({
          type: 'append-entry',
          entry: entryFactoryRef.current(event),
        });
      }
    });
  }, [dispatch]);

  const applySnapshotMeta = useCallback((snapshot: JobSnapshot, etaSeconds?: number | null) => {
    const summaryUpdate: ConversionSummary = {};
    if (snapshot.detectedLanguage) summaryUpdate.detectedLanguage = snapshot.detectedLanguage;
    if (typeof snapshot.chaptersTotal === 'number') summaryUpdate.chaptersTotal = snapshot.chaptersTotal;
    if (typeof snapshot.chaptersCompleted === 'number') summaryUpdate.chaptersCompleted = snapshot.chaptersCompleted;
    if (snapshot.currentChapter) summaryUpdate.currentChapter = snapshot.currentChapter;
    if (snapshot.statusHint) summaryUpdate.statusHint = snapshot.statusHint;
    if (Array.isArray(snapshot.chapterProgress)) {
      summaryUpdate.chapterProgress = snapshot.chapterProgress.map(entry => ({ ...entry }));
    }
    if (typeof snapshot.parallelSlots === 'number') summaryUpdate.parallelSlots = snapshot.parallelSlots;
    if (typeof snapshot.parallelActive === 'number') summaryUpdate.parallelActive = snapshot.parallelActive;
    const percentFromSnapshot = typeof snapshot.progressPercent === 'number'
      ? snapshot.progressPercent
      : typeof snapshot.progress === 'number'
        ? snapshot.progress * 100
        : undefined;
    if (typeof percentFromSnapshot === 'number') summaryUpdate.progressPercent = percentFromSnapshot;

    const detailUpdate: Partial<Pick<ConversionState, 'bookTitle' | 'bookAuthor' | 'coverUrl' | 'engine' | 'voice' | 'language' | 'uiLanguage' | 'speakFormattingCues'>> = {};
    if (snapshot.bookTitle) detailUpdate.bookTitle = snapshot.bookTitle;
    if (snapshot.bookAuthor) detailUpdate.bookAuthor = snapshot.bookAuthor;
    if (snapshot.coverUrl) detailUpdate.coverUrl = snapshot.coverUrl;
    if (snapshot.engine) detailUpdate.engine = snapshot.engine;
    if (snapshot.voice) detailUpdate.voice = snapshot.voice;
    if (snapshot.language) detailUpdate.language = snapshot.language;
    if (snapshot.uiLanguage) detailUpdate.uiLanguage = snapshot.uiLanguage;
    if (typeof snapshot.formattingCues === 'boolean') detailUpdate.speakFormattingCues = snapshot.formattingCues;

    const hasSummary = Object.values(summaryUpdate).some((value) => value !== undefined);
    const hasDetails = Object.values(detailUpdate).some((value) => value !== undefined);

    dispatch({
      type: 'update-meta',
      etaSeconds,
      summary: hasSummary ? summaryUpdate : undefined,
      details: hasDetails ? detailUpdate : undefined,
      rawLog: snapshot.rawLog,
    });
  }, [dispatch]);

  const persistCancelledJob = useCallback((jobId: string, snapshotState?: ConversionState) => {
    if (!jobId) return;
    const baseState = snapshotState ?? state;
    const resolvedState: ConversionState = {
      ...baseState,
      phase: 'cancelled',
      jobId,
    };
    const resolvedName = (fileNameRef.current && fileNameRef.current.trim())
      ? fileNameRef.current
      : (resolvedState.bookTitle && resolvedState.bookTitle.trim())
        ? resolvedState.bookTitle.trim()
        : t.status.bookFallbackTitle;
    conversionCache.save(jobId, resolvedName, resolvedState);
    setCachedJobs((prev) => {
      const next = prev.filter((job) => job.jobId !== jobId);
      next.unshift({
        jobId,
        fileName: resolvedName,
        timestamp: Date.now(),
        engine: resolvedState.engine,
        voice: resolvedState.voice,
        language: resolvedState.language ?? resolvedState.summary?.detectedLanguage,
      });
      return next;
    });
  }, [setCachedJobs, state, t.status.bookFallbackTitle]);

  useEffect(() => {
    if (client) {
      setApiAvailable(true);
      return undefined;
    }
    let cancelled = false;
    const base = API_BASE_URL.replace(/\/$/, '');
    const endpoint = `${base}/health`;

    const check = async () => {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 2500);
      try {
        const response = await fetch(endpoint, {
          method: 'GET',
          cache: 'no-store',
          signal: controller.signal,
        });
        if (!cancelled) {
          if (response.ok) {
            markApiOnline();
          } else {
            markApiOffline();
          }
        }
      } catch (error) {
        if (!cancelled) {
            markApiOffline();
        }
      } finally {
        clearTimeout(timeout);
      }
    };

    check();
    const interval = setInterval(check, 15000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [client, markApiOffline, markApiOnline]);

  // Cleanup old cache on mount and load cached jobs from backend when supported
  useEffect(() => {
    const loadJobs = async () => {
      const localFallback = (shouldMarkOffline: boolean = true) => {
        const localJobs = conversionCache.listAll();
        setCachedJobs(localJobs.map(job => ({
          jobId: job.jobId,
          fileName: job.fileName,
          timestamp: job.timestamp,
          engine: job.state?.engine,
          voice: job.state?.voice,
          language: job.state?.language ?? job.state?.summary?.detectedLanguage,
        })));
        if (shouldMarkOffline) {
          markApiOffline();
        }
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
          return;
        }

        setCachedJobs(backendJobs.map(job => ({
          jobId: job.jobId,
          fileName: job.fileName || job.bookTitle || 'Livro Desconhecido',
          timestamp: job.savedAt ? new Date(job.savedAt).getTime() : Date.now(),
          engine: job.engine,
          voice: job.voice,
          language: job.language,
        })));

        const backendJobIds = new Set(backendJobs.map(j => j.jobId));
        conversionCache.listAll().forEach((localJob) => {
          if (!backendJobIds.has(localJob.jobId)) {
            conversionCache.remove(localJob.jobId);
          }
        });
        markApiOnline();
      } catch (error) {
        console.warn('[useConversionFlow] Failed to load resumable jobs:', error);
        localFallback();
      }
    };

    loadJobs();
  }, [api, apiAvailable, markApiOffline, markApiOnline]);

  useEffect(() => {
    let cancelled = false;
    if (!api.getRecentJobs || !apiAvailable) {
      setRecentJobs([]);
      return () => {
        cancelled = true;
      };
    }
    const fetchRecent = async () => {
      try {
        const jobs = await api.getRecentJobs?.();
        if (!cancelled && Array.isArray(jobs)) {
          setRecentJobs(jobs);
          markApiOnline();
        }
      } catch (error) {
        console.warn('[useConversionFlow] Failed to load recent jobs:', error);
        markApiOffline();
      }
    };
    fetchRecent();
    const interval = setInterval(fetchRecent, 15000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [api, apiAvailable, markApiOffline, markApiOnline]);

  const resetLogAndCounters = useCallback(() => {
    entryFactoryRef.current = createStatusEntryFactory();
    seenEventsRef.current = new Set<string>();
  }, []);

  const reset = useCallback(() => {
    const controller = abortRef.current;
    if (controller && typeof controller.abort === 'function') {
      controller.abort();
    }
    abortRef.current = null;
    resetLogAndCounters();
    startTimeRef.current = null;
    dispatch({ type: 'reset' });
  }, [resetLogAndCounters]);

  const runConversion = useCallback(
    async (
      values: ConversionFormValues,
      batchMeta?: { index: number; total: number },
    ): Promise<'success' | 'failed' | 'cancelled'> => {
      if (!apiAvailable) {
        dispatch({
          type: 'fail',
          error: t.flow.backendOffline,
          entry: entryFactoryRef.current(t.flow.backendOfflineDetails),
        });
        return 'failed';
      }
      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;
      resetLogAndCounters();
      startTimeRef.current = Date.now();
      const originalFileName = values.file?.name ?? values.fileName ?? '';
      fileNameRef.current = originalFileName;
      const requestValues = values.uploadId
        ? { ...values, file: null }
        : values;
      const startMessage = values.uploadId ? t.flow.startReuse : t.flow.startUpload;
      const label = batchMeta && batchMeta.total > 1
        ? `${t.flow.batchPosition(batchMeta.index, batchMeta.total)} • ${startMessage}`
        : startMessage;

      // Generate CLI command
      const cliCommand = buildCliCommand(values);

      dispatch({ type: 'start', entry: entryFactoryRef.current(label), cliCommand });
      try {
        const { jobId } = await api.submit(requestValues);
        markApiOnline();
        dispatch({
          type: 'job-created',
          jobId,
          entry: entryFactoryRef.current(t.flow.jobCreated(jobId)),
        });

        const finalSnapshot = await api.poll(jobId, {
          signal: controller.signal,
          onSnapshot(snapshot) {
            const etaSeconds = estimateEtaSeconds(snapshot, startTimeRef.current);
            applySnapshotMeta(snapshot, etaSeconds);
            appendSnapshotEvents(snapshot.events);

            // Save to cache periodically during conversion
            if (snapshot.state === 'running' || snapshot.state === 'queued') {
              conversionCache.save(jobId, fileNameRef.current, state);
            }
          },
        });

        if (finalSnapshot.state === 'cancelled') {
          dispatch({
            type: 'cancelled',
            error: t.flow.cancelled,
            entry: entryFactoryRef.current(t.flow.cancelled),
          });
          persistCancelledJob(jobId);
          startTimeRef.current = null;
          return 'cancelled';
        }

        if (finalSnapshot.state === 'failed') {
          const failureMessage = finalSnapshot.error || t.flow.defaultFailure;
          dispatch({
            type: 'fail',
            error: failureMessage,
            entry: entryFactoryRef.current(t.flow.failure(failureMessage)),
          });
          startTimeRef.current = null;
          return 'failed';
        }

        const downloads = finalSnapshot.outputs ?? [];
        // Count only MP3 files (exclude ZIP)
        const chapterCount = downloads.filter(d => d.name.toLowerCase().endsWith('.mp3')).length;

        const summaryUpdate: ConversionSummary = {};
        if (typeof finalSnapshot.chaptersCompleted === 'number') {
          summaryUpdate.chaptersCompleted = finalSnapshot.chaptersCompleted;
        } else if (chapterCount > 0) {
          summaryUpdate.chaptersCompleted = chapterCount;
        }
        if (typeof finalSnapshot.chaptersTotal === 'number') {
          summaryUpdate.chaptersTotal = finalSnapshot.chaptersTotal;
        } else if (chapterCount > 0) {
          summaryUpdate.chaptersTotal = chapterCount;
        }
        if (Array.isArray(finalSnapshot.chapterProgress)) {
          summaryUpdate.chapterProgress = finalSnapshot.chapterProgress.map(entry => ({ ...entry }));
        }
        if (finalSnapshot.statusHint) {
          summaryUpdate.statusHint = finalSnapshot.statusHint;
        }
        if (typeof finalSnapshot.parallelSlots === 'number') {
          summaryUpdate.parallelSlots = finalSnapshot.parallelSlots;
        }
        if (typeof finalSnapshot.parallelActive === 'number') {
          summaryUpdate.parallelActive = finalSnapshot.parallelActive;
        }
        summaryUpdate.progressPercent = 100;
        const detailUpdate: Partial<Pick<ConversionState, 'bookTitle' | 'bookAuthor' | 'coverUrl'>> = {};
        if (finalSnapshot.bookTitle) detailUpdate.bookTitle = finalSnapshot.bookTitle;
        if (finalSnapshot.bookAuthor) detailUpdate.bookAuthor = finalSnapshot.bookAuthor;
        if (finalSnapshot.coverUrl) detailUpdate.coverUrl = finalSnapshot.coverUrl;
        const hasDetails = Object.values(detailUpdate).some((value) => value !== undefined);
        dispatch({
          type: 'update-meta',
          etaSeconds: 0,
          summary: summaryUpdate,
          details: hasDetails ? detailUpdate : undefined,
          rawLog: finalSnapshot.rawLog,
        });
        dispatch({
          type: 'complete',
          downloads,
          entry: entryFactoryRef.current(t.flow.completion(chapterCount)),
        });
        // Clear cache on successful completion
        conversionCache.remove(jobId);
        startTimeRef.current = null;
        return 'success';
      } catch (error) {
        if (isNetworkError(error)) {
          markApiOffline();
        }
        if (error instanceof DOMException && error.name === 'AbortError') {
          return 'cancelled';
        }
        const message = error instanceof Error && error.message ? error.message : t.flow.defaultError;
        dispatch({
          type: 'fail',
          error: message,
          entry: entryFactoryRef.current(t.flow.error(message)),
        });
        startTimeRef.current = null;
        return 'failed';
      }
    },
    [api, apiAvailable, applySnapshotMeta, appendSnapshotEvents, markApiOffline, markApiOnline, persistCancelledJob, resetLogAndCounters, state, t],
  );

  const drainQueue = useCallback(async () => {
    if (queueActiveRef.current) {
      return;
    }
    queueActiveRef.current = true;
    try {
      while (jobQueueRef.current.length > 0) {
        const currentJob = jobQueueRef.current.shift();
        if (!currentJob) {
          break;
        }
        const currentIndex = processedCountRef.current + 1;
        const total = currentIndex + jobQueueRef.current.length;
        const meta = total > 1 ? { index: currentIndex, total } : undefined;
        const result = await runConversion(currentJob, meta);
        if (result === 'cancelled') {
          jobQueueRef.current = [];
          break;
        }
        processedCountRef.current += 1;
      }
    } finally {
      queueActiveRef.current = false;
      processedCountRef.current = 0;
    }
  }, [runConversion]);

  const submit = useCallback(
    async (values: ConversionFormValues, options?: SubmitBatchOptions) => {
      const queue = [values, ...(options?.batchQueue ?? [])].filter(Boolean);
      if (queue.length === 0) {
        return;
      }
      jobQueueRef.current = queue;
      processedCountRef.current = 0;
      await drainQueue();
    },
    [drainQueue],
  );

  const enqueue = useCallback(
    async (jobs: ConversionFormValues[]) => {
      const normalized = jobs.filter(Boolean);
      if (normalized.length === 0) {
        return;
      }
      jobQueueRef.current.push(...normalized);
      if (!queueActiveRef.current) {
        processedCountRef.current = 0;
        await drainQueue();
      }
    },
    [drainQueue],
  );

  const resume = useCallback(
    async (jobId: string) => {
      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;

      resetLogAndCounters();

      const cached = conversionCache.load(jobId);
      if (cached) {
        fileNameRef.current = cached.fileName;
        if (Array.isArray(cached.state.log)) {
          cached.state.log.forEach((entry) => {
            seenEventsRef.current.add(entry.message);
            dispatch({ type: 'append-entry', entry });
          });
        }
        if (cached.state.summary || cached.state.bookTitle || cached.state.bookAuthor || cached.state.coverUrl) {
          dispatch({
            type: 'update-meta',
            summary: cached.state.summary,
            details: {
              bookTitle: cached.state.bookTitle,
              bookAuthor: cached.state.bookAuthor,
              coverUrl: cached.state.coverUrl,
            },
            rawLog: cached.state.rawLog,
          });
        }
      }

      if (!apiAvailable) {
        dispatch({
          type: 'fail',
          error: t.flow.backendOffline,
          entry: entryFactoryRef.current(t.flow.backendOfflineDetails),
        });
        startTimeRef.current = null;
        return;
      }

      dispatch({
        type: 'job-created',
        jobId,
        entry: entryFactoryRef.current(t.flow.resuming),
      });

      startTimeRef.current = Date.now();

      let initialSnapshot: JobSnapshot | null = null;
      try {
        initialSnapshot = await api.fetch(jobId);
        markApiOnline();
      } catch (error) {
        if (error instanceof Error && error.message.includes('404')) {
          markApiOnline();
          dispatch({
            type: 'fail',
            error: 'Conversão não encontrada',
            entry: entryFactoryRef.current('Esta conversão não existe mais no servidor. Ela pode ter sido removida ou expirou.'),
          });
          setCachedJobs(prev => prev.filter(j => j.jobId !== jobId));
          conversionCache.remove(jobId);
          startTimeRef.current = null;
          return;
        } else if (isNetworkError(error)) {
          markApiOffline();
        }
        console.warn('[useConversionFlow] Failed to fetch job from backend:', error);
      }

      if (!initialSnapshot) {
        dispatch({
          type: 'fail',
          error: 'Não foi possível recuperar o estado da conversão',
          entry: entryFactoryRef.current('Servidor não retornou nenhuma informação sobre esta conversão.'),
        });
        startTimeRef.current = null;
        return;
      }

      if (!fileNameRef.current) {
        fileNameRef.current = initialSnapshot.bookTitle || cached?.fileName || 'Livro';
      }

      appendSnapshotEvents(initialSnapshot.events);
      applySnapshotMeta(initialSnapshot);

      if (initialSnapshot.state === 'interrupted') {
        const message = initialSnapshot.error || 'Conversão interrompida';
        dispatch({
          type: 'fail',
          error: message,
          entry: entryFactoryRef.current(message),
        });
        setCachedJobs(prev => prev.filter(j => j.jobId !== jobId));
        conversionCache.remove(jobId);
        startTimeRef.current = null;
        return;
      }

      if (initialSnapshot.state === 'finished') {
        const downloads = initialSnapshot.outputs ?? [];
        const chapterCount = downloads.filter(d => d.name.toLowerCase().endsWith('.mp3')).length;
        dispatch({
          type: 'complete',
          downloads,
          entry: entryFactoryRef.current(t.flow.completion(chapterCount)),
        });
        conversionCache.remove(jobId);
        setCachedJobs(prev => prev.filter(j => j.jobId !== jobId));
        startTimeRef.current = null;
        return;
      }

      if (initialSnapshot.state === 'failed') {
        const failureMessage = initialSnapshot.error || t.flow.defaultFailure;
        dispatch({
          type: 'fail',
          error: failureMessage,
          entry: entryFactoryRef.current(t.flow.failure(failureMessage)),
        });
        setCachedJobs(prev => prev.filter(j => j.jobId !== jobId));
        conversionCache.remove(jobId);
        startTimeRef.current = null;
        return;
      }

      if (api.resume && initialSnapshot.state !== 'running' && initialSnapshot.state !== 'cancelling') {
        try {
          await api.resume(jobId);
          markApiOnline();
        } catch (error) {
          if (isNetworkError(error)) {
            markApiOffline();
          }
          const message = error instanceof Error && error.message ? error.message : t.flow.defaultFailure;
          dispatch({
            type: 'fail',
            error: message,
            entry: entryFactoryRef.current(t.flow.failure(message)),
          });
          startTimeRef.current = null;
          return;
        }
      }

      try {
        const finalSnapshot = await api.poll(jobId, {
          signal: controller.signal,
          onSnapshot(snapshot) {
            markApiOnline();
            const etaSeconds = estimateEtaSeconds(snapshot, startTimeRef.current);
            applySnapshotMeta(snapshot, etaSeconds);
            appendSnapshotEvents(snapshot.events);

            if (snapshot.state === 'running' || snapshot.state === 'queued') {
              conversionCache.save(jobId, fileNameRef.current, state);
            }
          },
        });

        if (finalSnapshot.state === 'cancelled') {
          dispatch({
            type: 'cancelled',
            error: t.flow.cancelled,
            entry: entryFactoryRef.current(t.flow.cancelled),
          });
          persistCancelledJob(jobId);
          startTimeRef.current = null;
          return;
        }

        if (finalSnapshot.state === 'failed' || finalSnapshot.state === 'interrupted') {
          const failureMessage = finalSnapshot.error || t.flow.defaultFailure;
          dispatch({
            type: 'fail',
            error: failureMessage,
            entry: entryFactoryRef.current(t.flow.failure(failureMessage)),
          });
          setCachedJobs(prev => prev.filter(j => j.jobId !== jobId));
          startTimeRef.current = null;
          return;
        }

        const downloads = finalSnapshot.outputs ?? [];
        const chapterCount = downloads.filter(d => d.name.toLowerCase().endsWith('.mp3')).length;
        applySnapshotMeta(finalSnapshot, 0);
        dispatch({
          type: 'complete',
          downloads,
          entry: entryFactoryRef.current(t.flow.completion(chapterCount)),
        });
        conversionCache.remove(jobId);
        setCachedJobs(prev => prev.filter(j => j.jobId !== jobId));
        startTimeRef.current = null;
      } catch (error) {
        if (error instanceof DOMException && error.name === 'AbortError') {
          return;
        }
        const message = error instanceof Error && error.message ? error.message : t.flow.defaultError;
        if (isNetworkError(error)) {
          markApiOffline();
        }
        dispatch({
          type: 'fail',
          error: message,
          entry: entryFactoryRef.current(t.flow.error(message)),
        });
        startTimeRef.current = null;
      }
    },
    [api, apiAvailable, applySnapshotMeta, appendSnapshotEvents, markApiOffline, markApiOnline, persistCancelledJob, resetLogAndCounters, setCachedJobs, state, t],
  );

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
      persistCancelledJob(state.jobId);
    }

    jobQueueRef.current = [];
    processedCountRef.current = 0;

    const jobId = state.jobId;
    const cancelFn = api?.cancel;
    if (jobId && typeof cancelFn === 'function') {
      void (async () => {
        try {
          await cancelFn(jobId);
        } catch (error) {
          const message = error instanceof Error && error.message
            ? error.message
            : t.flow.cancelFailed('');
          dispatch({
            type: 'append-entry',
            entry: entryFactoryRef.current(t.flow.cancelFailed(message)),
          });
        }
      })();
    }

    return true;
  }, [api, persistCancelledJob, state.jobId, state.phase, t]);

  const cancelJobById = useCallback(async (jobId: string) => {
    if (!jobId || !api.cancel || !apiAvailable) {
      return;
    }
    try {
      await api.cancel(jobId);
    } catch (error) {
      console.warn('[useConversionFlow] Failed to cancel cached job', jobId, error);
    } finally {
      setCachedJobs(prev => prev.filter(job => job.jobId !== jobId));
      conversionCache.remove(jobId);
    }
  }, [api, apiAvailable]);

  const removeCachedJob = useCallback((jobId: string) => {
    setCachedJobs(prev => prev.filter(job => job.jobId !== jobId));
    conversionCache.remove(jobId);
  }, []);

  const uploadFile = useCallback(async (file: File) => {
    if (!apiAvailable) {
      throw new Error(t.flow.backendOffline);
    }
    if (!api.upload) {
      throw new Error('Upload não suportado pelo cliente atual');
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
  }, [api, apiAvailable, markApiOffline, markApiOnline, t]);

  const isBusy = state.phase === 'submitting' || state.phase === 'polling' || state.phase === 'cancelling';

  return {
    state,
    submit,
    enqueue,
    resume,
    reset,
    cancel,
    cancelJobById,
    removeCachedJob,
    uploadFile,
    isBusy,
    cachedJobs,
    recentJobs,
    apiAvailable,
    healthStatus,
  };
}
