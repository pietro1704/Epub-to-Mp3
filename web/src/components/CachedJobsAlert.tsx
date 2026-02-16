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
  if (cachedJobs.length === 0) return null;

  const formatTime = (timestamp: number): string => {
    const now = Date.now();
    const diff = now - timestamp;
    const minutes = Math.floor(diff / 60000);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);

    if (days > 0) return `${days} day${days > 1 ? "s" : ""} ago`;
    if (hours > 0) return `${hours} hour${hours > 1 ? "s" : ""} ago`;
    if (minutes > 0) return `${minutes} minute${minutes > 1 ? "s" : ""} ago`;
    return "just now";
  };

  return (
    <div className="cached-jobs-alert">
      <div className="cached-jobs-alert__header">
        <h3>🔄 Interrupted Conversions</h3>
        <button
          type="button"
          className="cached-jobs-alert__close"
          onClick={onDismiss}
          aria-label="Close notice"
        >
          ✕
        </button>
      </div>
      <p className="cached-jobs-alert__message">
        {cachedJobs.length === 1
          ? "We found 1 interrupted conversion. Do you want to resume it?"
          : `We found ${cachedJobs.length} interrupted conversions. Do you want to resume one?`}
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
              Resume
            </button>
            <button
              type="button"
              className="cached-jobs-alert__remove"
              onClick={() => onRemove(job.jobId)}
              aria-label={`Remove ${job.fileName}`}
            >
              ✕
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
