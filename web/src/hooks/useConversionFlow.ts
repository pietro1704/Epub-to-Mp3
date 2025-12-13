import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react';
import { conversionClient, ConversionClient } from '../services/ConversionService';
import { conversionCache } from '../services/ConversionCache';
import {
  ConversionFormValues,
  ConversionState,
  DownloadAsset,
  StatusEntry,
  JobSnapshot,
  ConversionSummary,
} from '../types/conversion';
import { useTranslations } from '../i18n/I18nProvider';

function buildCliCommand(values: ConversionFormValues): string {
  const parts = ['python python_app/convert', values.file.name];

  if (values.engine) {
    parts.push('--engine', values.engine);
  }

  if (values.voice) {
    parts.push('--voice', values.voice);
  }

  if (values.chapters) {
    parts.push('--chapter', values.chapters);
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
  | { type: 'update-meta'; etaSeconds?: number | null; summary?: ConversionSummary };

const initialState: ConversionState = {
  phase: 'idle',
  log: [],
  downloads: [],
  error: undefined,
  jobId: undefined,
  etaSeconds: undefined,
  summary: undefined,
  cliCommand: undefined,
};

function reducer(state: ConversionState, action: Action): ConversionState {
  switch (action.type) {
    case 'reset':
      return { ...initialState };
    case 'start':
      return {
        phase: 'submitting',
        jobId: undefined,
        log: [action.entry],
        downloads: [],
        error: undefined,
        etaSeconds: undefined,
        summary: undefined,
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
      return {
        ...state,
        etaSeconds: typeof action.etaSeconds === 'number' ? Math.max(0, action.etaSeconds) : action.etaSeconds,
        summary: nextSummary,
      };
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
  submit: (values: ConversionFormValues) => Promise<void>;
  resume: (jobId: string) => Promise<void>;
  reset: () => void;
  isBusy: boolean;
  cachedJobs: Array<{ jobId: string; fileName: string; timestamp: number }>;
}

export function useConversionFlow(client?: ConversionClient): UseConversionFlowApi {
  const [state, dispatch] = useReducer(reducer, initialState);
  const api = useMemo(() => client ?? conversionClient, [client]);
  const abortRef = useRef<AbortController | null>(null);
  const seenEventsRef = useRef<Set<string>>(new Set());
  const entryFactoryRef = useRef(createStatusEntryFactory());
  const startTimeRef = useRef<number | null>(null);
  const fileNameRef = useRef<string>('');
  const t = useTranslations();
  const [cachedJobs, setCachedJobs] = useState<Array<{ jobId: string; fileName: string; timestamp: number }>>([]);

  // Cleanup old cache on mount and load cached jobs from both backend and localStorage
  useEffect(() => {
    const loadJobs = async () => {
      // Cleanup old localStorage cache
      conversionCache.cleanup();

      // Try to fetch resumable jobs from backend
      const backendJobs = await api.getResumableJobs?.() || [];

      if (backendJobs.length > 0) {
        // Convert backend jobs to cachedJobs format
        setCachedJobs(backendJobs.map(job => ({
          jobId: job.jobId,
          fileName: job.fileName || job.bookTitle || 'Livro Desconhecido',
          timestamp: job.savedAt ? new Date(job.savedAt).getTime() : Date.now(),
        })));

        // Clean up localStorage jobs that don't exist in backend
        const backendJobIds = new Set(backendJobs.map(j => j.jobId));
        const localJobs = conversionCache.listAll();
        localJobs.forEach(localJob => {
          if (!backendJobIds.has(localJob.jobId)) {
            conversionCache.remove(localJob.jobId);
          }
        });
      } else {
        // Fallback to localStorage cache if backend has no jobs
        // But validate each job still exists in backend
        const cached = conversionCache.listAll();
        const validJobs: Array<{ jobId: string; fileName: string; timestamp: number }> = [];

        for (const c of cached) {
          try {
            // Try to fetch job from backend to validate it exists
            await api.fetch(c.jobId);
            validJobs.push({ jobId: c.jobId, fileName: c.fileName, timestamp: c.timestamp });
          } catch (error) {
            // Job doesn't exist in backend, remove from cache
            console.log(`[useConversionFlow] Removing invalid job from cache: ${c.jobId}`);
            conversionCache.remove(c.jobId);
          }
        }

        setCachedJobs(validJobs);
      }
    };

    loadJobs();
  }, [api]);

  const resetLogAndCounters = useCallback(() => {
    entryFactoryRef.current = createStatusEntryFactory();
    seenEventsRef.current = new Set<string>();
  }, []);

  const reset = useCallback(() => {
    abortRef.current?.abort();
    abortRef.current = null;
    resetLogAndCounters();
    startTimeRef.current = null;
    dispatch({ type: 'reset' });
  }, [resetLogAndCounters]);

  const submit = useCallback(
    async (values: ConversionFormValues) => {
      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;
      resetLogAndCounters();
      startTimeRef.current = Date.now();
      fileNameRef.current = values.file.name;

      // Generate CLI command
      const cliCommand = buildCliCommand(values);

      dispatch({ type: 'start', entry: entryFactoryRef.current(t.flow.start), cliCommand });
      try {
        const { jobId } = await api.submit(values);
        dispatch({
          type: 'job-created',
          jobId,
          entry: entryFactoryRef.current(t.flow.jobCreated(jobId)),
        });

        const finalSnapshot = await api.poll(jobId, {
          signal: controller.signal,
          onSnapshot(snapshot) {
            const etaSeconds = estimateEtaSeconds(snapshot, startTimeRef.current);
            const summaryUpdate: ConversionSummary = {};
            if (snapshot.detectedLanguage) summaryUpdate.detectedLanguage = snapshot.detectedLanguage;
            if (typeof snapshot.chaptersTotal === 'number') summaryUpdate.chaptersTotal = snapshot.chaptersTotal;
            if (typeof snapshot.chaptersCompleted === 'number') {
              summaryUpdate.chaptersCompleted = snapshot.chaptersCompleted;
            }
            if (snapshot.currentChapter) summaryUpdate.currentChapter = snapshot.currentChapter;
            const percentFromSnapshot = typeof snapshot.progressPercent === 'number'
              ? snapshot.progressPercent
              : typeof snapshot.progress === 'number'
                ? snapshot.progress * 100
                : undefined;
            if (typeof percentFromSnapshot === 'number') {
              summaryUpdate.progressPercent = percentFromSnapshot;
            }
            const hasSummary = Object.values(summaryUpdate).some((value) => value !== undefined);
            dispatch({ type: 'update-meta', etaSeconds, summary: hasSummary ? summaryUpdate : undefined });
            snapshot.events?.forEach((event) => {
              if (!seenEventsRef.current.has(event)) {
                seenEventsRef.current.add(event);
                dispatch({
                  type: 'append-entry',
                  entry: entryFactoryRef.current(event),
                });
              }
            });

            // Save to cache periodically during conversion
            if (snapshot.state === 'running' || snapshot.state === 'queued') {
              conversionCache.save(jobId, fileNameRef.current, state);
            }
          },
        });

        if (finalSnapshot.state === 'failed') {
          const failureMessage = finalSnapshot.error || t.flow.defaultFailure;
          dispatch({
            type: 'fail',
            error: failureMessage,
            entry: entryFactoryRef.current(t.flow.failure(failureMessage)),
          });
          startTimeRef.current = null;
          return;
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
        summaryUpdate.progressPercent = 100;
        dispatch({ type: 'update-meta', etaSeconds: 0, summary: summaryUpdate });
        dispatch({
          type: 'complete',
          downloads,
          entry: entryFactoryRef.current(t.flow.completion(chapterCount)),
        });
        // Clear cache on successful completion
        conversionCache.remove(jobId);
        startTimeRef.current = null;
      } catch (error) {
        if (error instanceof DOMException && error.name === 'AbortError') {
          return;
        }
        const message = error instanceof Error && error.message ? error.message : t.flow.defaultError;
        dispatch({
          type: 'fail',
          error: message,
          entry: entryFactoryRef.current(t.flow.error(message)),
        });
        startTimeRef.current = null;
      }
    },
    [api, resetLogAndCounters, t],
  );

  const resume = useCallback(
    async (jobId: string) => {
      // Try to fetch job state from backend first
      let initialSnapshot: JobSnapshot | null = null;
      try {
        initialSnapshot = await api.fetch(jobId);

        // Check if job was interrupted (source file lost)
        if (initialSnapshot.state === 'interrupted') {
          dispatch({
            type: 'fail',
            error: initialSnapshot.error || 'Conversão interrompida',
            entry: entryFactoryRef.current(initialSnapshot.error || 'Conversão foi interrompida e não pode ser retomada'),
          });

          // Show all events from interrupted job
          initialSnapshot.events?.forEach((event) => {
            dispatch({
              type: 'append-entry',
              entry: { id: `event-${Math.random()}`, message: event, timestamp: new Date().toISOString() },
            });
          });

          // Remove from cached jobs list and localStorage
          setCachedJobs(prev => prev.filter(j => j.jobId !== jobId));
          conversionCache.remove(jobId);
          return;
        }
      } catch (error) {
        // If job not found (404), remove from cache and show error
        if (error instanceof Error && error.message.includes('404')) {
          console.warn('[useConversionFlow] Job not found in backend (404):', jobId);

          dispatch({
            type: 'fail',
            error: 'Conversão não encontrada',
            entry: entryFactoryRef.current('Esta conversão não existe mais no servidor. Ela pode ter sido removida ou o servidor foi reiniciado.'),
          });

          // Remove from cached jobs list and localStorage
          setCachedJobs(prev => prev.filter(j => j.jobId !== jobId));
          conversionCache.remove(jobId);
          return;
        }

        console.warn('[useConversionFlow] Failed to fetch job from backend:', error);
      }

      // Fallback to localStorage cache
      const cached = conversionCache.load(jobId);

      // If neither backend nor cache has the job, warn and return
      if (!initialSnapshot && !cached) {
        console.warn('[useConversionFlow] No state found for job:', jobId);
        dispatch({
          type: 'fail',
          error: 'Job não encontrado',
          entry: entryFactoryRef.current('Não foi possível encontrar o estado da conversão'),
        });
        return;
      }

      // Restore state
      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;

      resetLogAndCounters();

      // If we have backend data, use it; otherwise use cache
      if (initialSnapshot) {
        // Use backend state
        fileNameRef.current = initialSnapshot.events?.find(e => e.includes('📜 Título:'))?.replace('📜 Título: ', '') || 'Livro';

        // Dispatch initial events from backend
        initialSnapshot.events?.forEach((event) => {
          seenEventsRef.current.add(event);
          dispatch({
            type: 'append-entry',
            entry: { id: `event-${Math.random()}`, message: event, timestamp: new Date().toISOString() },
          });
        });
      } else if (cached) {
        // Use localStorage cache
        cached.state.log.forEach(entry => {
          seenEventsRef.current.add(entry.message);
        });

        for (const entry of cached.state.log) {
          dispatch({ type: 'append-entry', entry });
        }

        fileNameRef.current = cached.fileName;
      }

      // Set jobId and add resuming message
      dispatch({
        type: 'job-created',
        jobId,
        entry: entryFactoryRef.current(t.flow.resuming),
      });

      startTimeRef.current = Date.now();

      try {
        // Continue polling from where we left off
        const finalSnapshot = await api.poll(jobId, {
          signal: controller.signal,
          onSnapshot(snapshot) {
            const etaSeconds = estimateEtaSeconds(snapshot, startTimeRef.current);
            const summaryUpdate: ConversionSummary = {};
            if (snapshot.detectedLanguage) summaryUpdate.detectedLanguage = snapshot.detectedLanguage;
            if (typeof snapshot.chaptersTotal === 'number') summaryUpdate.chaptersTotal = snapshot.chaptersTotal;
            if (typeof snapshot.chaptersCompleted === 'number') {
              summaryUpdate.chaptersCompleted = snapshot.chaptersCompleted;
            }
            if (snapshot.currentChapter) summaryUpdate.currentChapter = snapshot.currentChapter;
            const percentFromSnapshot = typeof snapshot.progressPercent === 'number'
              ? snapshot.progressPercent
              : typeof snapshot.progress === 'number'
                ? snapshot.progress * 100
                : undefined;
            if (typeof percentFromSnapshot === 'number') {
              summaryUpdate.progressPercent = percentFromSnapshot;
            }
            const hasSummary = Object.values(summaryUpdate).some((value) => value !== undefined);
            dispatch({ type: 'update-meta', etaSeconds, summary: hasSummary ? summaryUpdate : undefined });
            snapshot.events?.forEach((event) => {
              if (!seenEventsRef.current.has(event)) {
                seenEventsRef.current.add(event);
                dispatch({
                  type: 'append-entry',
                  entry: entryFactoryRef.current(event),
                });
              }
            });

            // Save to cache periodically during conversion
            if (snapshot.state === 'running' || snapshot.state === 'queued') {
              conversionCache.save(jobId, fileNameRef.current, state);
            }
          },
        });

        if (finalSnapshot.state === 'failed' || finalSnapshot.state === 'interrupted') {
          const failureMessage = finalSnapshot.error || t.flow.defaultFailure;
          dispatch({
            type: 'fail',
            error: failureMessage,
            entry: entryFactoryRef.current(t.flow.failure(failureMessage)),
          });
          startTimeRef.current = null;
          // Remove from cached jobs list
          setCachedJobs(prev => prev.filter(j => j.jobId !== jobId));
          return;
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
        summaryUpdate.progressPercent = 100;
        dispatch({ type: 'update-meta', etaSeconds: 0, summary: summaryUpdate });
        dispatch({
          type: 'complete',
          downloads,
          entry: entryFactoryRef.current(t.flow.completion(chapterCount)),
        });
        // Clear cache on successful completion
        conversionCache.remove(jobId);
        setCachedJobs(prev => prev.filter(j => j.jobId !== jobId));
        startTimeRef.current = null;
      } catch (error) {
        if (error instanceof DOMException && error.name === 'AbortError') {
          return;
        }
        const message = error instanceof Error && error.message ? error.message : t.flow.defaultError;
        dispatch({
          type: 'fail',
          error: message,
          entry: entryFactoryRef.current(t.flow.error(message)),
        });
        startTimeRef.current = null;
      }
    },
    [api, resetLogAndCounters, state, t],
  );

  useEffect(() => {
    return () => {
      abortRef.current?.abort();
    };
  }, []);

  const isBusy = state.phase === 'submitting' || state.phase === 'polling';

  return {
    state,
    submit,
    resume,
    reset,
    isBusy,
    cachedJobs,
  };
}
