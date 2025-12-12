import { useState } from 'react';
import { useI18n, useTranslations } from '../i18n/I18nProvider';
import type { Locale } from '../i18n/translations';
import { ConversionState, DownloadAsset, StatusEntry } from '../types/conversion';

interface DownloadsPanelProps {
  downloads: DownloadAsset[];
  phase: ConversionState['phase'];
  onReset: () => void;
  isBusy: boolean;
  cliCommand?: string;
  log: StatusEntry[];
}

export default function DownloadsPanel({ downloads, phase, onReset, isBusy, cliCommand, log }: DownloadsPanelProps): JSX.Element {
  const t = useTranslations();
  const { locale } = useI18n();
  const hasDownloads = downloads.length > 0;
  const [expandedChapters, setExpandedChapters] = useState<Set<string>>(new Set());
  const [showLog, setShowLog] = useState(false);

  // Separate ZIP file from individual chapters
  const zipFile = downloads.find(d => d.name.toLowerCase().endsWith('.zip'));
  const chapters = downloads.filter(d => !d.name.toLowerCase().endsWith('.zip'));

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

  return (
    <div className="downloads-panel">
      {cliCommand && (
        <div className="downloads-panel__command-section">
          <h3>Comando executado</h3>
          <code className="downloads-panel__command">{cliCommand}</code>
          <button
            type="button"
            className="downloads-panel__log-toggle"
            onClick={() => setShowLog(!showLog)}
          >
            {showLog ? '▼ Ocultar log' : '▶ Ver log completo'}
          </button>
          {showLog && (
            <pre className="downloads-panel__log">
              {log.map(entry => entry.message).join('\n')}
            </pre>
          )}
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
                        <span className="chapter-item__name">{asset.name}</span>
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
