import { RecentJobEntry } from '../types/conversion';
import { useTranslations } from '../i18n/I18nProvider';

interface RecentJobsPanelProps {
  jobs: RecentJobEntry[];
  onResume: (jobId: string) => void;
  onViewOutputs?: (job: RecentJobEntry) => void;
}

export default function RecentJobsPanel({ jobs, onResume, onViewOutputs }: RecentJobsPanelProps): JSX.Element {
  const t = useTranslations();
  const hasJobs = Array.isArray(jobs) && jobs.length > 0;

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

  return (
    <section className="recent-jobs">
      <div className="recent-jobs__header">
        <div>
          <h3>{t.recentJobs.title}</h3>
          <p>{t.recentJobs.subtitle}</p>
        </div>
      </div>
      <ul className="recent-jobs__list">
        {hasJobs ? (
          jobs.map((job) => (
            <li key={job.jobId} className="recent-jobs__item">
              <div className="recent-jobs__meta">
                <div className="recent-jobs__info">
                  <strong className="recent-jobs__title" title={job.bookTitle}>{job.bookTitle}</strong>
                  <p className="recent-jobs__filename" title={job.fileName}>{job.fileName}</p>
                </div>
                <div className="recent-jobs__status">
                  <span className={`recent-jobs__badge recent-jobs__badge--${job.state}`}>
                    {stateLabel(job.state)}
                  </span>
                  <span className="recent-jobs__time">{formatWhen(job.savedAt)}</span>
                </div>
              </div>
              <div className="recent-jobs__actions">
                {job.canResume && (
                  <button type="button" onClick={() => onResume(job.jobId)} className="recent-jobs__action">
                    {t.recentJobs.resumeButton}
                  </button>
                )}
                {onViewOutputs && job.outputs && job.outputs.length > 0 && (
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
                  <a href={job.downloadUrl} className="recent-jobs__action recent-jobs__action--primary" target="_blank" rel="noopener noreferrer">
                    {t.recentJobs.downloadButton}
                  </a>
                )}
              </div>
            </li>
          ))
        ) : (
          <li className="recent-jobs__item recent-jobs__item--empty">
            {t.recentJobs.empty}
          </li>
        )}
      </ul>
    </section>
  );
}
