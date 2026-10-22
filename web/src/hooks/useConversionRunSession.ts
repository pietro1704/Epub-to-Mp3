import { buildCliReproduction } from '../utils/cliReproduction';
import { useCallback } from 'react';
import { conversionCache } from '../services/ConversionCache';
import { ConversionFormValues, ConversionState, ConversionSummary } from '../types/conversion';
import { createStatusEntryFactory } from './conversion_state';
import { estimateEtaSeconds } from './conversion_eta';
import { isNetworkError, fetchInitialJobSnapshot } from './conversion_runtime_health';
import type { ConversionStateScope } from './useConversionState';
import type { ConversionSnapshotsScope } from './useConversionSnapshots';

type ConversionRunSessionInput = Pick<
  ConversionStateScope,
  | 'entryFactoryRef'
  | 'seenEventsRef'
  | 'abortRef'
  | 'lastSnapshotAtRef'
  | 'startTimeRef'
  | 'dispatch'
  | 'apiAvailable'
  | 't'
  | 'fileNameRef'
  | 'api'
  | 'state'
  | 'queueGenerationRef'
  | 'jobQueueRef'
  | 'queueActiveRef'
  | 'skipModeRef'
  | 'syncQueueSnapshot'
  | 'setQueuePaused'
> &
  Pick<
    ConversionSnapshotsScope,
    | 'waitForBackendReady'
    | 'markApiOnline'
    | 'appendSnapshotEvents'
    | 'applySnapshotMeta'
    | 'markApiOffline'
    | 'onStreamStatus'
    | 'saveSnapshotToCache'
    | 'clearCancelledJob'
  >;

export function useConversionRunSession({
  queueGenerationRef,
  jobQueueRef,
  queueActiveRef,
  skipModeRef,
  syncQueueSnapshot,
  setQueuePaused,
  entryFactoryRef,
  seenEventsRef,
  abortRef,
  lastSnapshotAtRef,
  startTimeRef,
  dispatch,
  apiAvailable,
  t,
  waitForBackendReady,
  fileNameRef,
  api,
  markApiOnline,
  appendSnapshotEvents,
  applySnapshotMeta,
  markApiOffline,
  onStreamStatus,
  saveSnapshotToCache,
  clearCancelledJob,
  state,
}: ConversionRunSessionInput) {
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
    lastSnapshotAtRef.current = null;
    startTimeRef.current = null;
    // Reset invalidates the queue owner as well as the pending request.
    queueGenerationRef.current += 1;
    jobQueueRef.current = [];
    queueActiveRef.current = false;
    skipModeRef.current = false;
    setQueuePaused(false);
    syncQueueSnapshot();
    conversionCache.clearPendingBatch();
    dispatch({ type: 'reset' });
  }, [resetLogAndCounters]);

  const runConversion = useCallback(
    async (
      values: ConversionFormValues,
      batchMeta?: { index: number; total: number },
    ): Promise<'success' | 'failed' | 'cancelled'> => {
      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;
      // Only this immutable request identity may publish state or artifacts.
      const isCurrent = () => abortRef.current === controller && !controller.signal.aborted;
      if (!apiAvailable) {
        dispatch({
          type: 'append-entry',
          entry: entryFactoryRef.current(t.flow.backendConnecting),
        });
        const ready = await waitForBackendReady();
        if (!isCurrent()) return 'cancelled';
        if (!ready) {
          dispatch({
            type: 'fail',
            error: t.flow.backendOffline,
            entry: entryFactoryRef.current(t.flow.backendOfflineDetails),
          });
          return 'failed';
        }
      }
      resetLogAndCounters();
      lastSnapshotAtRef.current = null;
      startTimeRef.current = Date.now();
      const startedAtIso = new Date().toISOString();
      const originalFileName = values.file?.name ?? values.fileName ?? '';
      fileNameRef.current = originalFileName;
      const requestValues =
        values.uploadId && values.uploadId.trim().length > 0 ? { ...values, file: null } : values;
      const startMessage = values.uploadId ? t.flow.startReuse : t.flow.startUpload;
      const label =
        batchMeta && batchMeta.total > 1
          ? `${t.flow.batchPosition(batchMeta.index, batchMeta.total)} • ${startMessage}`
          : startMessage;

      // Generate CLI command
      const recipe = buildCliReproduction(values);

      dispatch({
        type: 'start',
        entry: entryFactoryRef.current(label),
        cliCommand: recipe?.command,
        cliShell: recipe?.shell,
        startedAt: startedAtIso,
      });
      if (values.bookTitle || values.bookAuthor || values.coverUrl) {
        dispatch({
          type: 'update-meta',
          details: {
            bookTitle: values.bookTitle,
            bookAuthor: values.bookAuthor,
            coverUrl: values.coverUrl,
          },
        });
      }
      try {
        const { jobId } = await api.submit(requestValues);
        if (!isCurrent()) return 'cancelled';
        markApiOnline();
        dispatch({
          type: 'job-created',
          jobId,
          entry: entryFactoryRef.current(t.flow.jobCreated(jobId)),
        });

        try {
          const initialSnapshot = await fetchInitialJobSnapshot(api, jobId, isCurrent);
          if (!isCurrent()) return 'cancelled';
          if (initialSnapshot) {
            lastSnapshotAtRef.current = Date.now();
            appendSnapshotEvents(initialSnapshot.events);
            const etaSeconds = estimateEtaSeconds(initialSnapshot, startTimeRef.current);
            applySnapshotMeta(initialSnapshot, etaSeconds);
          }
        } catch (error) {
          if (!isCurrent()) return 'cancelled';
          if (isNetworkError(error)) {
            markApiOffline();
          }
        }

        const finalSnapshot = await api.poll(jobId, {
          signal: controller.signal,
          onStreamStatus: (status) => {
            if (isCurrent()) onStreamStatus(status);
          },
          onSnapshot(snapshot) {
            if (!isCurrent() || snapshot.jobId !== jobId) return;
            const etaSeconds = estimateEtaSeconds(snapshot, startTimeRef.current);
            applySnapshotMeta(snapshot, etaSeconds);
            appendSnapshotEvents(snapshot.events);
            saveSnapshotToCache(jobId, snapshot);
          },
        });

        if (!isCurrent()) return 'cancelled';
        if (finalSnapshot.state === 'cancelled') {
          dispatch({
            type: 'cancelled',
            error: t.flow.cancelled,
            entry: entryFactoryRef.current(t.flow.cancelled),
          });
          clearCancelledJob(jobId);
          startTimeRef.current = null;
          return 'cancelled';
        }

        if (finalSnapshot.state === 'failed') {
          const failureMessage = finalSnapshot.error || t.flow.defaultFailure;
          dispatch({
            type: 'fail',
            error: failureMessage,
            errorCategory: finalSnapshot.errorCategory,
            entry: entryFactoryRef.current(t.flow.failure(failureMessage)),
          });
          startTimeRef.current = null;
          return 'failed';
        }

        const downloads = finalSnapshot.outputs ?? [];
        // Count only MP3 files (exclude ZIP)
        const chapterCount = downloads.filter((d) => d.name.toLowerCase().endsWith('.mp3')).length;

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
          summaryUpdate.chapterProgress = finalSnapshot.chapterProgress.map((entry) => ({
            ...entry,
          }));
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
        const detailUpdate: Partial<
          Pick<ConversionState, 'bookTitle' | 'bookAuthor' | 'coverUrl'>
        > = {};
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
        const completedAtIso = finalSnapshot.completedAt ?? new Date().toISOString();
        const totalElapsedSeconds =
          typeof finalSnapshot.totalElapsedSeconds === 'number'
            ? Math.max(0, Math.round(finalSnapshot.totalElapsedSeconds))
            : startTimeRef.current
              ? Math.max(0, Math.round((Date.now() - startTimeRef.current) / 1000))
              : undefined;
        dispatch({
          type: 'complete',
          downloads,
          entry: entryFactoryRef.current(t.flow.completion(chapterCount)),
          completedAt: completedAtIso,
          totalDurationSeconds: totalElapsedSeconds,
        });
        // Clear cache on successful completion
        conversionCache.remove(jobId);
        startTimeRef.current = null;
        return 'success';
      } catch (error) {
        if (!isCurrent()) return 'cancelled';
        if (isNetworkError(error)) {
          markApiOffline();
        }
        if (error instanceof DOMException && error.name === 'AbortError') {
          return 'cancelled';
        }
        const message =
          error instanceof Error && error.message ? error.message : t.flow.defaultError;
        dispatch({
          type: 'fail',
          error: message,
          entry: entryFactoryRef.current(t.flow.error(message)),
        });
        startTimeRef.current = null;
        return 'failed';
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
      onStreamStatus,
      resetLogAndCounters,
      state,
      t,
      waitForBackendReady,
    ],
  );

  return { runConversion, resetLogAndCounters, reset };
}

export type ConversionRunSessionScope = ReturnType<typeof useConversionRunSession>;
