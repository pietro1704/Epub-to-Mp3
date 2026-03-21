import type { ConversionState, ConversionSummary } from "../types/conversion";

interface ActiveConversionBannerProps {
  phase: ConversionState["phase"];
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
  skipLabel?: string;
  onViewProgress: () => void;
  onCancel?: () => void;
  onSkip?: () => void;
  canCancel?: boolean;
  canSkip?: boolean;
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
  skipLabel,
  onViewProgress,
  onCancel,
  onSkip,
  canCancel,
  canSkip,
  cancelDisabled,
  summary,
}: ActiveConversionBannerProps): JSX.Element {
  const currentChapter = summary?.currentChapter;
  const speedSamples =
    summary?.chapterProgress
      ?.map((entry) => entry.charsPerSecond)
      .filter(
        (value): value is number =>
          typeof value === "number" && Number.isFinite(value) && value > 0,
      ) ?? [];
  const recentSpeed =
    speedSamples.length > 0 ? speedSamples[speedSamples.length - 1] : null;
  const averageSpeed =
    speedSamples.length > 0
      ? speedSamples.reduce((sum, value) => sum + value, 0) /
        speedSamples.length
      : null;
  const progressPercent =
    typeof summary?.progressPercent === "number"
      ? Math.min(100, Math.max(0, summary.progressPercent))
      : null;
  const chapterCounts =
    typeof summary?.chaptersCompleted === "number" &&
    typeof summary?.chaptersTotal === "number" &&
    summary.chaptersTotal > 0
      ? `${summary.chaptersCompleted}/${summary.chaptersTotal}`
      : null;

  return (
    <section className="active-conversion">
      <div className="active-conversion__header">
        <span className={`status-chip status-chip--${phase}`}>
          {statusLabel}
        </span>
        {jobLabel && <span className="active-conversion__job">{jobLabel}</span>}
      </div>
      <div className="active-conversion__body">
        <div className="active-conversion__info">
          <p className="active-conversion__label">{currentLabel}</p>
          <h3>{bookTitle}</h3>
          {bookAuthor && (
            <p className="active-conversion__author">{bookAuthor}</p>
          )}
          {currentChapter && (
            <p className="active-conversion__chapter">{currentChapter}</p>
          )}
          <p className="active-conversion__eta">
            <span>{etaLabel}</span>
            <strong>{etaValue}</strong>
          </p>
          {(progressPercent !== null || chapterCounts) && (
            <div className="active-conversion__progress">
              <div className="active-conversion__progress-meta">
                {progressPercent !== null && (
                  <strong>{progressPercent.toFixed(1)}%</strong>
                )}
                {chapterCounts && (
                  <span className="active-conversion__progress-count">
                    {chapterCounts}
                  </span>
                )}
              </div>
              <div
                className="active-conversion__progress-bar"
                aria-hidden="true"
              >
                <span
                  className="active-conversion__progress-fill"
                  style={{ width: `${progressPercent ?? 0}%` }}
                />
              </div>
              {(recentSpeed || averageSpeed) && (
                <div className="active-conversion__speed">
                  {recentSpeed ? (
                    <strong>{Math.round(recentSpeed)} chars/s</strong>
                  ) : null}
                  {averageSpeed && speedSamples.length > 1 ? (
                    <span>avg {Math.round(averageSpeed)} chars/s</span>
                  ) : null}
                </div>
              )}
            </div>
          )}
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
          <button
            type="button"
            className="button-secondary"
            onClick={onViewProgress}
          >
            {viewLabel}
          </button>
          {canSkip && onSkip && skipLabel && (
            <button
              type="button"
              className="button-warning"
              onClick={onSkip}
              disabled={cancelDisabled}
            >
              {skipLabel}
            </button>
          )}
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
