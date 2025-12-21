import { useEffect, useMemo, useState } from 'react';
import { useI18n, useTranslations } from '../i18n/I18nProvider';
import type { ConversionSummary, ConversionState } from '../types/conversion';
import { formatEta } from './StatusPanel';

interface HeroProps {
  title?: string;
  author?: string;
  coverUrl?: string;
  summary?: ConversionSummary;
  etaSeconds?: number | null;
  phase: ConversionState['phase'];
  voiceLabel?: string;
  engineLabel?: string;
  languageLabel?: string;
}

export default function Hero({
  title,
  author,
  coverUrl,
  summary,
  etaSeconds,
  phase,
  voiceLabel,
  engineLabel,
  languageLabel,
}: HeroProps): JSX.Element {
  const t = useTranslations();
  const { locale } = useI18n();
  const highlights = t.hero.highlights ?? [];
  const [isCollapsed, setIsCollapsed] = useState(false);

  const progressValue = useMemo(() => {
    if (summary?.progressPercent !== undefined && summary?.progressPercent !== null) {
      return Math.min(100, Math.max(0, summary.progressPercent));
    }
    if (typeof summary?.chaptersCompleted === 'number' && typeof summary?.chaptersTotal === 'number' && summary.chaptersTotal > 0) {
      const computed = (summary.chaptersCompleted / summary.chaptersTotal) * 100;
      return Math.min(100, Math.max(0, computed));
    }
    return null;
  }, [summary]);

  const hasMetadata = Boolean(
    (title && title.trim()) ||
    (author && author.trim()) ||
    coverUrl ||
    progressValue !== null ||
    (summary?.currentChapter && summary.currentChapter.trim()),
  );
  const shouldShowStatusCard = hasMetadata || phase !== 'idle';
  const etaDisplay = formatEta(phase, etaSeconds, locale, t);
  const displayTitle = title?.trim() || t.status.bookFallbackTitle;
  const displayAuthor = author?.trim() || t.status.bookFallbackAuthor;
  const displayVoice = voiceLabel ?? '';
  const displayEngine = engineLabel ?? '';
  const displayLanguage = languageLabel ?? '';

  const chapterInfo = useMemo(() => {
    if (typeof summary?.chaptersCompleted === 'number' && typeof summary?.chaptersTotal === 'number') {
      return `${summary.chaptersCompleted}/${summary.chaptersTotal}`;
    }
    if (typeof summary?.chaptersTotal === 'number') {
      return `${summary.chaptersTotal}`;
    }
    return null;
  }, [summary]);

  useEffect(() => {
    if (typeof window === 'undefined') {
      return;
    }
    if (!shouldShowStatusCard) {
      setIsCollapsed(false);
      return;
    }
    const collapseThreshold = 180;
    const expandThreshold = 120;
    let ticking = false;

    const onScroll = () => {
      if (ticking) return;
      ticking = true;
      window.requestAnimationFrame(() => {
        const currentY = window.scrollY;
        setIsCollapsed((prev) => {
          if (!prev && currentY > collapseThreshold) {
            return true;
          }
          if (prev && currentY < expandThreshold) {
            return false;
          }
          return prev;
        });
        ticking = false;
      });
    };
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, [shouldShowStatusCard]);

  const heroClasses = [
    'hero',
    shouldShowStatusCard ? 'hero--active' : '',
    shouldShowStatusCard && isCollapsed ? 'hero--collapsed' : '',
  ].filter(Boolean).join(' ');

  return (
    <>
      <header className={heroClasses}>
        {shouldShowStatusCard ? (
          <div className="hero__book">
          <div className="hero__book-cover">
            {coverUrl ? (
              <img src={coverUrl} alt={displayTitle} loading="lazy" decoding="async" />
            ) : (
              <span aria-hidden="true" role="img">📘</span>
            )}
          </div>
          <div className="hero__book-body">
            <p className="badge badge--muted">{t.hero.badge}</p>
            <h1>{displayTitle}</h1>
            <p className="hero__author">{displayAuthor}</p>
            {(summary?.currentChapter || chapterInfo) && (
              <p className="hero__chapter">
                {summary?.currentChapter ?? ''}
                {summary?.currentChapter && chapterInfo ? ' · ' : ''}
                {chapterInfo ?? ''}
              </p>
            )}
            {(displayEngine || displayVoice || displayLanguage) && (
              <div className="hero__meta">
                {displayEngine && (
                  <span>
                    {t.activeConversion.engineLabel}: <strong>{displayEngine}</strong>
                  </span>
                )}
                {displayVoice && (
                  <span>
                    {t.activeConversion.voiceLabel}: <strong>{displayVoice}</strong>
                  </span>
                )}
                {displayLanguage && (
                  <span>
                    {t.activeConversion.languageLabel}: <strong>{displayLanguage}</strong>
                  </span>
                )}
              </div>
            )}
            <div className="hero__progress">
              <div className="hero__progress-info">
                <span>{t.status.progressLabel}</span>
                <strong>{progressValue !== null ? `${progressValue.toFixed(1)}%` : '—'}</strong>
              </div>
              <div
                className="hero__progress-bar"
                role="progressbar"
                aria-valuemin={0}
                aria-valuemax={100}
                aria-valuenow={progressValue ?? 0}
              >
                <div className="hero__progress-fill" style={{ width: `${progressValue ?? 0}%` }} />
              </div>
              <div className="hero__progress-info hero__progress-info--eta">
                <span>{t.status.etaLabel}</span>
                <strong>{etaDisplay}</strong>
              </div>
            </div>
          </div>
          </div>
        ) : (
          <>
            <div className="hero__copy">
            <p className="badge">{t.hero.badge}</p>
            <h1>{t.hero.title}</h1>
            <p className="hero__subtitle">{t.hero.subtitle}</p>
            </div>
            {highlights.length > 0 && (
              <div className="hero__highlights">
              {highlights.map((highlight) => (
                <article key={highlight.title} className="hero__highlight">
                  <h3>{highlight.title}</h3>
                  <p>{highlight.description}</p>
                </article>
              ))}
            </div>
            )}
          </>
        )}
        {shouldShowStatusCard && (
          <div className="hero__collapsed-summary" aria-live="polite">
          <div className="hero__collapsed-cover">
            {coverUrl ? (
              <img src={coverUrl} alt={displayTitle} loading="lazy" decoding="async" />
            ) : (
              <span aria-hidden="true">📘</span>
            )}
          </div>
          <div className="hero__collapsed-body">
            <p className="hero__collapsed-title">{displayTitle}</p>
            <p className="hero__collapsed-progress">
              {progressValue !== null ? `${progressValue.toFixed(1)}%` : '—'} · {etaDisplay}
            </p>
            <div
              className="hero__collapsed-bar"
              role="progressbar"
              aria-valuemin={0}
              aria-valuemax={100}
              aria-valuenow={progressValue ?? 0}
            >
              <div className="hero__collapsed-fill" style={{ width: `${progressValue ?? 0}%` }} />
            </div>
          </div>
        </div>
        )}
      </header>
      {shouldShowStatusCard && (
        <div
          className={['hero__spacer', isCollapsed ? 'hero__spacer--collapsed' : ''].filter(Boolean).join(' ')}
          aria-hidden="true"
        />
      )}
    </>
  );
}
