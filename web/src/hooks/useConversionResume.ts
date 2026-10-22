import { useCallback } from 'react';
import { conversionCache } from '../services/ConversionCache';
import { JobSnapshot } from '../types/conversion';
import { estimateEtaSeconds } from './conversion_eta';
import { isNetworkError, fetchResumedJobSnapshot } from './conversion_runtime_health';
import type { ConversionStateScope } from './useConversionState';
import type { ConversionSnapshotsScope } from './useConversionSnapshots';
import type { ConversionRunSessionScope } from './useConversionRunSession';
import type { ConversionQueueScope } from './useConversionQueue';

type ConversionResumeInput = Pick<
  ConversionStateScope,
  | 'abortRef'
  | 'lastSnapshotAtRef'
  | 'dispatch'
  | 'entryFactoryRef'
  | 't'
  | 'jobQueueRef'
  | 'processedCountRef'
  | 'setQueuePaused'
  | 'fileNameRef'
  | 'seenEventsRef'
  | 'syncQueueSnapshot'
  | 'startTimeRef'
  | 'apiAvailable'
  | 'api'
  | 'setCachedJobs'
  | 'state'
> &
  Pick<
    ConversionSnapshotsScope,
    | 'waitForBackendReady'
    | 'markApiOnline'
    | 'markApiOffline'
    | 'appendSnapshotEvents'
    | 'applySnapshotMeta'
    | 'onStreamStatus'
    | 'saveSnapshotToCache'
    | 'clearCancelledJob'
  > &
  Pick<ConversionRunSessionScope, 'resetLogAndCounters'> &
  Pick<ConversionQueueScope, 'drainQueue'>;

export function useConversionResume({
  abortRef,
  resetLogAndCounters,
  lastSnapshotAtRef,
  dispatch,
  entryFactoryRef,
  t,
  jobQueueRef,
  processedCountRef,
  setQueuePaused,
  drainQueue,
  fileNameRef,
  seenEventsRef,
  syncQueueSnapshot,
  startTimeRef,
  apiAvailable,
  waitForBackendReady,
  api,
  markApiOnline,
  setCachedJobs,
  markApiOffline,
  appendSnapshotEvents,
  applySnapshotMeta,
  onStreamStatus,
  saveSnapshotToCache,
  clearCancelledJob,
  state,
}: ConversionResumeInput) {
  const resume = useCallback(
    async (jobId: string) => {
      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;
      const isCurrent = () => abortRef.current === controller && !controller.signal.aborted;

      resetLogAndCounters();
      lastSnapshotAtRef.current = null;
      dispatch({
        type: 'append-entry',
        entry: entryFactoryRef.current(t.flow.loadingCache || '📦 Restoring conversion data...'),
      });
      const continuePendingBatch = async () => {
        if (!isCurrent()) return;
        if (jobQueueRef.current.length === 0) {
          return;
        }
        console.log(
          `[Resume] Continuing batch queue with ${jobQueueRef.current.length} remaining jobs`,
        );
        dispatch({
          type: 'append-entry',
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
        console.log('[useConversionFlow] Loaded cache for jobId:', jobId, {
          fileName: cached.fileName,
          bookTitle: cached.state.bookTitle,
          jobId: cached.jobId,
        });
        fileNameRef.current = cached.fileName;
        if (Array.isArray(cached.state.log)) {
          cached.state.log.forEach((entry) => {
            seenEventsRef.current.add(entry.message);
            dispatch({ type: 'append-entry', entry });
          });
        }
        if (
          cached.state.summary ||
          cached.state.bookTitle ||
          cached.state.bookAuthor ||
          cached.state.coverUrl
        ) {
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
              type: 'append-entry',
              entry: entryFactoryRef.current(
                `🔄 Queue restored: ${queueToRestore.length} pending conversions will resume after this one`,
              ),
            });
          }
        }

        // Terminal-state cache: restore directly so the user can still browse
        // downloads/metadata even after the backend was wiped (e.g. desktop
        // sidecar restart, /data eviction). Skip the backend fetch that would
        // otherwise 404 and surface a hard "Conversion not found" error.
        if (cached.state.phase === 'success') {
          dispatch({
            type: 'job-created',
            jobId: actualJobId,
            entry: entryFactoryRef.current(
              t.flow.loadingCache || '📦 Restoring conversion data...',
            ),
          });
          dispatch({
            type: 'complete',
            entry: entryFactoryRef.current(
              t.flow.cachedRestoredSuccess ||
                'Restored from local cache — downloads may be unavailable if the server was restarted.',
            ),
            downloads: cached.state.downloads ?? [],
            completedAt: cached.state.completedAt,
            totalDurationSeconds: cached.state.totalDurationSeconds,
          });
          startTimeRef.current = null;
          return;
        }
        if (cached.state.phase === 'cancelled') {
          dispatch({
            type: 'job-created',
            jobId: actualJobId,
            entry: entryFactoryRef.current(
              t.flow.loadingCache || '📦 Restoring conversion data...',
            ),
          });
          dispatch({
            type: 'cancelled',
            entry: entryFactoryRef.current(cached.state.error || t.flow.cancelled || 'Cancelled'),
            error: cached.state.error || t.flow.cancelled || 'Cancelled',
            errorCategory: cached.state.errorCategory,
          });
          startTimeRef.current = null;
          return;
        }
      }

      if (!apiAvailable) {
        dispatch({
          type: 'append-entry',
          entry: entryFactoryRef.current(t.flow.backendConnecting),
        });
        const ready = await waitForBackendReady();
        if (!isCurrent()) return;
        if (!ready) {
          dispatch({
            type: 'fail',
            error: t.flow.backendOffline,
            entry: entryFactoryRef.current(t.flow.backendOfflineDetails),
          });
          startTimeRef.current = null;
          return;
        }
      }

      dispatch({
        type: 'job-created',
        jobId: actualJobId,
        entry: entryFactoryRef.current(t.flow.resuming),
      });

      startTimeRef.current = Date.now();

      let initialSnapshot: JobSnapshot | null = null;
      try {
        initialSnapshot = await fetchResumedJobSnapshot(api, actualJobId, isCurrent);
        if (!isCurrent()) return;
        console.log('[useConversionFlow] Fetched initial snapshot for jobId:', actualJobId, {
          bookTitle: initialSnapshot.bookTitle,
          state: initialSnapshot.state,
        });
        markApiOnline();
      } catch (error) {
        if (!isCurrent()) return;
        if (error instanceof Error && error.message.includes('404')) {
          markApiOnline();
          dispatch({
            type: 'fail',
            error: 'Conversion not found',
            entry: entryFactoryRef.current(
              'This conversion no longer exists on the server. It may have been removed or expired.',
            ),
          });
          // Remove both the original job and any queued job variants
          setCachedJobs((prev) => prev.filter((j) => !j.jobId.startsWith(actualJobId)));
          conversionCache.remove(actualJobId);
          startTimeRef.current = null;
          await continuePendingBatch();
          return;
        } else if (isNetworkError(error)) {
          markApiOffline();
        }
        console.warn('[useConversionFlow] Failed to fetch job from backend:', error);
      }

      if (!initialSnapshot) {
        dispatch({
          type: 'fail',
          error: 'Could not recover conversion state',
          entry: entryFactoryRef.current('Server returned no information about this conversion.'),
        });
        startTimeRef.current = null;
        await continuePendingBatch();
        return;
      }

      if (!fileNameRef.current) {
        fileNameRef.current = initialSnapshot.bookTitle || cached?.fileName || 'Book';
      }

      appendSnapshotEvents(initialSnapshot.events);
      applySnapshotMeta(initialSnapshot);

      if (initialSnapshot.state === 'interrupted') {
        const message = initialSnapshot.error || 'Conversion interrupted';
        dispatch({
          type: 'fail',
          error: message,
          entry: entryFactoryRef.current(message),
        });
        setCachedJobs((prev) => prev.filter((j) => !j.jobId.startsWith(actualJobId)));
        conversionCache.remove(actualJobId);
        startTimeRef.current = null;
        await continuePendingBatch();
        return;
      }

      if (initialSnapshot.state === 'finished') {
        const downloads = initialSnapshot.outputs ?? [];
        const chapterCount = downloads.filter((d) => d.name.toLowerCase().endsWith('.mp3')).length;
        const completedAtIso =
          initialSnapshot.completedAt ?? initialSnapshot.updatedAt ?? new Date().toISOString();
        const totalElapsedSeconds =
          typeof initialSnapshot.totalElapsedSeconds === 'number'
            ? Math.max(0, Math.round(initialSnapshot.totalElapsedSeconds))
            : undefined;
        dispatch({
          type: 'complete',
          downloads,
          entry: entryFactoryRef.current(t.flow.completion(chapterCount)),
          completedAt: completedAtIso,
          totalDurationSeconds: totalElapsedSeconds,
        });
        conversionCache.remove(actualJobId);
        setCachedJobs((prev) => prev.filter((j) => !j.jobId.startsWith(actualJobId)));
        startTimeRef.current = null;
        await continuePendingBatch();
        return;
      }

      if (initialSnapshot.state === 'failed') {
        const failureMessage = initialSnapshot.error || t.flow.defaultFailure;
        dispatch({
          type: 'fail',
          error: failureMessage,
          entry: entryFactoryRef.current(t.flow.failure(failureMessage)),
        });
        setCachedJobs((prev) => prev.filter((j) => !j.jobId.startsWith(actualJobId)));
        conversionCache.remove(actualJobId);
        startTimeRef.current = null;
        await continuePendingBatch();
        return;
      }

      if (
        api.resume &&
        initialSnapshot.state !== 'running' &&
        initialSnapshot.state !== 'cancelling'
      ) {
        try {
          await api.resume(actualJobId);
          if (!isCurrent()) return;
          markApiOnline();
        } catch (error) {
          if (!isCurrent()) return;
          if (isNetworkError(error)) {
            markApiOffline();
          }
          const message =
            error instanceof Error && error.message ? error.message : t.flow.defaultFailure;
          dispatch({
            type: 'fail',
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
          onStreamStatus: (status) => {
            if (isCurrent()) onStreamStatus(status);
          },
          onSnapshot(snapshot) {
            if (!isCurrent() || snapshot.jobId !== actualJobId) return;
            markApiOnline();
            const etaSeconds = estimateEtaSeconds(snapshot, startTimeRef.current);
            applySnapshotMeta(snapshot, etaSeconds);
            appendSnapshotEvents(snapshot.events);
            saveSnapshotToCache(actualJobId, snapshot);
          },
        });

        if (!isCurrent()) return;
        if (finalSnapshot.state === 'cancelled') {
          dispatch({
            type: 'cancelled',
            error: t.flow.cancelled,
            entry: entryFactoryRef.current(t.flow.cancelled),
          });
          clearCancelledJob(actualJobId);
          startTimeRef.current = null;
          await continuePendingBatch();
          return;
        }

        if (finalSnapshot.state === 'failed' || finalSnapshot.state === 'interrupted') {
          const failureMessage = finalSnapshot.error || t.flow.defaultFailure;
          dispatch({
            type: 'fail',
            error: failureMessage,
            errorCategory: finalSnapshot.errorCategory,
            entry: entryFactoryRef.current(t.flow.failure(failureMessage)),
          });
          setCachedJobs((prev) => prev.filter((j) => !j.jobId.startsWith(actualJobId)));
          startTimeRef.current = null;
          await continuePendingBatch();
          return;
        }

        const downloads = finalSnapshot.outputs ?? [];
        const chapterCount = downloads.filter((d) => d.name.toLowerCase().endsWith('.mp3')).length;
        applySnapshotMeta(finalSnapshot, 0);
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
        conversionCache.remove(actualJobId);
        setCachedJobs((prev) => prev.filter((j) => !j.jobId.startsWith(actualJobId)));
        startTimeRef.current = null;

        await continuePendingBatch();
      } catch (error) {
        if (!isCurrent()) return;
        if (error instanceof DOMException && error.name === 'AbortError') {
          return;
        }
        const message =
          error instanceof Error && error.message ? error.message : t.flow.defaultError;
        if (isNetworkError(error)) {
          markApiOffline();
        }
        dispatch({
          type: 'fail',
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
      onStreamStatus,
      resetLogAndCounters,
      setCachedJobs,
      setQueuePaused,
      state,
      syncQueueSnapshot,
      t,
    ],
  );

  return { resume };
}

export type ConversionResumeScope = ReturnType<typeof useConversionResume>;
