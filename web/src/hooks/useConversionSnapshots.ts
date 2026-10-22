import { useCallback } from 'react';
import { conversionCache } from '../services/ConversionCache';
import { ConversionState, JobSnapshot, ConversionSummary } from '../types/conversion';
import { pingBackendHealth } from './conversion_runtime_health';
import type { ConversionStateScope } from './useConversionState';

type ConversionSnapshotsInput = Pick<
  ConversionStateScope,
  | 'stateRef'
  | 'saveStateWithQueue'
  | 'fileNameRef'
  | 'streamStatusRef'
  | 'fallbackPollAbortRef'
  | 'restartGraceRef'
  | 'healthFailureCountRef'
  | 'pollFailureCountRef'
  | 'setApiAvailable'
  | 'setHealthStatus'
  | 'isRestartGraceActive'
  | 'adaptiveTolerancesRef'
  | 'state'
  | 'lastSnapshotAtRef'
  | 'api'
  | 'seenEventsRef'
  | 'dispatch'
  | 'entryFactoryRef'
  | 'setCachedJobs'
  | 'apiAvailable'
>;

export function useConversionSnapshots({
  stateRef,
  saveStateWithQueue,
  fileNameRef,
  streamStatusRef,
  fallbackPollAbortRef,
  restartGraceRef,
  healthFailureCountRef,
  pollFailureCountRef,
  setApiAvailable,
  setHealthStatus,
  isRestartGraceActive,
  adaptiveTolerancesRef,
  state,
  lastSnapshotAtRef,
  api,
  seenEventsRef,
  dispatch,
  entryFactoryRef,
  setCachedJobs,
  apiAvailable,
}: ConversionSnapshotsInput) {
  const saveSnapshotToCache = (jobId: string, snapshot: JobSnapshot) => {
    const currentState = stateRef.current;
    const progressPercent =
      typeof snapshot.progressPercent === 'number'
        ? snapshot.progressPercent
        : typeof snapshot.progress === 'number'
          ? snapshot.progress * 100
          : undefined;
    const summary =
      progressPercent === undefined
        ? currentState.summary
        : {
            ...currentState.summary,
            progressPercent: Math.max(currentState.summary?.progressPercent ?? 0, progressPercent),
          };
    saveStateWithQueue(jobId, fileNameRef.current, {
      ...currentState,
      phase: 'polling',
      jobId,
      summary,
    });
  };

  const onStreamStatus = useCallback((status: 'connecting' | 'healthy' | 'fallback') => {
    streamStatusRef.current = status;
    if (status === 'healthy') {
      fallbackPollAbortRef.current?.abort();
      fallbackPollAbortRef.current = null;
    }
  }, []);

  const markApiOnline = useCallback(() => {
    restartGraceRef.current = null;
    healthFailureCountRef.current = 0;
    pollFailureCountRef.current = 0;
    setApiAvailable(true);
    setHealthStatus('ok');
  }, []);
  const markApiOffline = useCallback(() => {
    setApiAvailable(false);
    if (isRestartGraceActive()) {
      setHealthStatus('restarting');
      return;
    }
    setHealthStatus('fail');
  }, [isRestartGraceActive]);
  const shouldMarkOffline = useCallback(() => {
    const graceMs = adaptiveTolerancesRef.current.activeSnapshotGraceMs;
    if (state.phase === 'polling' || state.phase === 'submitting') {
      const lastSnapshotAt = lastSnapshotAtRef.current;
      if (lastSnapshotAt && Date.now() - lastSnapshotAt < graceMs) {
        return false;
      }
    }
    return true;
  }, [state.phase]);
  const waitForBackendReady = useCallback(async () => {
    if (api.mode === 'embedded') return true;
    const tolerances = adaptiveTolerancesRef.current;
    const maxAttempts = Math.max(3, tolerances.healthFailureLimit + 2);
    for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
      const ok = await pingBackendHealth(tolerances.healthPingTimeoutMs);
      if (ok) {
        markApiOnline();
        return true;
      }
      const retryDelay = Math.min(
        Math.max(1500, Math.round(tolerances.healthCheckTimeoutMs * 0.8)) + attempt * 500,
        8000,
      );
      await new Promise((resolve) => setTimeout(resolve, retryDelay));
    }
    markApiOffline();
    return false;
  }, [api, markApiOffline, markApiOnline]);
  const appendSnapshotEvents = useCallback(
    (events?: string[]) => {
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
    },
    [dispatch],
  );

  const applySnapshotMeta = useCallback(
    (snapshot: JobSnapshot, etaSeconds?: number | null) => {
      lastSnapshotAtRef.current = Date.now();
      const summaryUpdate: ConversionSummary = {};
      if (snapshot.detectedLanguage) summaryUpdate.detectedLanguage = snapshot.detectedLanguage;
      if (typeof snapshot.chaptersTotal === 'number')
        summaryUpdate.chaptersTotal = snapshot.chaptersTotal;
      if (typeof snapshot.chaptersCompleted === 'number')
        summaryUpdate.chaptersCompleted = snapshot.chaptersCompleted;
      if (snapshot.currentChapter) summaryUpdate.currentChapter = snapshot.currentChapter;
      if (snapshot.statusHint) summaryUpdate.statusHint = snapshot.statusHint;
      if (Array.isArray(snapshot.chapterProgress)) {
        summaryUpdate.chapterProgress = snapshot.chapterProgress.map((entry) => ({ ...entry }));
      }
      if (typeof snapshot.parallelSlots === 'number')
        summaryUpdate.parallelSlots = snapshot.parallelSlots;
      if (typeof snapshot.parallelActive === 'number')
        summaryUpdate.parallelActive = snapshot.parallelActive;
      if (snapshot.engineStatus) summaryUpdate.engineStatus = snapshot.engineStatus;
      const percentFromSnapshot =
        typeof snapshot.progressPercent === 'number'
          ? snapshot.progressPercent
          : typeof snapshot.progress === 'number'
            ? snapshot.progress * 100
            : undefined;
      if (typeof percentFromSnapshot === 'number')
        summaryUpdate.progressPercent = percentFromSnapshot;

      const detailUpdate: Partial<
        Pick<
          ConversionState,
          | 'bookTitle'
          | 'bookAuthor'
          | 'coverUrl'
          | 'engine'
          | 'voice'
          | 'language'
          | 'uiLanguage'
          | 'speakFormattingCues'
        >
      > = {};
      if (snapshot.bookTitle) detailUpdate.bookTitle = snapshot.bookTitle;
      if (snapshot.bookAuthor) detailUpdate.bookAuthor = snapshot.bookAuthor;
      if (snapshot.coverUrl) detailUpdate.coverUrl = snapshot.coverUrl;
      if (snapshot.engine) detailUpdate.engine = snapshot.engine;
      if (snapshot.voice) detailUpdate.voice = snapshot.voice;
      if (snapshot.language) detailUpdate.language = snapshot.language;
      if (snapshot.uiLanguage) detailUpdate.uiLanguage = snapshot.uiLanguage;
      if (typeof snapshot.formattingCues === 'boolean')
        detailUpdate.speakFormattingCues = snapshot.formattingCues;

      const hasSummary = Object.values(summaryUpdate).some((value) => value !== undefined);
      const hasDetails = Object.values(detailUpdate).some((value) => value !== undefined);
      const timestampUpdate: Partial<
        Pick<ConversionState, 'startedAt' | 'completedAt' | 'totalDurationSeconds'>
      > = {};
      if (snapshot.startedAt) {
        timestampUpdate.startedAt = snapshot.startedAt;
      }
      if (snapshot.completedAt) {
        timestampUpdate.completedAt = snapshot.completedAt;
      }
      if (typeof snapshot.totalElapsedSeconds === 'number') {
        timestampUpdate.totalDurationSeconds = snapshot.totalElapsedSeconds;
      }
      const hasTimestamps = Object.keys(timestampUpdate).length > 0;

      dispatch({
        type: 'update-meta',
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
      setCachedJobs((prev) => prev.filter((job) => !job.jobId.startsWith(jobId)));
      const removeFn = api?.removeJob;
      if (removeFn && apiAvailable) {
        void (async () => {
          try {
            await removeFn.call(api, jobId);
          } catch (error) {
            console.warn(
              '[useConversionFlow] Failed to purge cancelled job on backend',
              jobId,
              error,
            );
          }
        })();
      }
    },
    [api, apiAvailable, setCachedJobs],
  );

  return {
    markApiOnline,
    markApiOffline,
    appendSnapshotEvents,
    applySnapshotMeta,
    shouldMarkOffline,
    waitForBackendReady,
    onStreamStatus,
    saveSnapshotToCache,
    clearCancelledJob,
  };
}

export type ConversionSnapshotsScope = ReturnType<typeof useConversionSnapshots>;
