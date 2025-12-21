import { useEffect, useRef, useState } from 'react';
import { useI18n, useTranslations } from '../i18n/I18nProvider';
import type { Locale } from '../i18n/translations';
import { ConversionState, DownloadAsset, StatusEntry } from '../types/conversion';

interface DownloadsPanelContext {
  title: string;
  subtitle?: string;
  actionLabel: string;
  onAction: () => void;
}

interface DownloadsPanelProps {
  downloads: DownloadAsset[];
  phase: ConversionState['phase'];
  onReset: () => void;
  isBusy: boolean;
  cliCommand?: string;
  log: StatusEntry[];
  showRawLog?: boolean;
  context?: DownloadsPanelContext;
}

export default function DownloadsPanel({ downloads, phase, onReset, isBusy, cliCommand, log, showRawLog = false, context }: DownloadsPanelProps): JSX.Element {
  const t = useTranslations();
  const { locale } = useI18n();
  const hasDownloads = downloads.length > 0;
  const [expandedChapters, setExpandedChapters] = useState<Set<string>>(new Set());
  const [logPreview, setLogPreview] = useState<{ open: boolean; loading: boolean; content: string; error: string | null }>({
    open: false,
    loading: false,
    content: '',
    error: null,
  });
  const verboseLogRef = useRef<HTMLPreElement>(null);

  useEffect(() => {
    const handlePlay = (event: Event) => {
      const target = event.target;
      if (!(target instanceof HTMLAudioElement)) {
        return;
      }
      if (!target.classList.contains('chapter-item__player')) {
        return;
      }
      const players = document.querySelectorAll<HTMLAudioElement>('audio.chapter-item__player');
      players.forEach((audio) => {
        if (audio !== target && !audio.paused) {
          audio.pause();
        }
      });
    };
    document.addEventListener('play', handlePlay, true);
    return () => document.removeEventListener('play', handlePlay, true);
  }, []);

  const scrollLogToBottom = () => {
    if (verboseLogRef.current) {
      verboseLogRef.current.scrollTop = verboseLogRef.current.scrollHeight;
    }
  };

  const zipFile = downloads.find(d => d.name.toLowerCase().endsWith('.zip'));
  const logFile = downloads.find(d => d.name.toLowerCase().endsWith('.log'));
  const chapters = downloads.filter((d) => d.name.toLowerCase().endsWith('.mp3'));

  useEffect(() => {
    setLogPreview({ open: false, loading: false, content: '', error: null });
  }, [logFile?.url]);

  const toggleChapter = (url: string) => {
    setExpandedChapters((prev) => {
      const next = new Set(prev);
      if (next.has(url)) {
        next.delete(url);
      } else {
        next.add(url);
      }
      return next;
    });
  };

  const toggleLogPreview = async () => {
    if (!logFile) return;
    if (logPreview.open) {
      setLogPreview((prev) => ({ ...prev, open: false }));
      return;
    }
    setLogPreview({ open: true, loading: true, content: '', error: null });
    try {
      const response = await fetch(logFile.url);
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
      const text = await response.text();
      setLogPreview({ open: true, loading: false, content: text, error: null });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'unknown';
      setLogPreview({
        open: true,
        loading: false,
        content: '',
        error: t.downloads.logError(message),
      });
    }
  };

  return (
    <div className="downloads-panel">
      {context && (
        <div className="downloads-panel__context">
          <div>
            <p className="downloads-panel__context-title">{context.title}</p>
            {context.subtitle && <p className="downloads-panel__context-subtitle">{context.subtitle}</p>}
          </div>
          <button type="button" className="downloads-panel__context-action" onClick={context.onAction}>
            {context.actionLabel}
          </button>
        </div>
      )}

      {cliCommand && (
        <div className="downloads-panel__command-section">
          <h3>Comando executado</h3>
          <code className="downloads-panel__command">{cliCommand}</code>
        </div>
      )}

      {showRawLog && log.length > 0 && (
        <div className="downloads-panel__command-section">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '0.5rem' }}>
            <h3 style={{ margin: 0 }}>Saída do terminal (verbose)</h3>
            <button
              type="button"
              className="status-panel__toggle"
              onClick={scrollLogToBottom}
              title={locale === 'pt' ? 'Ir para o final' : 'Go to bottom'}
              style={{ fontSize: '0.8rem', padding: '0.35rem 0.75rem' }}
            >
              ↓ {locale === 'pt' ? 'Ver atual' : 'Go to current'}
            </button>
          </div>
          <pre className="downloads-panel__log" ref={verboseLogRef}>
            {log.map(entry => entry.message).join('\n')}
          </pre>
        </div>
      )}

      {!hasDownloads && phase !== 'success' && (
        <p className="downloads-panel__placeholder">{t.downloads.placeholder}</p>
      )}

      {hasDownloads && (
        <>
          {zipFile && (
            <div className="downloads-panel__primary">
              <a href={zipFile.url} download={zipFile.name} className="downloads-panel__zip-button">
                <span className="downloads-panel__zip-icon">📦</span>
                <span className="downloads-panel__zip-text">
                  <strong>{t.downloads.downloadZip}</strong>
                  <small>{t.downloads.downloadZipHint(chapters.length)}</small>
                </span>
              </a>
            </div>
          )}
          {logFile && (
            <div className="downloads-panel__logfile">
              <div className="downloads-panel__logfile-actions">
                <button
                  type="button"
                  className="downloads-panel__log-button"
                  onClick={toggleLogPreview}
                >
                  {logPreview.open ? t.downloads.hideLog : t.downloads.viewLog}
                </button>
                <a href={logFile.url} download={logFile.name} className="downloads-panel__log-link">
                  {t.downloads.downloadLog}
                </a>
              </div>
              {logPreview.open && (
                <div className="downloads-panel__log-preview">
                  {logPreview.loading && <p>{t.downloads.logLoading}</p>}
                  {!logPreview.loading && logPreview.error && (
                    <p className="downloads-panel__log-error">{logPreview.error}</p>
                  )}
                  {!logPreview.loading && !logPreview.error && (
                    <pre>{logPreview.content}</pre>
                  )}
                </div>
              )}
            </div>
          )}

          {chapters.length > 0 && (
            <>
              <div className="downloads-panel__divider">
                <span>{t.downloads.orIndividual}</span>
              </div>
              <div className="downloads-chapters">
                {chapters.map((asset) => {
                  const isExpanded = expandedChapters.has(asset.url);
                  return (
                    <div key={asset.url} className="chapter-item">
                      <button
                        type="button"
                        className="chapter-item__header"
                        onClick={() => toggleChapter(asset.url)}
                        aria-expanded={isExpanded}
                      >
                        <span className="chapter-item__icon">{isExpanded ? '▼' : '▶'}</span>
                        <span className="chapter-item__name" title={asset.name}>
                          {asset.name}
                        </span>
                        {typeof asset.durationSeconds === 'number' && (
                          <span className="chapter-item__duration">{formatDuration(asset.durationSeconds, locale)}</span>
                        )}
                      </button>
                      {isExpanded && (
                        <div className="chapter-item__content">
                          <audio controls className="chapter-item__player" preload="metadata">
                            <source src={asset.url} type="audio/mpeg" />
                            {t.downloads.audioNotSupported}
                          </audio>
                          <a href={asset.url} download={asset.name} className="chapter-item__download">
                            {t.downloads.downloadChapter}
                          </a>
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            </>
          )}
        </>
      )}

      <button type="button" className="downloads-panel__cta" onClick={onReset} disabled={isBusy}>
        {hasDownloads ? t.downloads.resetWithDownloads : t.downloads.resetWithoutDownloads}
      </button>
    </div>
  );
}

function formatDuration(seconds: number, locale: Locale): string {
  const totalMinutes = Math.round(seconds / 60);
  if (totalMinutes < 1) return locale === 'pt' ? '< 1 min' : '< 1 min';
  if (totalMinutes < 60) return `${totalMinutes} min`;
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (minutes === 0) {
    return locale === 'pt' ? `${hours} h` : `${hours} h`;
  }
  return locale === 'pt' ? `${hours} h ${minutes} min` : `${hours} h ${minutes} min`;
}
