import type { ConversionState, ConversionSummary } from '../types/conversion';

interface ActiveConversionBannerProps {
  phase: ConversionState['phase'];
  statusLabel: string;
  jobLabel?: string;
  bookTitle: string;
  bookAuthor?: string;
  etaLabel: string;
  etaValue: string;
  currentLabel: string;
  engineLabel: string;
  voiceLabel: string;
  languageLabel: string;
  engineValue?: string;
  voiceValue?: string;
  languageValue?: string;
  description: string;
  queueHint: string;
  viewLabel: string;
  cancelLabel: string;
  onViewProgress: () => void;
  onCancel?: () => void;
  canCancel?: boolean;
  cancelDisabled?: boolean;
  summary?: ConversionSummary;
}

export default function ActiveConversionBanner({
  phase,
  statusLabel,
  jobLabel,
  bookTitle,
  bookAuthor,
  etaLabel,
  etaValue,
  currentLabel,
  engineLabel,
  voiceLabel,
  languageLabel,
  engineValue,
  voiceValue,
  languageValue,
  description,
  queueHint,
  viewLabel,
  cancelLabel,
  onViewProgress,
  onCancel,
  canCancel,
  cancelDisabled,
  summary,
}: ActiveConversionBannerProps): JSX.Element {
  const currentChapter = summary?.currentChapter;

  return (
    <section className="active-conversion">
      <div className="active-conversion__header">
        <span className={`status-chip status-chip--${phase}`}>{statusLabel}</span>
        {jobLabel && <span className="active-conversion__job">{jobLabel}</span>}
      </div>
      <div className="active-conversion__body">
        <div className="active-conversion__info">
          <p className="active-conversion__label">{currentLabel}</p>
          <h3>{bookTitle}</h3>
          {bookAuthor && <p className="active-conversion__author">{bookAuthor}</p>}
        {currentChapter && <p className="active-conversion__chapter">{currentChapter}</p>}
        <p className="active-conversion__eta">
          <span>{etaLabel}</span>
          <strong>{etaValue}</strong>
        </p>
        {(engineValue || voiceValue || languageValue) && (
          <div className="active-conversion__meta">
            {engineValue && (
              <p>
                <span>{engineLabel}</span>
                <strong>{engineValue}</strong>
              </p>
            )}
            {voiceValue && (
              <p>
                <span>{voiceLabel}</span>
                <strong>{voiceValue}</strong>
              </p>
            )}
            {languageValue && (
              <p>
                <span>{languageLabel}</span>
                <strong>{languageValue}</strong>
              </p>
            )}
          </div>
        )}
      </div>
        <div className="active-conversion__actions">
          <button type="button" className="button-secondary" onClick={onViewProgress}>
            {viewLabel}
          </button>
          {canCancel && onCancel && (
            <button
              type="button"
              className="button-danger"
              onClick={onCancel}
              disabled={cancelDisabled}
            >
              {cancelLabel}
            </button>
          )}
        </div>
      </div>
      <p className="active-conversion__description">{description}</p>
      <p className="active-conversion__hint">{queueHint}</p>
    </section>
  );
}
