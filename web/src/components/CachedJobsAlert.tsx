import { useTranslations } from "../i18n/I18nProvider";

interface CachedJob {
  jobId: string;
  fileName: string;
  timestamp: number;
}

interface CachedJobsAlertProps {
  cachedJobs: CachedJob[];
  onResume: (jobId: string) => void;
  onDismiss: () => void;
  onRemove: (jobId: string) => void;
}

export default function CachedJobsAlert({
  cachedJobs,
  onResume,
  onDismiss,
  onRemove,
}: CachedJobsAlertProps): JSX.Element | null {
  const t = useTranslations();
  if (cachedJobs.length === 0) return null;

  const formatTime = (timestamp: number): string => {
    const now = Date.now();
    const diff = now - timestamp;
    const minutes = Math.floor(diff / 60000);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);

    if (days > 0) return t.status.cachedJobsDaysAgo(days);
    if (hours > 0) return t.status.cachedJobsHoursAgo(hours);
    if (minutes > 0) return t.status.cachedJobsMinutesAgo(minutes);
    return t.status.cachedJobsJustNow;
  };

  return (
    <div className="cached-jobs-alert">
      <div className="cached-jobs-alert__header">
        <h3>🔄 {t.status.cachedJobsTitle}</h3>
        <button
          type="button"
          className="cached-jobs-alert__close"
          onClick={onDismiss}
          aria-label={t.status.cachedJobsClose}
        >
          ✕
        </button>
      </div>
      <p className="cached-jobs-alert__message">
        {cachedJobs.length === 1
          ? t.status.cachedJobsSingular
          : t.status.cachedJobsPlural(cachedJobs.length)}
      </p>
      <ul className="cached-jobs-alert__list">
        {cachedJobs.map((job) => (
          <li key={job.jobId} className="cached-jobs-alert__item">
            <div className="cached-jobs-alert__info">
              <span
                className="cached-jobs-alert__filename"
                title={job.fileName}
              >
                <span aria-hidden="true">📄</span>
                <span className="cached-jobs-alert__filename-text">
                  {job.fileName}
                </span>
              </span>
              <span className="cached-jobs-alert__time">
                {formatTime(job.timestamp)}
              </span>
            </div>
            <button
              type="button"
              className="cached-jobs-alert__resume"
              onClick={() => onResume(job.jobId)}
            >
              {t.status.cachedJobsResume}
            </button>
            <button
              type="button"
              className="cached-jobs-alert__remove"
              onClick={() => onRemove(job.jobId)}
              aria-label={t.status.cachedJobsRemove(job.fileName)}
            >
              ✕
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
