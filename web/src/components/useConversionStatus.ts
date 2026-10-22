import { useMemo, useRef, useState } from 'react';
import {
  ConversionState,
  StatusEntry,
  ConversionSummary,
  PlaybackIndicator,
} from '../types/conversion';
import { useI18n, useTranslations } from '../i18n/I18nProvider';
import { formatEta } from '../utils/formatEta';
import { resolveLanguageLabel } from './ConversionSummaryIndicators';

export interface StatusPanelProps {
  entries: StatusEntry[];
  rawLog?: string[];
  phase: ConversionState['phase'];
  phaseLabelOverride?: string;
  jobId?: string;
  error?: string;
  errorCategory?: string;
  etaSeconds?: number | null;
  showRawLog: boolean;
  onToggleRawLog: () => void;
  summary?: ConversionSummary;
  cliCommand?: string;
  cliShell?: ConversionState['cliShell'];
  onCancel?: () => void;
  onSkip?: () => void;
  canCancel?: boolean;
  canSkip?: boolean;
  cancelDisabled?: boolean;
  bookTitle?: string;
  bookAuthor?: string;
  coverUrl?: string;
}

export function useConversionStatus({
  entries,
  rawLog,
  phase,
  phaseLabelOverride,
  jobId,
  error,
  errorCategory,
  etaSeconds,
  showRawLog,
  onToggleRawLog,
  summary,
  cliCommand,
  cliShell,
  onCancel,
  onSkip,
  canCancel,
  canSkip,
  cancelDisabled,
  bookTitle,
  bookAuthor,
  coverUrl,
}: StatusPanelProps) {
  const t = useTranslations();
  const { locale } = useI18n();
  const rawLogRef = useRef<HTMLPreElement>(null);
  const showError = (phase === 'error' || phase === 'cancelled') && error;
  const [playingSegment, setPlayingSegment] = useState<PlaybackIndicator | null>(null);
  const [readerStartRequestId, setReaderStartRequestId] = useState(0);
  const [readerOpen, setReaderOpen] = useState(false);
  const [readerPopup, setReaderPopup] = useState(false);

  const errorText = showError ? t.status.errorPrefix.replace('{message}', error) : null;
  const errorHint =
    showError && errorCategory ? (t.status.errorCategoryHints[errorCategory] ?? null) : null;
  const timeLocale = locale === 'pt' ? 'pt-BR' : 'en-US';
  const toggleLabel = showRawLog ? t.status.toggleHide : t.status.toggleShow;
  const etaDisplay = formatEta(phase, etaSeconds, locale, t);
  const placeholderText = t.status.placeholder;
  const languageDisplay = summary?.detectedLanguage
    ? resolveLanguageLabel(summary.detectedLanguage, t)
    : '—';
  const progressValue = useMemo(() => {
    if (typeof summary?.progressPercent === 'number') {
      return Math.max(0, Math.min(100, summary.progressPercent));
    }
    if (
      typeof summary?.chaptersCompleted === 'number' &&
      typeof summary?.chaptersTotal === 'number' &&
      summary.chaptersTotal > 0
    ) {
      const computed = (summary.chaptersCompleted / summary.chaptersTotal) * 100;
      return Math.max(0, Math.min(100, computed));
    }
    return null;
  }, [summary]);
  const chapterProgress = summary?.chapterProgress ?? null;
  const speedSamples = useMemo(
    () =>
      (chapterProgress ?? [])
        .map((entry) => entry.charsPerSecond)
        .filter(
          (value): value is number =>
            typeof value === 'number' && Number.isFinite(value) && value > 0,
        ),
    [chapterProgress],
  );
  const recentSpeed = speedSamples.length > 0 ? speedSamples[speedSamples.length - 1] : null;
  const averageSpeed =
    speedSamples.length > 0
      ? speedSamples.reduce((sum, value) => sum + value, 0) / speedSamples.length
      : null;
  const timeFormatOptions = useMemo(
    () => ({
      hour: '2-digit' as const,
      minute: '2-digit' as const,
      second: '2-digit' as const,
    }),
    [],
  );

  const rawLogText = useMemo(() => {
    if (rawLog && rawLog.length > 0) {
      return rawLog.join('\n');
    }
    if (entries.length === 0) {
      return placeholderText;
    }
    return entries
      .map((entry) => {
        const timestamp = new Date(entry.timestamp).toLocaleTimeString(
          timeLocale,
          timeFormatOptions,
        );
        return `${timestamp} ${entry.message}`;
      })
      .join('\n');
  }, [rawLog, entries, placeholderText, timeLocale, timeFormatOptions]);

  return {
    phase,
    phaseLabelOverride,
    t,
    jobId,
    onToggleRawLog,
    toggleLabel,
    cliCommand,
    cliShell,
    etaDisplay,
    canSkip,
    onSkip,
    cancelDisabled,
    canCancel,
    onCancel,
    summary,
    languageDisplay,
    locale,
    progressValue,
    recentSpeed,
    averageSpeed,
    speedSamples,
    chapterProgress,
    readerPopup,
    setReaderPopup,
    setReaderOpen,
    readerOpen,
    bookTitle,
    bookAuthor,
    coverUrl,
    playingSegment,
    setReaderStartRequestId,
    readerStartRequestId,
    setPlayingSegment,
    showRawLog,
    rawLogRef,
    rawLogText,
    errorText,
    errorHint,
  };
}

export type StatusPanelScope = ReturnType<typeof useConversionStatus>;
