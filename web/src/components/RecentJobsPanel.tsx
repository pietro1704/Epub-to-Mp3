import { useState, useMemo } from "react";
import { RecentJobEntry } from "../types/conversion";
import { useI18n, useTranslations } from "../i18n/I18nProvider";

interface JobBatch {
  batchId: string;
  jobs: RecentJobEntry[];
  startedAt: string;
  completedAt?: string;
  totalDuration?: number;
  allCompleted: boolean;
}

interface RecentJobsPanelProps {
  jobs: RecentJobEntry[];
  onViewOutputs?: (job: RecentJobEntry) => void;
  onRemoveJob?: (jobId: string) => void;
}

export default function RecentJobsPanel({
  jobs,
  onViewOutputs,
  onRemoveJob,
}: RecentJobsPanelProps): JSX.Element {
  const t = useTranslations();
  const { locale } = useI18n();
  const [isCollapsed, setIsCollapsed] = useState(true);
  const [expandedBatches, setExpandedBatches] = useState<Set<string>>(
    new Set(),
  );

  // Group jobs into batches based on close timestamps (within 5 minutes)
  const batches = useMemo<JobBatch[]>(() => {
    if (!jobs || jobs.length === 0) return [];

    // Sort jobs by timestamp
    const sorted = [...jobs].sort((a, b) => {
      const timeA = Date.parse(a.startedAt || a.savedAt || "");
      const timeB = Date.parse(b.startedAt || b.savedAt || "");
      return timeB - timeA; // Most recent first
    });

    const result: JobBatch[] = [];
    const BATCH_THRESHOLD_MS = 5 * 60 * 1000; // 5 minutes

    for (const job of sorted) {
      const jobTime = Date.parse(job.startedAt || job.savedAt || "");
      if (Number.isNaN(jobTime)) continue;

      // Try to add to the most recent batch
      const lastBatch = result[0];
      if (lastBatch) {
        const batchTime = Date.parse(lastBatch.startedAt);
        if (
          !Number.isNaN(batchTime) &&
          Math.abs(jobTime - batchTime) < BATCH_THRESHOLD_MS
        ) {
          // Add to existing batch
          lastBatch.jobs.push(job);

          // Update batch data
          if (job.completedAt) {
            const completedTime = Date.parse(job.completedAt);
            const currentCompletedTime = lastBatch.completedAt
              ? Date.parse(lastBatch.completedAt)
              : 0;
            if (completedTime > currentCompletedTime) {
              lastBatch.completedAt = job.completedAt;
            }
          }

          if (job.totalDurationSeconds) {
            lastBatch.totalDuration =
              (lastBatch.totalDuration || 0) + job.totalDurationSeconds;
          }

          lastBatch.allCompleted =
            lastBatch.allCompleted && job.state === "finished";
          continue;
        }
      }

      // Create new batch
      result.unshift({
        batchId: `batch-${jobTime}-${job.jobId}`,
        jobs: [job],
        startedAt: job.startedAt || job.savedAt || new Date().toISOString(),
        completedAt: job.completedAt,
        totalDuration: job.totalDurationSeconds,
        allCompleted: job.state === "finished",
      });
    }

    return result;
  }, [jobs]);

  const hasJobs = batches.length > 0;

  const toggleBatch = (batchId: string) => {
    setExpandedBatches((prev) => {
      const next = new Set(prev);
      if (next.has(batchId)) {
        next.delete(batchId);
      } else {
        next.add(batchId);
      }
      return next;
    });
  };

  const formatWhen = (timestamp?: string): string => {
    if (!timestamp) return t.recentJobs.justNow;
    const value = Date.parse(timestamp);
    if (Number.isNaN(value)) return t.recentJobs.justNow;
    const diff = Date.now() - value;
    const minutes = Math.floor(diff / 60000);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);
    if (days > 0) return t.recentJobs.daysAgo(days);
    if (hours > 0) return t.recentJobs.hoursAgo(hours);
    if (minutes > 0) return t.recentJobs.minutesAgo(minutes);
    return t.recentJobs.justNow;
  };

  const stateLabel = (state: string): string => {
    const map = t.recentJobs.stateLabels;
    return map?.[state] ?? state;
  };

  const formatDateTime = (value?: string): string | null => {
    if (!value) return null;
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return null;
    }
    try {
      return new Intl.DateTimeFormat(locale, {
        dateStyle: "medium",
        timeStyle: "short",
      }).format(date);
    } catch (_error) {
      return date.toLocaleString();
    }
  };

  const formatDuration = (seconds?: number | null): string | null => {
    if (
      typeof seconds !== "number" ||
      !Number.isFinite(seconds) ||
      seconds <= 0
    ) {
      return null;
    }
    const totalSeconds = Math.max(1, Math.round(seconds));
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const remainingSeconds = totalSeconds % 60;
    const parts: string[] = [];
    if (hours > 0) {
      parts.push(t.downloads.durationHours(hours));
    }
    if (minutes > 0) {
      parts.push(t.downloads.durationMinutes(minutes));
    }
    if (parts.length === 0) {
      parts.push(t.downloads.durationSeconds(Math.max(remainingSeconds, 1)));
    }
    return parts.join(" ");
  };

  return (
    <section className="recent-jobs">
      <button
        type="button"
        className="recent-jobs__header"
        onClick={() => setIsCollapsed(!isCollapsed)}
        aria-expanded={!isCollapsed}
        aria-controls="recent-jobs-list"
      >
        <div>
          <h3>{t.recentJobs.title}</h3>
          <p>{t.recentJobs.subtitle}</p>
        </div>
        <span className="recent-jobs__toggle-icon" aria-hidden="true">
          {isCollapsed ? "▼" : "▲"}
        </span>
      </button>
      {!isCollapsed && (
        <ul className="recent-jobs__list" id="recent-jobs-list">
          {hasJobs ? (
            batches.map((batch) => {
              const isExpanded = expandedBatches.has(batch.batchId);
              const batchLabel =
                batch.jobs.length === 1
                  ? batch.jobs[0].bookTitle
                  : `${batch.jobs.length} books`;
              const completedLabel = formatDateTime(
                batch.completedAt ?? batch.startedAt,
              );
              const durationText = formatDuration(batch.totalDuration);
              const relativeTime = formatWhen(
                batch.completedAt ?? batch.startedAt,
              );

              return (
                <li
                  key={batch.batchId}
                  className="recent-jobs__item recent-jobs__item--batch"
                >
                  {/* Batch header */}
                  <div
                    className="recent-jobs__batch-header"
                    onClick={() =>
                      batch.jobs.length > 1 && toggleBatch(batch.batchId)
                    }
                  >
                    <div className="recent-jobs__meta">
                      <div className="recent-jobs__info">
                        <strong className="recent-jobs__title">
                          {batch.jobs.length > 1 && (
                            <span
                              className="recent-jobs__batch-icon"
                              aria-hidden="true"
                            >
                              {isExpanded ? "▼" : "▶"}
                            </span>
                          )}
                          {batchLabel}
                        </strong>
                        {batch.jobs.length > 1 && (
                          <p className="recent-jobs__filename">
                            Queue of {batch.jobs.length} conversions
                          </p>
                        )}
                        {batch.jobs.length === 1 && (
                          <p
                            className="recent-jobs__filename"
                            title={batch.jobs[0].fileName}
                          >
                            {batch.jobs[0].fileName}
                          </p>
                        )}
                      </div>
                      <div className="recent-jobs__status">
                        <span
                          className={`recent-jobs__badge recent-jobs__badge--${batch.allCompleted ? "finished" : "partial"}`}
                        >
                          {batch.allCompleted
                            ? stateLabel("finished")
                            : `${batch.jobs.filter((j) => j.state === "finished").length}/${batch.jobs.length}`}
                        </span>
                        <div className="recent-jobs__time">
                          <span>{relativeTime}</span>
                          {completedLabel && (
                            <span>
                              {t.recentJobs.completedAtLabel(completedLabel)}
                            </span>
                          )}
                          {durationText && (
                            <span>
                              {t.recentJobs.durationLabel(durationText)}
                            </span>
                          )}
                        </div>
                      </div>
                    </div>
                  </div>

                  {/* Expanded job list */}
                  {isExpanded && batch.jobs.length > 1 && (
                    <ul className="recent-jobs__batch-items">
                      {batch.jobs.map((job) => (
                        <li key={job.jobId} className="recent-jobs__batch-item">
                          <div className="recent-jobs__batch-item-info">
                            <strong title={job.bookTitle}>
                              {job.bookTitle}
                            </strong>
                            <span
                              className={`recent-jobs__badge recent-jobs__badge--${job.state}`}
                            >
                              {stateLabel(job.state)}
                            </span>
                          </div>
                          <div className="recent-jobs__actions">
                            {onViewOutputs &&
                              job.outputs &&
                              job.outputs.length > 0 && (
                                <button
                                  type="button"
                                  className="recent-jobs__action recent-jobs__action--ghost"
                                  onClick={() => onViewOutputs(job)}
                                  title={t.recentJobs.viewAudiosHint}
                                >
                                  {t.recentJobs.viewAudiosButton}
                                </button>
                              )}
                            {job.downloadUrl && (
                              <a
                                href={job.downloadUrl}
                                className="recent-jobs__action recent-jobs__action--primary"
                                target="_blank"
                                rel="noopener noreferrer"
                              >
                                {t.recentJobs.downloadButton}
                              </a>
                            )}
                            {onRemoveJob && (
                              <button
                                type="button"
                                className="recent-jobs__action recent-jobs__action--ghost"
                                onClick={() => onRemoveJob(job.jobId)}
                              >
                                {t.recentJobs.removeButton}
                              </button>
                            )}
                          </div>
                        </li>
                      ))}
                    </ul>
                  )}

                  {/* Batch actions (when collapsed or single-job batch) */}
                  {(!isExpanded || batch.jobs.length === 1) && (
                    <div className="recent-jobs__actions">
                      {batch.jobs.length === 1 &&
                        onViewOutputs &&
                        batch.jobs[0].outputs &&
                        batch.jobs[0].outputs.length > 0 && (
                          <button
                            type="button"
                            className="recent-jobs__action recent-jobs__action--ghost"
                            onClick={() => onViewOutputs(batch.jobs[0])}
                            title={t.recentJobs.viewAudiosHint}
                          >
                            {t.recentJobs.viewAudiosButton}
                          </button>
                        )}
                      {batch.jobs.length === 1 && batch.jobs[0].downloadUrl && (
                        <a
                          href={batch.jobs[0].downloadUrl}
                          className="recent-jobs__action recent-jobs__action--primary"
                          target="_blank"
                          rel="noopener noreferrer"
                        >
                          {t.recentJobs.downloadButton}
                        </a>
                      )}
                      {batch.jobs.length > 1 && batch.allCompleted && (
                        <button
                          type="button"
                          className="recent-jobs__action recent-jobs__action--primary"
                          onClick={() => toggleBatch(batch.batchId)}
                        >
                          View {batch.jobs.length} books
                        </button>
                      )}
                    </div>
                  )}
                </li>
              );
            })
          ) : (
            <li className="recent-jobs__item recent-jobs__item--empty">
              {t.recentJobs.empty}
            </li>
          )}
        </ul>
      )}
    </section>
  );
}
