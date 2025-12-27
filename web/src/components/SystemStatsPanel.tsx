import { SystemStats } from "../hooks/useSystemStats";

interface SystemStatsPanelProps {
  stats: SystemStats | null;
  hasError?: boolean;
  isLoading?: boolean;
  updatedAt?: number | null;
  nextRetryMs?: number | null;
  labels: {
    title: string;
    loading: string;
    error: string;
    offline: string;
    uptime: string;
    cpu: string;
    memory: string;
    queue: string;
    running: string;
    workers: string;
    recommendation: string;
    gpu: string;
    lastUpdated: (value: string) => string;
    retrying: (value: string) => string;
  };
}

const formatBytes = (bytes?: number): string => {
  if (typeof bytes !== "number") {
    return "—";
  }
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  return `${value.toFixed(1)} ${units[unitIndex]}`;
};

const formatDuration = (seconds?: number): string => {
  if (!seconds || seconds <= 0) {
    return "—";
  }
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours > 0) {
    return `${hours}h ${minutes}m`;
  }
  return `${minutes}m`;
};

const formatRelativeTime = (timestamp?: number | null): string | null => {
  if (!timestamp) {
    return null;
  }
  const deltaSeconds = Math.round((Date.now() - timestamp) / 1000);
  if (!Number.isFinite(deltaSeconds)) {
    return null;
  }
  const absSeconds = Math.abs(deltaSeconds);
  const direction = deltaSeconds > 0 ? -1 : 1;
  const relative = (value: number, unit: Intl.RelativeTimeFormatUnit) => {
    if (
      typeof Intl !== "undefined" &&
      typeof Intl.RelativeTimeFormat === "function"
    ) {
      const formatter = new Intl.RelativeTimeFormat(undefined, {
        numeric: "auto",
      });
      return formatter.format(direction * value, unit);
    }
    return unit === "second"
      ? `${Math.abs(value)}s`
      : unit === "minute"
        ? `${Math.abs(value)}m`
        : `${Math.abs(value)}h`;
  };
  if (absSeconds < 60) {
    return relative(absSeconds, "second");
  }
  if (absSeconds < 3600) {
    return relative(Math.round(absSeconds / 60), "minute");
  }
  return relative(Math.round(absSeconds / 3600), "hour");
};

const formatRetryDelay = (ms?: number | null): string => {
  if (!ms || ms <= 0) {
    return "0s";
  }
  const totalSeconds = Math.max(1, Math.ceil(ms / 1000));
  if (totalSeconds < 60) {
    return `${totalSeconds}s`;
  }
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  if (seconds === 0) {
    return `${minutes}m`;
  }
  return `${minutes}m ${seconds}s`;
};

export default function SystemStatsPanel({
  stats,
  labels,
  hasError,
  isLoading,
  updatedAt,
  nextRetryMs,
}: SystemStatsPanelProps): JSX.Element {
  if (!stats) {
    const statusText = hasError ? labels.offline : labels.loading;
    const retryText =
      hasError && nextRetryMs
        ? labels.retrying(formatRetryDelay(nextRetryMs))
        : null;
    return (
      <div className="system-stats">
        <div className="system-stats__header">
          <strong>{labels.title}</strong>
          <span>{statusText}</span>
        </div>
        {hasError && (
          <div className="system-stats__hint">
            <span>{labels.error}</span>
            {retryText && <small>{retryText}</small>}
          </div>
        )}
      </div>
    );
  }
  const cpuPercent = Math.round(stats.cpu?.percent ?? 0);
  const memPercent = Math.round(stats.memory?.percent ?? 0);
  const memUsage = `${formatBytes(stats.memory?.used)} / ${formatBytes(stats.memory?.total)}`;
  const uptime = formatDuration(stats.uptimeSeconds);
  const relative = formatRelativeTime(updatedAt);
  const statusParts: string[] = [];
  if (relative) {
    statusParts.push(labels.lastUpdated(relative));
  }
  if (hasError && nextRetryMs) {
    statusParts.push(labels.retrying(formatRetryDelay(nextRetryMs)));
  }
  if (!relative && isLoading) {
    statusParts.push(labels.loading);
  }
  const headerNote = statusParts.join(" • ");
  return (
    <div className="system-stats">
      <div className="system-stats__header">
        <strong>{labels.title}</strong>
        <div className="system-stats__status">
          {uptime && (
            <span>
              {labels.uptime}: {uptime}
            </span>
          )}
          {headerNote && <span>{headerNote}</span>}
        </div>
      </div>
      <div className="system-stats__grid">
        <div className="system-stats__item">
          <span>{labels.cpu}</span>
          <strong>{cpuPercent}%</strong>
          <div className="system-stats__bar">
            <div
              className="system-stats__fill"
              style={{ width: `${Math.min(100, Math.max(0, cpuPercent))}%` }}
            />
          </div>
        </div>
        <div className="system-stats__item">
          <span>{labels.memory}</span>
          <strong>{memPercent}%</strong>
          <small>{memUsage}</small>
          <div className="system-stats__bar">
            <div
              className="system-stats__fill"
              style={{ width: `${Math.min(100, Math.max(0, memPercent))}%` }}
            />
          </div>
        </div>
        <div className="system-stats__item">
          <span>{labels.queue}</span>
          <strong>{stats.jobs?.queueDepth ?? 0}</strong>
          <small>
            {labels.running}: {stats.jobs?.inFlight ?? 0}
          </small>
        </div>
        <div className="system-stats__item">
          <span>{labels.workers}</span>
          <strong>{stats.jobs?.workers?.current ?? 0}</strong>
          <small>
            Target:{" "}
            {stats.jobs?.workers?.target ??
              stats.recommendations?.jobWorkers ??
              0}
          </small>
        </div>
        {stats.recommendations && (
          <div className="system-stats__item">
            <span>{labels.recommendation}</span>
            <strong>{stats.recommendations.parallelSlots} slots</strong>
            <small>{stats.recommendations.jobWorkers} worker(s)</small>
          </div>
        )}
      </div>
      {Array.isArray(stats.gpus) && stats.gpus.length > 0 && (
        <div className="system-stats__gpus">
          {stats.gpus.map((gpu, index) => (
            <div key={`${gpu.name}-${index}`} className="system-stats__gpu">
              <strong>{gpu.name || `${labels.gpu} ${index + 1}`}</strong>
              <span>{`Uso: ${gpu.utilizationPercent ?? 0}%`}</span>
              <span>{`VRAM: ${Math.round(gpu.memoryUsedMB ?? 0)} / ${Math.round(gpu.memoryTotalMB ?? 0)} MB`}</span>
              {typeof gpu.temperatureC === "number" && (
                <span>Temp: {Math.round(gpu.temperatureC)}°C</span>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
