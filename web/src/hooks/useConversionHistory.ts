import { useEffect } from 'react';
import { conversionCache } from '../services/ConversionCache';
import { ConversionFormValues } from '../types/conversion';
import type { ConversionStateScope } from './useConversionState';
import type { ConversionSnapshotsScope } from './useConversionSnapshots';

type ConversionHistoryInput = Pick<
  ConversionStateScope,
  'setCachedJobsLoading' | 'setCachedJobs' | 'apiAvailable' | 'api' | 'setRecentJobs'
> &
  Pick<ConversionSnapshotsScope, 'shouldMarkOffline' | 'markApiOffline' | 'markApiOnline'>;

export function useConversionHistory({
  setCachedJobsLoading,
  setCachedJobs,
  shouldMarkOffline,
  markApiOffline,
  apiAvailable,
  api,
  markApiOnline,
  setRecentJobs,
}: ConversionHistoryInput) {
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
              language: job.state?.language ?? job.state?.summary?.detectedLanguage,
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
        markApiOnline();

        if (!backendJobs || backendJobs.length === 0) {
          // Backend has no resumable jobs (e.g. desktop sidecar restarted and
          // .jobs/ was wiped from temp dir). Keep local-cache entries visible
          // so the user can still resume from the last persisted state.
          localFallback(false);
          return;
        }

        const localCacheMap = new Map(conversionCache.listAll().map((job) => [job.jobId, job]));
        const backendJobIds = new Set(backendJobs.map((j) => j.jobId));

        const backendExpanded = backendJobs.flatMap((job) => {
          const localCache = localCacheMap.get(job.jobId);
          return expandJobsWithQueue(
            {
              jobId: job.jobId,
              fileName: job.fileName || job.bookTitle || 'Unknown Book',
              timestamp: job.savedAt ? new Date(job.savedAt).getTime() : Date.now(),
              engine: job.engine,
              voice: job.voice,
              language: job.language,
            },
            localCache?.state?.pendingBatchQueue,
          );
        });

        const localOnlyExpanded = conversionCache
          .listAll()
          .filter((localJob) => !backendJobIds.has(localJob.jobId))
          .flatMap((localJob) =>
            expandJobsWithQueue(
              {
                jobId: localJob.jobId,
                fileName: localJob.fileName,
                timestamp: localJob.timestamp,
                engine: localJob.state?.engine,
                voice: localJob.state?.voice,
                language: localJob.state?.language ?? localJob.state?.summary?.detectedLanguage,
              },
              localJob.state?.pendingBatchQueue,
            ),
          );

        setCachedJobs([...backendExpanded, ...localOnlyExpanded]);
        setCachedJobsLoading(false);
      } catch (error) {
        console.warn('[useConversionFlow] Failed to load resumable jobs:', error);
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
      if (typeof document !== 'undefined' && document.visibilityState === 'hidden') {
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
        console.warn('[useConversionFlow] Failed to load recent jobs:', error);
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

  return {};
}

export type ConversionHistoryScope = ReturnType<typeof useConversionHistory>;
