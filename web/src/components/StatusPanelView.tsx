import ChapterProgressList from './ChapterProgressList';
import EbookReaderPanel from './EbookReaderPanel';
import { ParallelismMeter, EngineStatusDisplay } from './ConversionSummaryIndicators';
import type { StatusPanelScope } from './useConversionStatus';

export function StatusPanelView({
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
}: StatusPanelScope): JSX.Element {
  return (
    <div className="status-panel">
      <div className="status-panel__meta">
        <span className={`status-chip status-chip--${phase}`}>
          {phaseLabelOverride ?? t.status.phases[phase]}
        </span>
        {jobId && <span className="status-panel__job">{t.status.jobLabel(jobId)}</span>}
      </div>

      <div className="status-panel__toolbar">
        <button type="button" className="status-panel__toggle" onClick={onToggleRawLog}>
          {toggleLabel}
        </button>
        {cliCommand && (
          <>
            {cliShell && <small>{cliShell}</small>}
            <code className="status-panel__cli" title={cliCommand}>
              {cliCommand}
            </code>
          </>
        )}
        <div className="status-panel__eta">
          <span className="status-panel__eta-label">{t.status.etaLabel}</span>
          <span className="status-panel__eta-value">{etaDisplay}</span>
        </div>
        {canSkip && onSkip && (
          <button
            type="button"
            className="status-panel__skip"
            onClick={onSkip}
            disabled={cancelDisabled}
          >
            {t.status.skipButton || 'Skip to next'}
          </button>
        )}
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
                  : (summary.chaptersTotal ?? '—')}
              </dd>
            </div>
            <div className="status-summary__row">
              <dt>{t.status.summaryCurrent}</dt>
              <dd>{summary.currentChapter ?? '—'}</dd>
            </div>
            {summary.statusHint && (
              <div className="status-summary__row">
                <dt>{t.status.summaryHint}</dt>
                <dd>{summary.statusHint}</dd>
              </div>
            )}
            {summary.engineStatus && (
              <div className="status-summary__row status-summary__row--engine">
                <dt>{t.status.ttsEngineLabel}</dt>
                <dd>
                  <EngineStatusDisplay status={summary.engineStatus} locale={locale} />
                </dd>
              </div>
            )}
            <div className="status-summary__row">
              <dt>{t.status.summaryProgress}</dt>
              <dd>
                {progressValue !== null
                  ? `${Math.min(100, Math.max(0, Math.round(progressValue)))}%`
                  : '—'}
              </dd>
            </div>
            {(recentSpeed || averageSpeed) && (
              <div className="status-summary__row">
                <dt>{t.status.speedLabel}</dt>
                <dd>
                  {recentSpeed ? `${Math.round(recentSpeed)} chars/s` : '—'}
                  {averageSpeed && speedSamples.length > 1
                    ? ` • avg ${Math.round(averageSpeed)} chars/s`
                    : ''}
                </dd>
              </div>
            )}
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
          <div
            className="status-progress__bar"
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuenow={progressValue}
          >
            <div className="status-progress__fill" style={{ width: `${progressValue}%` }} />
          </div>
          <div className="status-progress__value">{progressValue.toFixed(1)}%</div>
        </div>
      )}
      {chapterProgress && chapterProgress.length > 0 && (
        <>
          <div className="status-panel__reader-actions">
            <button
              type="button"
              className="button-secondary"
              onClick={() => {
                if (readerPopup) {
                  setReaderPopup(false);
                }
                setReaderOpen((current) => !current);
              }}
            >
              {readerOpen ? t.status.readerClose : t.status.readerOpen}
            </button>
            <button
              type="button"
              className="button-secondary"
              onClick={() => {
                setReaderOpen(true);
                setReaderPopup((current) => !current);
              }}
            >
              {readerPopup ? t.status.readerExitPopup : t.status.readerOpenPopup}
            </button>
          </div>
          {readerOpen && !readerPopup && (
            <EbookReaderPanel
              jobId={jobId}
              bookTitle={bookTitle}
              bookAuthor={bookAuthor}
              coverUrl={coverUrl}
              chapterProgress={chapterProgress}
              playback={playingSegment}
              onRequestStart={() => setReaderStartRequestId((current) => current + 1)}
              startRequestId={readerStartRequestId}
              onPlayingSegment={(chapterIndex, segmentIndex) =>
                setPlayingSegment((current) => ({
                  chapterIndex,
                  segmentIndex,
                  segmentText: current?.segmentText,
                  isPlaying: current?.isPlaying ?? false,
                  started: current?.started ?? true,
                  waiting: current?.waiting ?? false,
                }))
              }
              onPlaybackStateChange={setPlayingSegment}
              compact
            />
          )}
          {readerOpen && readerPopup && (
            <div className="reader-modal" role="dialog" aria-modal="true">
              <div className="reader-modal__backdrop" onClick={() => setReaderPopup(false)} />
              <div className="reader-modal__panel">
                <div className="reader-modal__toolbar">
                  <button
                    type="button"
                    className="button-secondary"
                    onClick={() => setReaderPopup(false)}
                  >
                    {t.status.readerExitPopup}
                  </button>
                </div>
                <EbookReaderPanel
                  jobId={jobId}
                  bookTitle={bookTitle}
                  bookAuthor={bookAuthor}
                  coverUrl={coverUrl}
                  chapterProgress={chapterProgress}
                  playback={playingSegment}
                  onRequestStart={() => setReaderStartRequestId((current) => current + 1)}
                  startRequestId={readerStartRequestId}
                  onPlayingSegment={(chapterIndex, segmentIndex) =>
                    setPlayingSegment((current) => ({
                      chapterIndex,
                      segmentIndex,
                      segmentText: current?.segmentText,
                      isPlaying: current?.isPlaying ?? false,
                      started: current?.started ?? true,
                      waiting: current?.waiting ?? false,
                    }))
                  }
                  onPlaybackStateChange={setPlayingSegment}
                />
              </div>
            </div>
          )}
        </>
      )}
      {chapterProgress && chapterProgress.length > 0 && (
        <ChapterProgressList
          entries={chapterProgress}
          jobId={jobId}
          playingSegment={
            playingSegment
              ? {
                  chapterIndex: playingSegment.chapterIndex,
                  segmentIndex: playingSegment.segmentIndex,
                }
              : null
          }
        />
      )}

      {showRawLog && (
        <div>
          <div
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'center',
              marginBottom: '0.5rem',
            }}
          >
            <h3
              style={{
                margin: 0,
                fontSize: '0.9rem',
                fontWeight: 600,
                color: 'var(--text-secondary)',
              }}
            >
              {t.status.terminalLogLabel}
            </h3>
          </div>
          <pre className="status-panel__raw" aria-live="polite" ref={rawLogRef}>
            {rawLogText}
          </pre>
        </div>
      )}

      {errorText && <p className="status-panel__error">{errorText}</p>}
      {errorHint && <p className="status-panel__error-hint">{errorHint}</p>}
    </div>
  );
}
