import { EngineStatus } from '../types/conversion';
import type { Locale, Translations } from '../i18n/translations';

export interface ParallelismMeterProps {
  slots: number;
  active: number;
}

export function ParallelismMeter({ slots, active }: ParallelismMeterProps): JSX.Element {
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
      <div className="parallel-meter__slots">{items}</div>
    </div>
  );
}

export function resolveLanguageLabel(code: string, t: Translations): string {
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

export interface EngineStatusDisplayProps {
  status: EngineStatus;
  locale: Locale;
}

export const ENGINE_STATUS_ICONS: Record<EngineStatus['status'], string> = {
  idle: '⏸️',
  downloading: '⬇️',
  loading: '🔄',
  ready: '✅',
  error: '❌',
};

export function EngineStatusDisplay({ status, locale }: EngineStatusDisplayProps): JSX.Element {
  const statusLabels: Record<EngineStatus['status'], { pt: string; en: string }> = {
    idle: { pt: 'Aguardando', en: 'Idle' },
    downloading: { pt: 'Baixando modelo', en: 'Downloading model' },
    loading: { pt: 'Carregando modelo', en: 'Loading model' },
    ready: { pt: 'Pronto', en: 'Ready' },
    error: { pt: 'Erro', en: 'Error' },
  };

  const label = statusLabels[status.status]?.[locale] ?? status.status;
  const icon = ENGINE_STATUS_ICONS[status.status] ?? '•';

  return (
    <div className="engine-status">
      <span className="engine-status__icon" aria-hidden="true">
        {icon}
      </span>
      <span className="engine-status__engine">{status.engine.toUpperCase()}</span>
      <span className="engine-status__label">{label}</span>
      {status.message && <span className="engine-status__message">{status.message}</span>}
      {status.status === 'downloading' && typeof status.progress === 'number' && (
        <span className="engine-status__progress">({Math.round(status.progress)}%)</span>
      )}
    </div>
  );
}
