import { RecentJobEntry } from "../types/conversion";
import { useI18n, useTranslations } from "../i18n/I18nProvider";

export type ReadyDownloadJob = RecentJobEntry & {
  source: "current" | "recent";
  savedAtMs: number;
};

interface ReadyDownloadsListProps {
  jobs: ReadyDownloadJob[];
  activeJobId?: string;
  onSelect: (job: ReadyDownloadJob) => void;
  onRemove?: (jobId: string) => void;
}

export default function ReadyDownloadsList({
  jobs,
  activeJobId,
  onSelect,
  onRemove,
}: ReadyDownloadsListProps): JSX.Element | null {
  const t = useTranslations();
  const { locale } = useI18n();
  if (!jobs || jobs.length === 0) {
    return null;
  }

  const formatChapterLabel = (job: RecentJobEntry): string | null => {
    if (
      typeof job.chaptersCompleted === "number" &&
      job.chaptersCompleted > 0
    ) {
      return t.downloads.readyListItem(job.chaptersCompleted);
    }
    if (Array.isArray(job.outputs)) {
      const chapterCount = job.outputs.filter((asset) =>
        asset.name.toLowerCase().endsWith(".mp3"),
      ).length;
      if (chapterCount > 0) {
        return t.downloads.readyListItem(chapterCount);
      }
    }
    return null;
  };

  const formatSourceTag = (source: ReadyDownloadJob["source"]): string => {
    return source === "current"
      ? t.downloads.readyListTagCurrent
      : t.downloads.readyListTagPast;
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

  const collectZipUrl = (job: ReadyDownloadJob): string | null => {
    if (job.downloadUrl) {
      return job.downloadUrl;
    }
    if (Array.isArray(job.outputs)) {
      const asset = job.outputs.find((entry) =>
        entry.name?.toLowerCase().endsWith(".zip"),
      );
      if (asset?.url) {
        return asset.url;
      }
    }
    return null;
  };

  const bulkZipUrls = jobs
    .map((job) => ({ job, url: collectZipUrl(job) }))
    .filter((entry): entry is { job: ReadyDownloadJob; url: string } =>
      Boolean(entry.url),
    );

  const handleBulkDownload = () => {
    if (bulkZipUrls.length === 0) {
      return;
    }
    bulkZipUrls.forEach((entry, index) => {
      setTimeout(() => {
        const url = entry.url;
        if (typeof window !== "undefined" && url) {
          window.open(url, "_blank", "noopener,noreferrer");
        }
      }, index * 250);
    });
  };

  return (
    <section
      className="ready-downloads"
      aria-label={t.downloads.readyListAriaLabel}
    >
      <div className="ready-downloads__header">
        <h4>{t.downloads.readyListTitle}</h4>
        <p>{t.downloads.readyListSubtitle}</p>
      </div>
      <div className="ready-downloads__list">
        {jobs.map((job) => {
          const isActive = activeJobId === job.jobId;
          const chapterLabel = formatChapterLabel(job);
          const tagLabel = formatSourceTag(job.source);
          const completedLabel = formatDateTime(job.completedAt ?? job.savedAt);
          const durationLabel = formatDuration(job.totalDurationSeconds);
          return (
            <div key={job.jobId} className="ready-downloads__item-wrapper">
              <button
                type="button"
                className={`ready-downloads__item${isActive ? " ready-downloads__item--active" : ""}`}
                onClick={() => onSelect(job)}
                aria-pressed={isActive}
              >
                <div className="ready-downloads__info">
                  <strong title={job.bookTitle}>{job.bookTitle}</strong>
                  <div className="ready-downloads__meta">
                    {chapterLabel && <span>{chapterLabel}</span>}
                    <span
                      className={`ready-downloads__tag ready-downloads__tag--${job.source}`}
                    >
                      {tagLabel}
                    </span>
                  </div>
                  {(completedLabel || durationLabel) && (
                    <div className="ready-downloads__details">
                      {completedLabel && (
                        <span>
                          {t.downloads.readyListCompletedAt(completedLabel)}
                        </span>
                      )}
                      {durationLabel && (
                        <span>
                          {t.downloads.readyListDuration(durationLabel)}
                        </span>
                      )}
                    </div>
                  )}
                </div>
                <span className="ready-downloads__action">
                  {t.downloads.readyListAction}
                </span>
              </button>
              {onRemove && job.source === "recent" && (
                <button
                  type="button"
                  className="ready-downloads__remove"
                  onClick={(e) => {
                    e.stopPropagation();
                    onRemove(job.jobId);
                  }}
                  aria-label={t.downloads.removeButton || "Remove"}
                  title={t.downloads.removeButton || "Remove"}
                >
                  ×
                </button>
              )}
            </div>
          );
        })}
      </div>
      {bulkZipUrls.length > 1 && (
        <div className="ready-downloads__bulk">
          <button
            type="button"
            className="ready-downloads__bulk-button"
            onClick={handleBulkDownload}
          >
            {t.downloads.readyListDownloadAll}
          </button>
          <p className="ready-downloads__bulk-hint">
            {t.downloads.readyListDownloadAllHint}
          </p>
        </div>
      )}
    </section>
  );
}
