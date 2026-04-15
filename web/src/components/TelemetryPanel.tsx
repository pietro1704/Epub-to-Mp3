import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  TelemetryService,
  type EngineStats,
  type TelemetryPoint,
  type TelemetrySummary,
} from "../services/TelemetryService";

export interface TelemetryPanelLabels {
  title: string;
  description: string;
  refresh: string;
  refreshing: string;
  errorGeneric: string;
  emptyState: string;
  engineHeader: string;
  samplesHeader: string;
  avgHeader: string;
  minHeader: string;
  maxHeader: string;
  rankedLabel: string;
  timelineTitle: string;
  timelineEmpty: string;
  timelineLatest: string;
  totalSamples: (count: number) => string;
  updatedAt: (isoString: string) => string;
}

export const DEFAULT_TELEMETRY_LABELS_EN: TelemetryPanelLabels = {
  title: "Telemetry",
  description:
    "TTS throughput per engine, based on recorded synthesis samples.",
  refresh: "Refresh",
  refreshing: "Refreshing…",
  errorGeneric: "Failed to load telemetry.",
  emptyState: "No telemetry samples yet — run a conversion to populate.",
  engineHeader: "Engine",
  samplesHeader: "Samples",
  avgHeader: "Avg c/s",
  minHeader: "Min c/s",
  maxHeader: "Max c/s",
  rankedLabel: "Fastest → slowest",
  timelineTitle: "Recent chapters",
  timelineEmpty: "No recent samples.",
  timelineLatest: "Latest first",
  totalSamples: (count) => `${count} total samples`,
  updatedAt: (iso) => `Updated ${new Date(iso).toLocaleTimeString()}`,
};

export const DEFAULT_TELEMETRY_LABELS_PT: TelemetryPanelLabels = {
  title: "Telemetria",
  description:
    "Taxa de síntese TTS por engine, com base em amostras registradas.",
  refresh: "Atualizar",
  refreshing: "Atualizando…",
  errorGeneric: "Falha ao carregar telemetria.",
  emptyState:
    "Sem amostras de telemetria ainda — rode uma conversão para popular.",
  engineHeader: "Engine",
  samplesHeader: "Amostras",
  avgHeader: "Média c/s",
  minHeader: "Mín c/s",
  maxHeader: "Máx c/s",
  rankedLabel: "Mais rápido → mais lento",
  timelineTitle: "Capítulos recentes",
  timelineEmpty: "Sem amostras recentes.",
  timelineLatest: "Mais recentes primeiro",
  totalSamples: (count) => `${count} amostras totais`,
  updatedAt: (iso) => `Atualizado ${new Date(iso).toLocaleTimeString()}`,
};

export interface TelemetryPanelProps {
  labels?: TelemetryPanelLabels;
  locale?: "pt" | "en";
  autoRefreshMs?: number;
}

function formatNumber(value: number): string {
  if (!Number.isFinite(value)) return "–";
  if (value >= 100) return value.toFixed(0);
  if (value >= 10) return value.toFixed(1);
  return value.toFixed(2);
}

function engineRow(name: string, stats: EngineStats): JSX.Element {
  return (
    <tr key={name} data-engine={name}>
      <td>{name.toUpperCase()}</td>
      <td>{stats.samples}</td>
      <td>{formatNumber(stats.avg_chars_per_second)}</td>
      <td>{formatNumber(stats.min_chars_per_second)}</td>
      <td>{formatNumber(stats.max_chars_per_second)}</td>
    </tr>
  );
}

export default function TelemetryPanel({
  labels: labelsProp,
  locale = "en",
  autoRefreshMs = 30000,
}: TelemetryPanelProps): JSX.Element {
  const labels =
    labelsProp ??
    (locale === "pt"
      ? DEFAULT_TELEMETRY_LABELS_PT
      : DEFAULT_TELEMETRY_LABELS_EN);
  const [summary, setSummary] = useState<TelemetrySummary | null>(null);
  const [timeline, setTimeline] = useState<TelemetryPoint[]>([]);
  const [loading, setLoading] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);
  const [updatedAt, setUpdatedAt] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const fetchAll = useCallback(async () => {
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setLoading(true);
    setError(null);
    try {
      const [summaryData, timelineData] = await Promise.all([
        TelemetryService.getSummary(controller.signal),
        TelemetryService.getTimeline(30, controller.signal),
      ]);
      if (controller.signal.aborted) return;
      setSummary(summaryData);
      const points = Array.isArray(timelineData?.points)
        ? timelineData.points
        : [];
      setTimeline([...points].reverse());
      setUpdatedAt(new Date().toISOString());
    } catch (err) {
      if (controller.signal.aborted) return;
      const message = err instanceof Error ? err.message : labels.errorGeneric;
      setError(message || labels.errorGeneric);
    } finally {
      if (!controller.signal.aborted) setLoading(false);
    }
  }, [labels.errorGeneric]);

  useEffect(() => {
    void fetchAll();
    return () => abortRef.current?.abort();
  }, [fetchAll]);

  useEffect(() => {
    if (autoRefreshMs <= 0) return;
    const id = window.setInterval(() => void fetchAll(), autoRefreshMs);
    return () => window.clearInterval(id);
  }, [autoRefreshMs, fetchAll]);

  const sortedEngines = useMemo(() => {
    if (!summary || !summary.engines) return [] as [string, EngineStats][];
    const entries = Object.entries(summary.engines);
    const ranked = Array.isArray(summary.ranked) ? summary.ranked : [];
    const order = new Map(ranked.map((name, idx) => [name, idx]));
    return entries.sort(
      ([a], [b]) =>
        (order.get(a) ?? Number.POSITIVE_INFINITY) -
        (order.get(b) ?? Number.POSITIVE_INFINITY),
    );
  }, [summary]);

  const isEmpty =
    !summary || !summary.engines || Object.keys(summary.engines).length === 0;

  return (
    <section
      className="telemetry-panel"
      aria-label={labels.title}
      data-testid="telemetry-panel"
    >
      <header className="telemetry-panel__header">
        <div>
          <h2>{labels.title}</h2>
          <p>{labels.description}</p>
        </div>
        <div className="telemetry-panel__actions">
          <button
            type="button"
            onClick={() => void fetchAll()}
            disabled={loading}
            aria-busy={loading || undefined}
          >
            {loading ? labels.refreshing : labels.refresh}
          </button>
          {updatedAt && (
            <small className="telemetry-panel__timestamp">
              {labels.updatedAt(updatedAt)}
            </small>
          )}
        </div>
      </header>

      {error && (
        <div role="alert" className="telemetry-panel__error">
          {error}
        </div>
      )}

      {isEmpty && !loading && !error ? (
        <p className="telemetry-panel__empty">{labels.emptyState}</p>
      ) : (
        <>
          <div className="telemetry-panel__summary">
            <table>
              <thead>
                <tr>
                  <th scope="col">{labels.engineHeader}</th>
                  <th scope="col">{labels.samplesHeader}</th>
                  <th scope="col">{labels.avgHeader}</th>
                  <th scope="col">{labels.minHeader}</th>
                  <th scope="col">{labels.maxHeader}</th>
                </tr>
              </thead>
              <tbody>
                {sortedEngines.map(([name, stats]) => engineRow(name, stats))}
              </tbody>
            </table>
            {summary &&
              Array.isArray(summary.ranked) &&
              summary.ranked.length > 0 && (
                <p className="telemetry-panel__ranked">
                  <strong>{labels.rankedLabel}:</strong>{" "}
                  {summary.ranked.map((n) => n.toUpperCase()).join(" → ")}
                </p>
              )}
            {summary && (
              <p className="telemetry-panel__total">
                {labels.totalSamples(summary.totalSamples ?? 0)}
              </p>
            )}
          </div>

          <div className="telemetry-panel__timeline">
            <h3>{labels.timelineTitle}</h3>
            {timeline.length === 0 ? (
              <p className="telemetry-panel__empty">{labels.timelineEmpty}</p>
            ) : (
              <ol className="telemetry-panel__timeline-list">
                {timeline.map((point, idx) => (
                  <li
                    key={`${point.jobId ?? "job"}-${point.chapter ?? idx}-${idx}`}
                  >
                    <span className="telemetry-panel__engine-badge">
                      {point.engine.toUpperCase()}
                    </span>
                    <span className="telemetry-panel__chapter">
                      {point.chapter || `#${idx + 1}`}
                    </span>
                    <span className="telemetry-panel__cps">
                      {formatNumber(point.charsPerSecond)} c/s
                    </span>
                    <span className="telemetry-panel__chars">
                      {point.chars} chars
                    </span>
                  </li>
                ))}
              </ol>
            )}
          </div>
        </>
      )}
    </section>
  );
}
