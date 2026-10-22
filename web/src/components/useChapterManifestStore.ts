import { useCallback, useEffect, useMemo, useState } from 'react';
import type { ChapterStreamManifest } from '../types/conversion';
import { conversionClient } from '../services/ConversionService';

type ChapterManifests = Record<number, ChapterStreamManifest | null>;

/** A job owns its cached manifests, pending requests and bounded batch workers. */
export function useChapterManifestStore(jobId?: string) {
  const [manifests, setManifests] = useState<ChapterManifests>({});
  const [manifestLoading, setManifestLoading] = useState<Record<number, boolean>>({});
  const [manifestErrors, setManifestErrors] = useState<Record<number, string | null>>({});
  const lease = useMemo(() => ({ active: false, generation: 0 }), [jobId]);

  useEffect(() => {
    lease.active = true;
    lease.generation += 1;
    setManifests({});
    setManifestLoading({});
    setManifestErrors({});
    return () => {
      lease.active = false;
    };
  }, [lease]);

  const fetchManifest = useCallback(
    async (chapterIndex: number, silent = false) => {
      if (!jobId || !conversionClient.getChapterManifest || !lease.active) return;
      const generation = lease.generation;
      const isCurrent = () => lease.active && lease.generation === generation;
      if (!silent) {
        setManifestLoading((prev) => ({ ...prev, [chapterIndex]: true }));
        setManifestErrors((prev) => ({ ...prev, [chapterIndex]: null }));
      }
      try {
        const manifest = await conversionClient.getChapterManifest(jobId, chapterIndex);
        if (!isCurrent()) return;
        if (manifest) {
          setManifests((prev) => (isCurrent() ? { ...prev, [chapterIndex]: manifest } : prev));
          setManifestErrors((prev) => (isCurrent() ? { ...prev, [chapterIndex]: null } : prev));
        }
        return manifest;
      } catch (error) {
        if (!isCurrent()) return;
        const message = error instanceof Error ? error.message : 'Failed to load segments';
        setManifestErrors((prev) => (isCurrent() ? { ...prev, [chapterIndex]: message } : prev));
      } finally {
        if (!silent && isCurrent()) {
          setManifestLoading((prev) => (isCurrent() ? { ...prev, [chapterIndex]: false } : prev));
        }
      }
    },
    [jobId, lease],
  );

  const fetchAllManifests = useCallback(
    async (chapterIndices: number[]) => {
      if (!jobId || !lease.active) return;
      const generation = lease.generation;
      const isCurrent = () => lease.active && lease.generation === generation;
      // Return this operation's resolved text rather than relying on a later render.
      const resolved = { ...manifests };
      const queue = chapterIndices.filter((index) => !resolved[index]);
      const workers = Array.from({ length: 4 }).map(async () => {
        while (queue.length > 0 && isCurrent()) {
          const index = queue.shift();
          if (index === undefined) break;
          const manifest = await fetchManifest(index, true);
          if (manifest && isCurrent()) resolved[index] = manifest;
        }
      });
      await Promise.all(workers);
      return isCurrent() ? resolved : undefined;
    },
    [fetchManifest, jobId, lease, manifests],
  );

  return { manifests, manifestLoading, manifestErrors, fetchManifest, fetchAllManifests };
}
