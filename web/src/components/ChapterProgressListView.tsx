import { AudioChunkEntry } from '../types/conversion';
import { EngineBadges, STATUS_ICONS, formatChapterDuration } from './ChapterProgressPresentation';
import type { ChapterProgressListScope } from './useChapterProgress';

export function ChapterProgressListView({
  hasEntries,
  matchCounterRef,
  containerRef,
  headerRef,
  t,
  scrollToCurrent,
  handleToggleAllChapters,
  jobId,
  expandAllChapters,
  handleToggleAllTexts,
  expandAllTexts,
  handleScrollTop,
  handleDownloadText,
  searchQuery,
  handleSearchChange,
  searchHits,
  handlePrevMatch,
  handleNextMatch,
  completedCount,
  entries,
  listRef,
  expanded,
  manifests,
  manifestLoading,
  manifestErrors,
  toggleChapter,
  fetchManifest,
  locale,
  segmentCountLabel,
  expandedTexts,
  playingSegment,
  segmentDurationLabel,
  toggleSegmentText,
  highlightMatches,
}: ChapterProgressListScope): JSX.Element | null {
  if (!hasEntries) {
    return null;
  }

  matchCounterRef.current = 0;

  return (
    <div className="chapter-progress" aria-live="polite" ref={containerRef}>
      <div className="chapter-progress__header" ref={headerRef}>
        <h3>{t.status.chapterProgressTitle}</h3>
        <div className="chapter-progress__actions">
          <button
            type="button"
            className="status-panel__toggle"
            onClick={() => scrollToCurrent('smooth')}
            title={t.status.chapterGoToCurrentTitle}
            style={{ fontSize: '0.8rem', padding: '0.35rem 0.75rem' }}
          >
            ↓ {t.status.chapterGoToCurrent}
          </button>
          <button
            type="button"
            className="status-panel__toggle"
            onClick={handleToggleAllChapters}
            disabled={!jobId}
          >
            {expandAllChapters ? t.status.collapseAllChapters : t.status.expandAllChapters}
          </button>
          <button
            type="button"
            className="status-panel__toggle"
            onClick={handleToggleAllTexts}
            disabled={!jobId}
          >
            {expandAllTexts ? t.status.hideAllText : t.status.showAllText}
          </button>
          {expandAllTexts && (
            <>
              <button type="button" className="status-panel__toggle" onClick={handleScrollTop}>
                {t.status.scrollToTop}
              </button>
              <button type="button" className="status-panel__toggle" onClick={handleDownloadText}>
                {t.status.downloadFullText}
              </button>
              <div className="chapter-progress__search">
                <input
                  type="search"
                  placeholder={t.status.searchPlaceholder}
                  value={searchQuery}
                  onChange={(event) => handleSearchChange(event.target.value)}
                />
                <span className="chapter-progress__search-count">
                  {searchQuery.trim() ? t.status.searchCount(searchHits) : ''}
                </span>
                <div className="chapter-progress__search-nav">
                  <button
                    type="button"
                    className="status-panel__toggle"
                    onClick={handlePrevMatch}
                    disabled={!searchHits}
                  >
                    {t.status.searchPrev}
                  </button>
                  <button
                    type="button"
                    className="status-panel__toggle"
                    onClick={handleNextMatch}
                    disabled={!searchHits}
                  >
                    {t.status.searchNext}
                  </button>
                </div>
              </div>
            </>
          )}
          <span className="chapter-progress__totals">
            {completedCount}/{entries.length}
          </span>
        </div>
      </div>
      <ul className="chapter-progress__list" ref={listRef}>
        {entries.map((entry) => {
          const status = entry.status;
          const statusLabel = t.status.chapterStatuses?.[status] ?? status;
          const isExpanded = Boolean(expanded[entry.index]);
          const manifest = manifests[entry.index];
          const loading = Boolean(manifestLoading[entry.index]);
          const manifestError = manifestErrors[entry.index];
          const segments = manifest?.chunks ?? [];
          return (
            <li
              key={`chapter-${entry.index}`}
              className={`chapter-progress__item chapter-progress__item--${status}`}
            >
              <button
                type="button"
                className="chapter-progress__item-header"
                aria-expanded={isExpanded}
                onClick={() => {
                  toggleChapter(entry.index);
                  if (!isExpanded && jobId) {
                    fetchManifest(entry.index);
                  }
                }}
              >
                <span className="chapter-progress__icon" aria-hidden="true">
                  {STATUS_ICONS[status] ?? '•'}
                </span>
                <span className="chapter-progress__name">
                  {entry.index}. {entry.name}
                </span>
                <span className="chapter-progress__status" aria-label={statusLabel}>
                  {statusLabel} <EngineBadges entry={entry} />
                  {/* Retry information */}
                  {entry.status === 'retrying' && (
                    <span className="chapter-progress__retry">
                      {entry.retryCount !== undefined && entry.maxRetries !== undefined && (
                        <span className="chapter-progress__retry-count">
                          ({entry.retryCount}/{entry.maxRetries})
                        </span>
                      )}
                      {entry.paramAdjustment && (
                        <span className="chapter-progress__param-adj" title={entry.retryReason}>
                          {entry.paramAdjustment}
                        </span>
                      )}
                    </span>
                  )}
                  {entry.status === 'completed' && (
                    <span className="chapter-progress__time">
                      {formatChapterDuration(entry.elapsedSeconds, t.status.chapterCompletedIn) ??
                        '--'}
                      {typeof entry.charsPerSecond === 'number'
                        ? ` • ~${entry.charsPerSecond} chars/s`
                        : ''}
                      {/* Show if retry was needed */}
                      {entry.retryCount !== undefined && entry.retryCount > 0 && (
                        <span
                          className="chapter-progress__retry-badge"
                          title={
                            locale === 'pt'
                              ? `Success after ${entry.retryCount} attempt(s)`
                              : `Success after ${entry.retryCount} retry(s)`
                          }
                        >
                          🔄{entry.retryCount}
                        </span>
                      )}
                    </span>
                  )}
                  <span className="chapter-progress__chevron" aria-hidden="true">
                    {isExpanded ? '▾' : '▸'}
                  </span>
                </span>
              </button>
              {isExpanded && (
                <div className="chapter-progress__details">
                  {entry.downloadUrl && (
                    <div className="chapter-progress__download-audio">
                      <strong>{t.status.chapterFullAudio}</strong>
                      <audio controls preload="metadata" className="chapter-progress__audio">
                        <source src={entry.downloadUrl} type="audio/mpeg" />
                        {t.status.chapterAudioUnsupported}
                      </audio>
                    </div>
                  )}
                  <div className="chapter-progress__segments">
                    <div className="chapter-progress__segments-header">
                      <strong>{t.status.chapterSegmentsTitle}</strong>
                      <span className="chapter-progress__segments-meta">
                        {segments.length > 0
                          ? segmentCountLabel(segments.length)
                          : status === 'completed' && !loading
                            ? t.status.chapterSegmentsNone
                            : t.status.chapterSegmentsWaiting}
                      </span>
                    </div>
                    {manifestError && <p className="chapter-progress__error">{manifestError}</p>}
                    {loading && (
                      <p className="chapter-progress__loading">{t.status.chapterSegmentsLoading}</p>
                    )}
                    {segments.length > 0 && (
                      <ul className="chapter-progress__segments-list">
                        {segments.map((segment: AudioChunkEntry) => {
                          const textKey = `${entry.index}-${segment.index}`;
                          const isTextExpanded = Boolean(expandAllTexts || expandedTexts[textKey]);
                          const hasText = Boolean(segment.text?.trim());
                          const isPlaying =
                            playingSegment?.chapterIndex === entry.index &&
                            playingSegment?.segmentIndex === segment.index;
                          return (
                            <li
                              key={`segment-${entry.index}-${segment.index}`}
                              className={`chapter-progress__segment ${
                                isPlaying ? 'chapter-progress__segment--playing' : ''
                              }`}
                              data-segment-key={`${entry.index}-${segment.index}`}
                            >
                              <div className="chapter-progress__segment-header">
                                <div className="chapter-progress__segment-meta">
                                  <span className="chapter-progress__segment-title">
                                    {t.status.chapterSegmentTitle(segment.index + 1)}
                                  </span>
                                  {segment.durationSeconds !== undefined && (
                                    <span className="chapter-progress__segment-duration">
                                      {segmentDurationLabel(segment.durationSeconds)}
                                    </span>
                                  )}
                                </div>
                                {hasText && !expandAllTexts && (
                                  <button
                                    type="button"
                                    className="chapter-progress__segment-toggle"
                                    onClick={() => toggleSegmentText(entry.index, segment.index)}
                                    title={
                                      isTextExpanded
                                        ? t.status.chapterSegmentHideText
                                        : t.status.chapterSegmentShowText
                                    }
                                  >
                                    {isTextExpanded ? '▾' : '▸'} {t.status.chapterSegmentText}
                                  </button>
                                )}
                              </div>
                              <audio
                                controls
                                preload="metadata"
                                className="chapter-progress__audio"
                              >
                                <source src={segment.url} type="audio/mpeg" />
                                {t.status.chapterAudioUnsupported}
                              </audio>
                              {isTextExpanded && hasText && (
                                <div
                                  className={`chapter-progress__segment-text${
                                    expandAllTexts ? ' chapter-progress__segment-text--full' : ''
                                  }`}
                                >
                                  {expandAllTexts && searchQuery.trim()
                                    ? highlightMatches(segment.text || '', searchQuery)
                                    : segment.text}
                                </div>
                              )}
                            </li>
                          );
                        })}
                      </ul>
                    )}
                    {!loading && segments.length === 0 && (
                      <p className="chapter-progress__empty">{t.status.chapterSegmentsEmpty}</p>
                    )}
                    {!jobId && (
                      <p className="chapter-progress__hint">
                        {locale === 'pt'
                          ? 'Start a conversion to load the segments.'
                          : 'Start a conversion to load segments.'}
                      </p>
                    )}
                  </div>
                </div>
              )}
            </li>
          );
        })}
      </ul>
    </div>
  );
}
