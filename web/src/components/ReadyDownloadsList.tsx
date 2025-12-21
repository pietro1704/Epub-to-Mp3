import { RecentJobEntry } from '../types/conversion';
import { useTranslations } from '../i18n/I18nProvider';

export type ReadyDownloadJob = RecentJobEntry & {
  source: 'current' | 'recent';
  savedAtMs: number;
};

interface ReadyDownloadsListProps {
  jobs: ReadyDownloadJob[];
  activeJobId?: string;
  onSelect: (job: ReadyDownloadJob) => void;
}

export default function ReadyDownloadsList({ jobs, activeJobId, onSelect }: ReadyDownloadsListProps): JSX.Element | null {
  const t = useTranslations();
  if (!jobs || jobs.length === 0) {
    return null;
  }

  const formatChapterLabel = (job: RecentJobEntry): string | null => {
    if (typeof job.chaptersCompleted === 'number' && job.chaptersCompleted > 0) {
      return t.downloads.readyListItem(job.chaptersCompleted);
    }
    if (Array.isArray(job.outputs)) {
      const chapterCount = job.outputs.filter((asset) => asset.name.toLowerCase().endsWith('.mp3')).length;
      if (chapterCount > 0) {
        return t.downloads.readyListItem(chapterCount);
      }
    }
    return null;
  };

  const formatSourceTag = (source: ReadyDownloadJob['source']): string => {
    return source === 'current' ? t.downloads.readyListTagCurrent : t.downloads.readyListTagPast;
  };

  return (
    <section className="ready-downloads" aria-label={t.downloads.readyListAriaLabel}>
      <div className="ready-downloads__header">
        <h4>{t.downloads.readyListTitle}</h4>
        <p>{t.downloads.readyListSubtitle}</p>
      </div>
      <div className="ready-downloads__list">
        {jobs.map((job) => {
          const isActive = activeJobId === job.jobId;
          const chapterLabel = formatChapterLabel(job);
          const tagLabel = formatSourceTag(job.source);
          return (
            <button
              key={job.jobId}
              type="button"
              className={`ready-downloads__item${isActive ? ' ready-downloads__item--active' : ''}`}
              onClick={() => onSelect(job)}
              aria-pressed={isActive}
            >
              <div className="ready-downloads__info">
                <strong title={job.bookTitle}>{job.bookTitle}</strong>
                <div className="ready-downloads__meta">
                  {chapterLabel && <span>{chapterLabel}</span>}
                  <span className={`ready-downloads__tag ready-downloads__tag--${job.source}`}>{tagLabel}</span>
                </div>
              </div>
              <span className="ready-downloads__action">{t.downloads.readyListAction}</span>
            </button>
          );
        })}
      </div>
    </section>
  );
}
