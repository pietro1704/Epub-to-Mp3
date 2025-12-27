import { useEffect, useState } from "react";
import { resolveApiUrl } from "../config";

export interface SystemCpuStats {
  percent?: number;
  perCore?: number[];
  logical?: number;
  physical?: number;
  frequencyMHz?: number;
  loadAverage?: number[];
}

export interface SystemMemoryStats {
  total?: number;
  available?: number;
  used?: number;
  percent?: number;
}

export interface SystemRecommendation {
  parallelSlots: number;
  jobWorkers: number;
}

export interface SystemStats {
  timestamp: number;
  uptimeSeconds?: number;
  cpu?: SystemCpuStats;
  memory?: SystemMemoryStats;
  swap?: SystemMemoryStats;
  disk?: { readBytes?: number; writeBytes?: number };
  network?: { sentBytes?: number; receivedBytes?: number };
  gpus?: Array<{
    name?: string;
    memoryTotalMB?: number;
    memoryUsedMB?: number;
    utilizationPercent?: number;
    temperatureC?: number;
  }>;
  jobs?: {
    total?: number;
    queued?: number;
    running?: number;
    finished?: number;
    failed?: number;
    cancelled?: number;
    queueDepth?: number;
    inFlight?: number;
    workers?: {
      current?: number;
      target?: number;
    };
  };
  recommendations?: SystemRecommendation;
  telemetry?: Record<
    string,
    {
      avg_chars_per_second?: number;
      max_chars_per_second?: number;
      min_chars_per_second?: number;
      samples?: number;
    }
  >;
}

const STATS_ENDPOINT = resolveApiUrl("/api/system/stats");

export interface SystemStatsResult {
  data: SystemStats | null;
  error: boolean;
  loading: boolean;
  lastUpdated: number | null;
  nextRetryMs: number | null;
}

export function useSystemStats(pollIntervalMs = 5000): SystemStatsResult {
  const [stats, setStats] = useState<SystemStats | null>(null);
  const [error, setError] = useState(false);
  const [loading, setLoading] = useState(true);
  const [lastUpdated, setLastUpdated] = useState<number | null>(null);
  const [nextRetryMs, setNextRetryMs] = useState<number | null>(pollIntervalMs);

  useEffect(() => {
    if (typeof window === "undefined") {
      return () => {};
    }
    if (pollIntervalMs <= 0) {
      setLoading(false);
      setNextRetryMs(null);
      return () => {};
    }
    let cancelled = false;
    let timeout: number | undefined;
    let controller: AbortController | null = null;
    let attempt = 0;
    const minInterval = Math.max(1000, pollIntervalMs);
    const maxInterval = 60000;
    let hasSuccessfulFetch = false;

    const scheduleNext = (delay: number) => {
      if (cancelled) {
        return;
      }
      setNextRetryMs(delay);
      timeout = window.setTimeout(fetchStats, delay);
    };

    const fetchStats = async () => {
      if (cancelled) {
        return;
      }
      controller?.abort();
      controller = new AbortController();
      try {
        if (!hasSuccessfulFetch) {
          setLoading(true);
        }
        const response = await fetch(STATS_ENDPOINT, {
          cache: "no-store",
          signal: controller.signal,
        });
        if (!response.ok) {
          throw new Error(`HTTP ${response.status}`);
        }
        const payload = await response.json();
        if (!cancelled) {
          setStats(payload);
          setError(false);
          setLoading(false);
          setLastUpdated(Date.now());
          hasSuccessfulFetch = true;
          attempt = 0;
        }
      } catch (error) {
        if (!cancelled) {
          console.warn("[useSystemStats] Failed to fetch stats", error);
          setError(true);
          setLoading(false);
          attempt += 1;
          const nextDelay = Math.min(
            Math.round(minInterval * Math.pow(1.6, attempt)),
            maxInterval,
          );
          scheduleNext(nextDelay);
          return;
        }
      } finally {
        if (!cancelled && attempt === 0) {
          scheduleNext(minInterval);
        }
      }
    };

    scheduleNext(0);
    return () => {
      cancelled = true;
      if (timeout) {
        window.clearTimeout(timeout);
      }
      if (controller) {
        controller.abort();
      }
    };
  }, [pollIntervalMs]);

  return { data: stats, error, loading, lastUpdated, nextRetryMs };
}
