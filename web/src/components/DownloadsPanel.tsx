import { useI18n, useTranslations } from '../i18n/I18nProvider';
import type { Locale } from '../i18n/translations';
import { ConversionState, DownloadAsset } from '../types/conversion';

interface DownloadsPanelProps {
  downloads: DownloadAsset[];
  phase: ConversionState['phase'];
  onReset: () => void;
  isBusy: boolean;
}

export default function DownloadsPanel({ downloads, phase, onReset, isBusy }: DownloadsPanelProps): JSX.Element {
  const t = useTranslations();
  const { locale } = useI18n();
  const hasDownloads = downloads.length > 0;
  return (
    <div className="downloads-panel">
      {!hasDownloads && phase !== 'success' && (
        <p className="downloads-panel__placeholder">{t.downloads.placeholder}</p>
      )}

      {hasDownloads && (
        <ul className="downloads-list">
          {downloads.map((asset) => (
            <li key={asset.url} className="downloads-list__item">
              <a href={asset.url} download={asset.name} className="downloads-list__link">
                {asset.name}
              </a>
              {typeof asset.durationSeconds === 'number' && (
                <span className="downloads-list__meta">{formatDuration(asset.durationSeconds, locale)}</span>
              )}
            </li>
          ))}
        </ul>
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
