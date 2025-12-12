import { useEffect, useRef } from 'react';
import { ConversionState, StatusEntry, ConversionSummary } from '../types/conversion';
import { useI18n, useTranslations } from '../i18n/I18nProvider';
import type { Locale, Translations } from '../i18n/translations';

interface StatusPanelProps {
  entries: StatusEntry[];
  phase: ConversionState['phase'];
  jobId?: string;
  error?: string;
  etaSeconds?: number | null;
  showRawLog: boolean;
  onToggleRawLog: () => void;
  summary?: ConversionSummary;
  cliCommand?: string;
}

export default function StatusPanel({
  entries,
  phase,
  jobId,
  error,
  etaSeconds,
  showRawLog,
  onToggleRawLog,
  summary,
  cliCommand,
}: StatusPanelProps): JSX.Element {
  const t = useTranslations();
  const { locale } = useI18n();
  const rawLogRef = useRef<HTMLPreElement>(null);
  const timelineRef = useRef<HTMLUListElement>(null);
  const errorText = phase === 'error' && error ? t.status.errorPrefix.replace('{message}', error) : null;
  const timeLocale = locale === 'pt' ? 'pt-BR' : 'en-US';
  const toggleLabel = showRawLog ? t.status.toggleHide : t.status.toggleShow;
  const etaDisplay = formatEta(phase, etaSeconds, locale, t);
  const languageDisplay = summary?.detectedLanguage
    ? resolveLanguageLabel(summary.detectedLanguage, t)
    : '—';

  // Autoscroll when new entries are added
  useEffect(() => {
    if (showRawLog && rawLogRef.current) {
      rawLogRef.current.scrollTop = rawLogRef.current.scrollHeight;
    } else if (!showRawLog && timelineRef.current) {
      timelineRef.current.scrollTop = timelineRef.current.scrollHeight;
    }
  }, [entries, showRawLog]);

  return (
    <div className="status-panel">
      <div className="status-panel__meta">
        <span className={`status-chip status-chip--${phase}`}>{t.status.phases[phase]}</span>
        {jobId && <span className="status-panel__job">{t.status.jobLabel(jobId)}</span>}
      </div>

      <div className="status-panel__toolbar">
        <button type="button" className="status-panel__toggle" onClick={onToggleRawLog}>
          {toggleLabel}
        </button>
        {cliCommand && (
          <code className="status-panel__cli" title={cliCommand}>
            {cliCommand}
          </code>
        )}
        <div className="status-panel__eta">
          <span className="status-panel__eta-label">{t.status.etaLabel}</span>
          <span className="status-panel__eta-value">{etaDisplay}</span>
        </div>
      </div>

      {summary && (
        <div className="status-summary">
          <h3 className="status-summary__title">{t.status.summaryTitle}</h3>
          <dl>
          <div className="status-summary__row">
            <dt>{t.status.summaryLanguage}</dt>
            <dd>{languageDisplay}</dd>
          </div>
          <div className="status-summary__row">
            <dt>{t.status.summaryChapters}</dt>
            <dd>
              {summary.chaptersCompleted !== undefined && summary.chaptersTotal !== undefined
                ? `${summary.chaptersCompleted}/${summary.chaptersTotal}`
                : summary.chaptersTotal ?? '—'}
            </dd>
          </div>
          <div className="status-summary__row">
            <dt>{t.status.summaryCurrent}</dt>
            <dd>{summary.currentChapter ?? '—'}</dd>
          </div>
          <div className="status-summary__row">
            <dt>{t.status.summaryProgress}</dt>
            <dd>
              {summary.progressPercent !== undefined && summary.progressPercent !== null
                ? `${Math.min(100, Math.max(0, Math.round(summary.progressPercent)))}%`
                : '—'}
            </dd>
          </div>
          </dl>
        </div>
      )}

      {showRawLog ? (
        <pre className="status-panel__raw" aria-live="polite" ref={rawLogRef}>
          {entries.length > 0 ? entries.map((entry) => entry.message).join('\n') : t.status.placeholder}
        </pre>
      ) : (
        <ul className="status-timeline" aria-live="polite" ref={timelineRef}>
          {entries.map((entry) => (
            <li key={entry.id} className="status-timeline__item">
              <small className="status-timeline__time">
                {new Date(entry.timestamp).toLocaleTimeString(timeLocale, {
                  hour: '2-digit',
                  minute: '2-digit',
                  second: '2-digit',
                })}
              </small>
              <span className="status-timeline__message">{entry.message}</span>
            </li>
          ))}
          {entries.length === 0 && <li className="status-timeline__placeholder">{t.status.placeholder}</li>}
        </ul>
      )}

      {errorText && <p className="status-panel__error">{errorText}</p>}
    </div>
  );
}

function resolveLanguageLabel(code: string, t: Translations): string {
  if (!code) return '—';
  const direct = t.form.languageOptions?.[code];
  if (direct) return direct;
  const lowered = code.toLowerCase();
  const segments = lowered.split(/[-_]/);
  if (segments.length > 0) {
    const base = segments[0];
    const fallback = t.form.languageOptions?.[base];
    if (fallback) return fallback;
  }
  return code;
}

function formatEta(
  phase: ConversionState['phase'],
  etaSeconds: number | null | undefined,
  locale: Locale,
  t: Translations,
): string {
  if (phase === 'success') {
    return t.status.etaDone;
  }
  if (phase === 'error') {
    return '—';
  }
  if (phase === 'idle') {
    return '—';
  }
  if (typeof etaSeconds !== 'number') {
    return t.status.etaCalculating;
  }
  if (etaSeconds <= 1) {
    return t.status.etaSoon;
  }
  const minutes = Math.floor(etaSeconds / 60);
  const seconds = Math.max(0, Math.round(etaSeconds % 60));
  if (minutes >= 1) {
    return locale === 'pt' ? `≈ ${minutes} min` : `≈ ${minutes} min`;
  }
  return locale === 'pt' ? `≈ ${seconds} s` : `≈ ${seconds} s`;
}
