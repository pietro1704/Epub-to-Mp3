import { ChapterProgressEntry } from '../types/conversion';
import { useTranslations } from '../i18n/I18nProvider';

interface ChapterProgressListProps {
  entries: ChapterProgressEntry[];
}

const STATUS_ICONS: Record<ChapterProgressEntry['status'], string> = {
  completed: '✅',
  processing: '⏳',
  pending: '•',
  skipped: '↷',
  failed: '⚠️',
  cancelled: '⛔',
};

export default function ChapterProgressList({ entries }: ChapterProgressListProps): JSX.Element | null {
  const t = useTranslations();
  if (!entries || entries.length === 0) {
    return null;
  }

  const completedCount = entries.filter((entry) => entry.status === 'completed').length;

  return (
    <div className="chapter-progress" aria-live="polite">
      <div className="chapter-progress__header">
        <h3>{t.status.chapterProgressTitle}</h3>
        <span className="chapter-progress__totals">
          {completedCount}/{entries.length}
        </span>
      </div>
      <ul className="chapter-progress__list">
        {entries.map((entry) => {
          const status = entry.status;
          const statusLabel = t.status.chapterStatuses?.[status] ?? status;
          return (
            <li key={`chapter-${entry.index}`} className={`chapter-progress__item chapter-progress__item--${status}`}>
              <span className="chapter-progress__icon" aria-hidden="true">
                {STATUS_ICONS[status] ?? '•'}
              </span>
              <span className="chapter-progress__name">
                {entry.index}. {entry.name}
              </span>
              <span className="chapter-progress__status" aria-label={statusLabel}>
                {statusLabel}
                {entry.status === 'completed' && typeof entry.elapsedSeconds === 'number' && (
                  <span className="chapter-progress__time">
                    {Math.round(entry.elapsedSeconds)}s
                    {typeof entry.charsPerSecond === 'number'
                      ? ` (~${entry.charsPerSecond} chars/s)`
                      : ''}
                  </span>
                )}
              </span>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
