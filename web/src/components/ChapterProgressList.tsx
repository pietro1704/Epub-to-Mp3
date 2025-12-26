import { useCallback, useEffect, useRef } from 'react';
import { ChapterProgressEntry } from '../types/conversion';
import { useI18n, useTranslations } from '../i18n/I18nProvider';

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
  const { locale } = useI18n();
  const containerRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLUListElement>(null);
  const headerRef = useRef<HTMLDivElement>(null);

  if (!entries || entries.length === 0) {
    return null;
  }

  const completedCount = entries.filter((entry) => entry.status === 'completed').length;

  const scrollToCurrent = useCallback((behavior: ScrollBehavior = 'smooth') => {
    const container = containerRef.current;
    const list = listRef.current;
    if (!container || !list) return;

    // Find first processing item, or last completed item
    const processingIndex = entries.findIndex(e => e.status === 'processing');
    const targetIndex = processingIndex >= 0 ? processingIndex : entries.findIndex(e => e.status === 'completed');

    if (targetIndex >= 0) {
      const items = list.children;
      const target = items[targetIndex] as HTMLElement | undefined;
      if (target) {
        const containerRect = container.getBoundingClientRect();
        const targetRect = target.getBoundingClientRect();
        const headerHeight = headerRef.current?.offsetHeight ?? 0;
        const relativeTop = targetRect.top - containerRect.top + container.scrollTop - headerHeight;
        const viewportHeight = container.clientHeight - headerHeight;
        const offset = Math.max(0, relativeTop - Math.max(0, (viewportHeight - targetRect.height) / 2));
        container.scrollTo({ top: offset, behavior });
      }
    }
  }, [entries]);

  useEffect(() => {
    scrollToCurrent('auto');
  }, [scrollToCurrent]);

  return (
    <div className="chapter-progress" aria-live="polite" ref={containerRef}>
      <div className="chapter-progress__header" ref={headerRef}>
        <h3>{t.status.chapterProgressTitle}</h3>
        <div style={{ display: 'flex', gap: '0.75rem', alignItems: 'center' }}>
          <button
            type="button"
            className="status-panel__toggle"
            onClick={() => scrollToCurrent('smooth')}
            title={locale === 'pt' ? 'Ir para o capítulo atual' : 'Go to current chapter'}
            style={{ fontSize: '0.8rem', padding: '0.35rem 0.75rem' }}
          >
            ↓ {locale === 'pt' ? 'Ver atual' : 'Go to current'}
          </button>
          <span className="chapter-progress__totals">
            {completedCount}/{entries.length}
          </span>
        </div>
      </div>
      <ul className="chapter-progress__list" ref={listRef}>
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
                {entry.status === 'completed' && (
                  <>
                    <span className="chapter-progress__time">
                      {formatChapterDuration(entry.elapsedSeconds) ?? '--'}
                      {typeof entry.charsPerSecond === 'number'
                        ? ` • ~${entry.charsPerSecond} chars/s`
                        : ''}
                    </span>
                    {entry.downloadUrl && (
                      <a
                        href={entry.downloadUrl}
                        download
                        className="chapter-progress__download"
                        title={locale === 'pt' ? 'Baixar capítulo' : 'Download chapter'}
                        onClick={(e) => e.stopPropagation()}
                      >
                        💾 {locale === 'pt' ? 'Download' : 'Download'}
                      </a>
                    )}
                  </>
                )}
              </span>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

function formatChapterDuration(value?: number): string | null {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return null;
  }
  const total = Math.max(0, Math.round(value));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const parts: string[] = [];
  if (hours > 0) {
    parts.push(`${hours.toString().padStart(2, '0')}h`);
  }
  if (hours > 0 || minutes > 0) {
    parts.push(`${minutes.toString().padStart(2, '0')}m`);
  }
  parts.push(`${seconds.toString().padStart(2, '0')}s`);
  return `Concluído em ${parts.join(' ')}`;
}
