import { useEffect, useMemo, useRef } from 'react';
import { ConversionState, StatusEntry, ConversionSummary } from '../types/conversion';
import { useI18n, useTranslations } from '../i18n/I18nProvider';
import type { Locale, Translations } from '../i18n/translations';
import ChapterProgressList from './ChapterProgressList';

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
  onCancel?: () => void;
  canCancel?: boolean;
  cancelDisabled?: boolean;
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
  onCancel,
  canCancel,
  cancelDisabled,
}: StatusPanelProps): JSX.Element {
  const t = useTranslations();
  const { locale } = useI18n();
  const rawLogRef = useRef<HTMLPreElement>(null);
  const timelineRef = useRef<HTMLUListElement>(null);
  const showError = (phase === 'error' || phase === 'cancelled') && error;
  const errorText = showError ? t.status.errorPrefix.replace('{message}', error) : null;
  const timeLocale = locale === 'pt' ? 'pt-BR' : 'en-US';
  const toggleLabel = showRawLog ? t.status.toggleHide : t.status.toggleShow;
  const etaDisplay = formatEta(phase, etaSeconds, locale, t);
  const placeholderText = t.status.placeholder;
  const languageDisplay = summary?.detectedLanguage
    ? resolveLanguageLabel(summary.detectedLanguage, t)
    : '—';
  const progressValue = typeof summary?.progressPercent === 'number'
    ? Math.max(0, Math.min(100, summary.progressPercent))
    : null;
  const chapterProgress = summary?.chapterProgress ?? null;
  const timeFormatOptions = useMemo(() => ({
    hour: '2-digit' as const,
    minute: '2-digit' as const,
    second: '2-digit' as const,
  }), []);

  const rawLogText = useMemo(() => {
    if (entries.length === 0) {
      return placeholderText;
    }
    return entries
      .map((entry) => {
        const timestamp = new Date(entry.timestamp).toLocaleTimeString(timeLocale, timeFormatOptions);
        return `${timestamp} ${entry.message}`;
      })
      .join('\n');
  }, [entries, placeholderText, timeLocale, timeFormatOptions]);

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
        {canCancel && onCancel && (
          <button
            type="button"
            className="status-panel__cancel"
            onClick={onCancel}
            disabled={cancelDisabled}
          >
            {phase === 'cancelling' ? t.status.cancelButtonPending : t.status.cancelButton}
          </button>
        )}
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
          {typeof summary.parallelSlots === 'number' && summary.parallelSlots > 0 && (
            <div className="status-summary__row status-summary__row--parallel">
              <dt>{t.status.summaryParallel}</dt>
              <dd>
                <ParallelismMeter
                  slots={summary.parallelSlots}
                  active={summary.parallelActive ?? 0}
                />
              </dd>
            </div>
          )}
          </dl>
        </div>
      )}
      {progressValue !== null && (
        <div className="status-progress">
          <div className="status-progress__label">{t.status.progressLabel}</div>
          <div className="status-progress__bar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={progressValue}>
            <div className="status-progress__fill" style={{ width: `${progressValue}%` }} />
          </div>
          <div className="status-progress__value">{progressValue.toFixed(1)}%</div>
        </div>
      )}
      {chapterProgress && chapterProgress.length > 0 && (
        <ChapterProgressList entries={chapterProgress} />
      )}

      {showRawLog ? (
        <pre className="status-panel__raw" aria-live="polite" ref={rawLogRef}>
          {rawLogText}
        </pre>
      ) : (
        <ul className="status-timeline" aria-live="polite" ref={timelineRef}>
          {entries.map((entry) => (
            <li key={entry.id} className="status-timeline__item">
              <small className="status-timeline__time">
                {new Date(entry.timestamp).toLocaleTimeString(timeLocale, timeFormatOptions)}
              </small>
              <span className="status-timeline__message">{entry.message}</span>
            </li>
          ))}
          {entries.length === 0 && <li className="status-timeline__placeholder">{placeholderText}</li>}
        </ul>
      )}

      {errorText && <p className="status-panel__error">{errorText}</p>}
    </div>
  );
}

interface ParallelismMeterProps {
  slots: number;
  active: number;
}

function ParallelismMeter({ slots, active }: ParallelismMeterProps): JSX.Element {
  const normalizedSlots = Math.max(1, Math.min(Math.floor(slots), 12));
  const clampedActive = Math.max(0, Math.min(Math.floor(active), slots));
  const items = Array.from({ length: normalizedSlots }, (_, index) => {
    const filled = index < clampedActive;
    return (
      <span
        key={`parallel-slot-${index}`}
        className={`parallel-meter__slot${filled ? ' parallel-meter__slot--active' : ''}`}
        aria-hidden="true"
      />
    );
  });
  return (
    <div className="parallel-meter" aria-label={`${clampedActive}/${slots} slots`}>
      <span className="parallel-meter__count">
        {clampedActive}/{slots}
      </span>
      <div className="parallel-meter__slots">
        {items}
      </div>
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
  if (phase === 'error' || phase === 'cancelled') {
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
  const totalSeconds = Math.max(0, Math.round(etaSeconds));
  const units: Array<{ label: string; value: number }> = [
    { label: 'd', value: 86400 },
    { label: 'h', value: 3600 },
    { label: 'm', value: 60 },
    { label: 's', value: 1 },
  ];
  let remainder = totalSeconds;
  const parts: string[] = [];
  for (const unit of units) {
    const qty = Math.floor(remainder / unit.value);
    if (qty > 0) {
      parts.push(`${qty}${unit.label}`);
      remainder -= qty * unit.value;
    }
    if (parts.length >= 2) {
      break;
    }
  }
  if (parts.length === 0) {
    parts.push('0s');
  }
  const humanEta = parts.join(' ');
  return locale === 'pt' ? `≈ ${humanEta}` : `≈ ${humanEta}`;
}
