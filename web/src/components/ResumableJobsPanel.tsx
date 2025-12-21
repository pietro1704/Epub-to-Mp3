import { useTranslations } from '../i18n/I18nProvider';

interface ResumableJobEntry {
  jobId: string;
  fileName: string;
  timestamp: number;
  engine?: string;
  voice?: string;
  language?: string;
}

interface ResumableJobsPanelProps {
  jobs: ResumableJobEntry[];
  onResume: (jobId: string) => void;
}

export default function ResumableJobsPanel({ jobs, onResume }: ResumableJobsPanelProps): JSX.Element {
  const t = useTranslations();
  const hasJobs = Array.isArray(jobs) && jobs.length > 0;

  const formatWhen = (timestamp: number): string => {
    if (!timestamp || Number.isNaN(timestamp)) return t.resumableJobs.justNow;
    const diff = Date.now() - timestamp;
    const minutes = Math.floor(diff / 60000);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);
    if (days > 0) return t.resumableJobs.daysAgo(days);
    if (hours > 0) return t.resumableJobs.hoursAgo(hours);
    if (minutes > 0) return t.resumableJobs.minutesAgo(minutes);
    return t.resumableJobs.justNow;
  };

  const formatLanguage = (code?: string | null): string | null => {
    if (!code) return null;
    const normalized = code.toLowerCase();
    const map = t.form.languageOptions ?? {};
    if (map[normalized]) {
      return map[normalized];
    }
    const base = normalized.split(/[-_]/)[0];
    if (map[base]) {
      return map[base];
    }
    return code.toUpperCase();
  };

  return (
    <section className="resumable-jobs">
      <div className="resumable-jobs__header">
        <div>
          <h3>{t.resumableJobs.title}</h3>
          <p>{t.resumableJobs.subtitle}</p>
        </div>
      </div>
      <ul className="resumable-jobs__list">
        {hasJobs ? (
          jobs.map((job) => {
            const languageDisplay = formatLanguage(job.language);
            return (
              <li key={job.jobId} className="resumable-jobs__item">
                <div className="resumable-jobs__meta">
                  <strong className="resumable-jobs__title">{job.fileName}</strong>
                  <span className="resumable-jobs__time">{formatWhen(job.timestamp)}</span>
                </div>
                <div className="resumable-jobs__details">
                  {job.engine && <span>{t.resumableJobs.engineLabel(job.engine)}</span>}
                  {job.voice && <span>{t.resumableJobs.voiceLabel(job.voice)}</span>}
                  {languageDisplay && <span>{t.resumableJobs.languageLabel(languageDisplay)}</span>}
                </div>
                <button type="button" className="resumable-jobs__action" onClick={() => onResume(job.jobId)}>
                  {t.resumableJobs.resumeButton}
                </button>
              </li>
            );
          })
        ) : (
          <li className="resumable-jobs__item resumable-jobs__item--empty">
            {t.resumableJobs.empty}
          </li>
        )}
      </ul>
    </section>
  );
}
