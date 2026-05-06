import { API_BASE_URL } from "../config";

export interface EngineStats {
  samples: number;
  avg_chars_per_second: number;
  max_chars_per_second: number;
  min_chars_per_second: number;
}

export interface TelemetrySummary {
  engines: Record<string, EngineStats>;
  ranked: string[];
  totalSamples: number;
  /** Per-language breakdown, shape: ``{ engine: { lang: EngineStats } }``.
   *  Bucket ``"_any"`` collects samples without a recorded language. */
  byLanguage?: Record<string, Record<string, EngineStats>>;
}

export interface TelemetryPoint {
  engine: string;
  voice?: string | null;
  timestamp?: string | null;
  charsPerSecond: number;
  chars: number;
  synthSeconds: number;
  chapter?: string | null;
  jobId?: string | null;
}

export interface TelemetryTimeline {
  points: TelemetryPoint[];
  count: number;
}

async function jsonFetch<T>(path: string, signal?: AbortSignal): Promise<T> {
  const response = await fetch(`${API_BASE_URL}${path}`, {
    headers: { Accept: "application/json" },
    signal,
  });
  if (!response.ok) {
    throw new Error(
      `Request failed: ${response.status} ${response.statusText}`,
    );
  }
  return (await response.json()) as T;
}

export const TelemetryService = {
  async getSummary(signal?: AbortSignal): Promise<TelemetrySummary> {
    return jsonFetch<TelemetrySummary>("/api/telemetry/summary", signal);
  },
  async getTimeline(
    limit = 50,
    signal?: AbortSignal,
  ): Promise<TelemetryTimeline> {
    const safeLimit = Math.max(1, Math.min(500, Math.floor(limit)));
    return jsonFetch<TelemetryTimeline>(
      `/api/telemetry/timeline?limit=${safeLimit}`,
      signal,
    );
  },
};
