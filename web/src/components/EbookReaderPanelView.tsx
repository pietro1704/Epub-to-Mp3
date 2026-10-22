import type { CSSProperties } from 'react';
import NativeReaderFallback from './NativeReaderFallback';
import StreamingAudioPlayer from './StreamingAudioPlayer';
import { ReaderTheme, ReaderFontFamily } from './reader_preferences';
import type { EbookReaderPanelScope } from './useReaderPosition';

export function EbookReaderPanelView({
  jobId,
  prefs,
  compact,
  t,
  resolvedTitle,
  resolvedAuthor,
  document,
  chapters,
  playbackStarted,
  onRequestStart,
  loading,
  loadError,
  followPaused,
  readerPages,
  pageIndex,
  audioChapter,
  selectedChapter,
  chapterProgress,
  coverUrl,
  startRequestId,
  onPlayingSegment,
  onPlaybackStateChange,
  search,
  setSearch,
  currentSearchCount,
  setPrefs,
  setFollowPaused,
  setReloadToken,
  chapterStatusMap,
  selectedChapterIndex,
  audioChapterIndex,
  setSelectedChapterIndex,
  locale,
  articleShellRef,
  setPageIndex,
  playback,
  articleHostRef,
}: EbookReaderPanelScope): JSX.Element | null {
  if (!jobId) {
    return null;
  }

  return (
    <section
      className={`ebook-reader ebook-reader--${prefs.theme} ${compact ? 'ebook-reader--compact' : ''}`}
      aria-label={t.status.readerTitle}
    >
      <div className="ebook-reader__stage">
        <div className="ebook-reader__hero">
          <div>
            <div className="ebook-reader__eyebrow">{t.status.readerTitle}</div>
            <h3 className="ebook-reader__title">{resolvedTitle}</h3>
            <p className="ebook-reader__subtitle">
              {resolvedAuthor}
              {document
                ? ` • ${chapters.length} ${t.status.readerChapterCount(chapters.length)}`
                : ''}
            </p>
          </div>
          <div className="ebook-reader__hero-meta">
            {!playbackStarted && onRequestStart && (
              <button
                type="button"
                className="ebook-reader__read-button"
                onClick={onRequestStart}
                disabled={loading || Boolean(loadError)}
              >
                {t.status.readerReadButton}
              </button>
            )}
            <span className="ebook-reader__hero-chip">
              {prefs.followAudio && !followPaused
                ? t.status.readerFollowAudioOn
                : t.status.readerFollowAudioOff}
            </span>
            {readerPages.length > 0 && (
              <span className="ebook-reader__hero-chip">
                {t.status.readerPageLabel(pageIndex + 1, readerPages.length)}
              </span>
            )}
            {audioChapter && (
              <span className="ebook-reader__hero-chip ebook-reader__hero-chip--live">
                {t.status.readerAudioOnChapter(audioChapter.index)}
              </span>
            )}
          </div>
        </div>
        {selectedChapter && (
          <NativeReaderFallback
            jobId={jobId}
            chapterIndex={selectedChapter.index}
            text={selectedChapter.text}
          />
        )}
        {chapterProgress && chapterProgress.length > 0 && (
          <StreamingAudioPlayer
            jobId={jobId}
            chapters={chapterProgress}
            bookTitle={resolvedTitle}
            bookAuthor={resolvedAuthor}
            coverUrl={coverUrl}
            startRequestId={startRequestId}
            hideStartButton={Boolean(onRequestStart)}
            embedded
            onPlayingSegment={onPlayingSegment}
            onPlaybackStateChange={onPlaybackStateChange}
          />
        )}
      </div>

      <div className="ebook-reader__toolbar">
        <label className="ebook-reader__search">
          <span>{t.status.searchPlaceholder}</span>
          <input
            type="search"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            placeholder={t.status.searchPlaceholder}
          />
          <small>{t.status.searchCount(currentSearchCount)}</small>
        </label>

        <label className="ebook-reader__toggle">
          <span>{t.status.readerFollowAudioLabel}</span>
          <input
            type="checkbox"
            checked={prefs.followAudio}
            onChange={(event) => {
              setPrefs((current) => ({
                ...current,
                followAudio: event.target.checked,
              }));
              // Re-enabling follow clears any manual override.
              if (event.target.checked) {
                setFollowPaused(false);
              }
            }}
          />
        </label>

        <label className="ebook-reader__control">
          <span>{t.status.readerThemeLabel}</span>
          <select
            value={prefs.theme}
            onChange={(event) =>
              setPrefs((current) => ({
                ...current,
                theme: event.target.value as ReaderTheme,
              }))
            }
          >
            <option value="paper">{t.status.readerThemePaper}</option>
            <option value="mist">{t.status.readerThemeMist}</option>
            <option value="ink">{t.status.readerThemeInk}</option>
          </select>
        </label>

        <label className="ebook-reader__control">
          <span>{t.status.readerFontFamilyLabel}</span>
          <select
            value={prefs.fontFamily}
            onChange={(event) =>
              setPrefs((current) => ({
                ...current,
                fontFamily: event.target.value as ReaderFontFamily,
              }))
            }
          >
            <option value="serif">{t.status.readerFontFamilySerif}</option>
            <option value="sans">{t.status.readerFontFamilySans}</option>
          </select>
        </label>

        <label className="ebook-reader__control">
          <span>{t.status.readerFontSizeLabel}</span>
          <input
            type="range"
            min="0.9"
            max="1.4"
            step="0.05"
            value={prefs.fontScale}
            onChange={(event) =>
              setPrefs((current) => ({
                ...current,
                fontScale: Number(event.target.value),
              }))
            }
          />
        </label>

        <label className="ebook-reader__control">
          <span>{t.status.readerLineHeightLabel}</span>
          <input
            type="range"
            min="1.45"
            max="2.1"
            step="0.05"
            value={prefs.lineHeight}
            onChange={(event) =>
              setPrefs((current) => ({
                ...current,
                lineHeight: Number(event.target.value),
              }))
            }
          />
        </label>

        <label className="ebook-reader__control">
          <span>{t.status.readerWidthLabel}</span>
          <input
            type="range"
            min="34"
            max="68"
            step="2"
            value={prefs.widthRem}
            onChange={(event) =>
              setPrefs((current) => ({
                ...current,
                widthRem: Number(event.target.value),
              }))
            }
          />
        </label>
      </div>

      <div className="ebook-reader__layout">
        <aside className="ebook-reader__chapters">
          <div className="ebook-reader__chapters-header">
            <h4>{t.status.readerChaptersTitle}</h4>
            <span>{chapters.length}</span>
          </div>
          {loading && chapters.length === 0 && (
            <div className="ebook-reader__state">{t.status.readerLoading}</div>
          )}
          {!loading && loadError && chapters.length === 0 && (
            <div className="ebook-reader__state ebook-reader__state--error">
              <div className="ebook-reader__state-copy">{loadError}</div>
              <button
                type="button"
                className="ebook-reader__retry"
                onClick={() => setReloadToken((current) => current + 1)}
              >
                {t.status.readerRetryLoad}
              </button>
            </div>
          )}
          {chapters.length > 0 && (
            <div
              className={`ebook-reader__chapter-list${loading ? ' is-reloading' : ''}`}
              aria-busy={loading || undefined}
            >
              {chapters.map((chapter) => {
                const status = chapterStatusMap.get(chapter.index);
                const isSelected = selectedChapterIndex === chapter.index;
                const isAudio = audioChapterIndex === chapter.index;
                return (
                  <button
                    key={chapter.index}
                    type="button"
                    className={[
                      'ebook-reader__chapter-item',
                      isSelected ? 'is-selected' : '',
                      isAudio ? 'is-audio' : '',
                    ]
                      .filter(Boolean)
                      .join(' ')}
                    onClick={() => {
                      setSelectedChapterIndex(chapter.index);
                      // Pause follow temporarily without persisting to localStorage.
                      // Resumes automatically when audio advances to a new chapter.
                      if (prefs.followAudio) {
                        setFollowPaused(true);
                      }
                    }}
                  >
                    <span className="ebook-reader__chapter-index">{chapter.index}</span>
                    <span className="ebook-reader__chapter-copy">
                      <strong className="ebook-reader__chapter-name" title={chapter.name}>
                        {chapter.name}
                      </strong>
                      <small>
                        {chapter.charCount.toLocaleString(locale === 'pt' ? 'pt-BR' : 'en-US')}{' '}
                        chars
                      </small>
                    </span>
                    {status && (
                      <span className={`ebook-reader__chapter-badge is-${status.status}`}>
                        {t.status.chapterStatuses[status.status]}
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          )}
        </aside>

        <div ref={articleShellRef} className="ebook-reader__article-shell">
          {selectedChapter ? (
            <>
              <div className="ebook-reader__article-header">
                <div>
                  <div className="ebook-reader__article-eyebrow">{t.status.summaryCurrent}</div>
                  <h4>{selectedChapter.name}</h4>
                </div>
                {readerPages.length > 0 && (
                  <div className="ebook-reader__pager">
                    <button
                      type="button"
                      className="ebook-reader__page-button"
                      onClick={() => setPageIndex((current) => Math.max(0, current - 1))}
                      disabled={pageIndex <= 0}
                    >
                      {t.status.readerPrevPage}
                    </button>
                    <span className="ebook-reader__page-label">
                      {t.status.readerPageLabel(pageIndex + 1, readerPages.length)}
                    </span>
                    <button
                      type="button"
                      className="ebook-reader__page-button"
                      onClick={() =>
                        setPageIndex((current) => Math.min(readerPages.length - 1, current + 1))
                      }
                      disabled={pageIndex >= readerPages.length - 1}
                    >
                      {t.status.readerNextPage}
                    </button>
                  </div>
                )}
                {playback?.chapterIndex === selectedChapter.index && (
                  <div className="ebook-reader__live">
                    <strong>{t.status.readerNowReading}</strong>
                    <span>{t.status.readerSegmentLabel(playback.segmentIndex + 1)}</span>
                    <span>
                      {playback.waiting
                        ? t.status.readerWaitingSegment
                        : playback.isPlaying
                          ? t.status.readerPlaying
                          : t.status.readerPaused}
                    </span>
                  </div>
                )}
              </div>

              <article
                className="ebook-reader__article"
                style={
                  {
                    '--reader-font-scale': prefs.fontScale,
                    '--reader-line-height': prefs.lineHeight,
                    '--reader-width': `${prefs.widthRem}rem`,
                    '--reader-font-family':
                      prefs.fontFamily === 'sans'
                        ? '"Helvetica Neue", Arial, sans-serif'
                        : '"Iowan Old Style", "Palatino Linotype", "Book Antiqua", Georgia, serif',
                  } as CSSProperties
                }
              >
                <div ref={articleHostRef} className="ebook-reader__content-host" />
              </article>
            </>
          ) : (
            <div className="ebook-reader__state">{t.status.readerEmpty}</div>
          )}
        </div>
      </div>
    </section>
  );
}
