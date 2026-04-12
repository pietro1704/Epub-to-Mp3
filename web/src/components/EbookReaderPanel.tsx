import { useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties } from "react";
import { conversionClient } from "../services/ConversionService";
import { reportUiIssue } from "../services/uiIssueMonitor";
import { safeScrollIntoView } from "../utils/safeScrollIntoView";
import StreamingAudioPlayer from "./StreamingAudioPlayer";
import {
  BookTextDocument,
  ChapterProgressEntry,
  PlaybackIndicator,
} from "../types/conversion";
import { useI18n, useTranslations } from "../i18n/I18nProvider";

interface EbookReaderPanelProps {
  jobId?: string;
  bookTitle?: string;
  bookAuthor?: string;
  chapterProgress?: ChapterProgressEntry[] | null;
  playback?: PlaybackIndicator | null;
  coverUrl?: string;
  onRequestStart?: () => void;
  onPlayingSegment?: (chapterIndex: number, segmentIndex: number) => void;
  onPlaybackStateChange?: (state: PlaybackIndicator | null) => void;
  startRequestId?: number;
  compact?: boolean;
}

type ReaderTheme = "paper" | "mist" | "ink";

interface ReaderPrefs {
  fontScale: number;
  lineHeight: number;
  widthRem: number;
  theme: ReaderTheme;
  followAudio: boolean;
}

const PREFS_KEY = "epub-to-mp3:reader-prefs";
const DEFAULT_PREFS: ReaderPrefs = {
  fontScale: 1.05,
  lineHeight: 1.75,
  widthRem: 48,
  theme: "paper",
  followAudio: true,
};

const READER_CONTENT_BASE_CSS = `
  .reader-root {
    color: var(--reader-text);
    font-family: "Iowan Old Style", "Palatino Linotype", "Book Antiqua", "Georgia", serif;
    font-size: calc(1rem * var(--reader-font-scale, 1.05));
    line-height: var(--reader-line-height, 1.75);
    text-rendering: optimizeLegibility;
    font-kerning: normal;
    word-break: normal;
  }
  .reader-root p,
  .reader-root blockquote,
  .reader-root ol,
  .reader-root ul,
  .reader-root pre,
  .reader-root figure {
    margin: 0 0 1.1rem;
    text-wrap: pretty;
  }
  .reader-root h1,
  .reader-root h2,
  .reader-root h3,
  .reader-root h4,
  .reader-root h5,
  .reader-root h6 {
    margin: 1.65em 0 0.75em;
    line-height: 1.18;
    font-weight: 600;
    letter-spacing: -0.01em;
  }
  .reader-root p {
    text-indent: 1.4em;
  }
  .reader-root p:first-child,
  .reader-root h1 + p,
  .reader-root h2 + p,
  .reader-root h3 + p,
  .reader-root hr + p,
  .reader-root blockquote + p,
  .reader-root figure + p {
    text-indent: 0;
  }
  .reader-root blockquote {
    margin-left: 0;
    padding: 0.9rem 1rem;
    border-left: 3px solid color-mix(in srgb, var(--reader-accent) 32%, transparent);
    background: color-mix(in srgb, var(--reader-panel) 86%, white);
    border-radius: 0 1rem 1rem 0;
    color: var(--reader-muted);
  }
  .reader-root ol,
  .reader-root ul {
    padding-left: 1.6rem;
  }
  .reader-root li + li {
    margin-top: 0.35rem;
  }
  .reader-root a {
    color: inherit;
    text-decoration-color: color-mix(in srgb, var(--reader-accent) 45%, transparent);
  }
  .reader-root hr {
    border: none;
    border-top: 1px solid var(--reader-border);
    margin: 1.75rem auto;
    width: min(12rem, 32%);
  }
  .reader-root code,
  .reader-root pre {
    font-family: "SFMono-Regular", "Menlo", "Consolas", monospace;
  }
  .reader-root pre {
    overflow: auto;
    padding: 0.9rem 1rem;
    border-radius: 1rem;
    background: color-mix(in srgb, var(--reader-sidebar) 70%, transparent);
  }
  .ebook-reader__media-note {
    margin: 0 0 1.1rem;
    padding: 0.8rem 1rem;
    border-radius: 1rem;
    background: color-mix(in srgb, var(--reader-sidebar) 68%, transparent);
    color: var(--reader-muted);
    font-size: 0.94em;
    text-align: center;
  }
  .ebook-reader__inline-highlight {
    border-radius: 0.32rem;
    transition: background 0.18s ease;
    color: inherit;
  }
  .ebook-reader__inline-highlight.is-search {
    background: var(--reader-search);
  }
  .ebook-reader__inline-highlight.is-audio {
    background: var(--reader-audio);
    box-shadow: 0 0 0 1px color-mix(in srgb, var(--reader-accent) 24%, transparent);
  }
`;

export default function EbookReaderPanel({
  jobId,
  bookTitle,
  bookAuthor,
  chapterProgress,
  playback,
  coverUrl,
  onRequestStart,
  onPlayingSegment,
  onPlaybackStateChange,
  startRequestId = 0,
  compact = false,
}: EbookReaderPanelProps): JSX.Element | null {
  const t = useTranslations();
  const { locale } = useI18n();
  const [document, setDocument] = useState<BookTextDocument | null>(null);
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [reloadToken, setReloadToken] = useState(0);
  const [selectedChapterIndex, setSelectedChapterIndex] = useState<number>(0);
  const [pageIndex, setPageIndex] = useState(0);
  const [search, setSearch] = useState("");
  const [prefs, setPrefs] = useState<ReaderPrefs>(DEFAULT_PREFS);
  // In-memory override: user clicked a chapter manually, temporarily pause followAudio
  // without persisting the change. Clears automatically when audio advances to a new chapter.
  const [followPaused, setFollowPaused] = useState(false);
  const articleHostRef = useRef<HTMLDivElement | null>(null);
  const deferredSearch = useDeferredValue(search.trim());

  useEffect(() => {
    try {
      const raw = window.localStorage.getItem(PREFS_KEY);
      if (!raw) {
        return;
      }
      const parsed = JSON.parse(raw) as Partial<ReaderPrefs>;
      setPrefs((current) => ({
        ...current,
        ...parsed,
      }));
    } catch {
      // Ignore invalid persisted settings.
    }
  }, []);

  useEffect(() => {
    try {
      window.localStorage.setItem(PREFS_KEY, JSON.stringify(prefs));
    } catch {
      // Persistence is optional.
    }
  }, [prefs]);

  useEffect(() => {
    let cancelled = false;

    async function loadDocument() {
      if (!jobId || !conversionClient.getJobFullText) {
        setDocument(null);
        return;
      }
      setLoading(true);
      setLoadError(null);
      const payload = await conversionClient.getJobFullText(jobId);
      if (cancelled) {
        return;
      }
      if (!payload || payload.chapters.length === 0) {
        setDocument(null);
        setLoadError(t.status.readerUnavailable);
        reportUiIssue("reader", t.status.readerUnavailable, {
          severity: "warning",
          details: `job=${jobId}`,
        });
        setLoading(false);
        return;
      }
      setDocument(payload);
      setSelectedChapterIndex((current) => {
        if (payload.chapters.some((chapter) => chapter.index === current)) {
          return current;
        }
        return payload.chapters[0]?.index ?? 0;
      });
      setLoading(false);
    }

    void loadDocument();

    return () => {
      cancelled = true;
    };
  }, [jobId, reloadToken, t.status.readerUnavailable]);

  useEffect(() => {
    if (!prefs.followAudio || !playback) {
      return;
    }
    if (followPaused) {
      // Audio advanced to a different chapter than the manually-selected one:
      // resume following automatically.
      if (playback.chapterIndex !== selectedChapterIndex) {
        setFollowPaused(false);
        setSelectedChapterIndex(playback.chapterIndex);
      }
      return;
    }
    setSelectedChapterIndex(playback.chapterIndex);
  }, [prefs.followAudio, playback, followPaused, selectedChapterIndex]);

  useEffect(() => {
    const marker = articleHostRef.current?.shadowRoot?.querySelector(
      "[data-reader-audio='true']",
    );
    if (!marker) {
      return;
    }
    safeScrollIntoView(marker, { block: "center", behavior: "smooth" });
  }, [selectedChapterIndex, playback?.chapterIndex, playback?.segmentIndex]);

  const chapterStatusMap = useMemo(() => {
    const map = new Map<number, ChapterProgressEntry>();
    for (const entry of chapterProgress ?? []) {
      map.set(entry.index, entry);
    }
    return map;
  }, [chapterProgress]);

  const chapters = document?.chapters ?? [];
  const selectedChapter =
    chapters.find((chapter) => chapter.index === selectedChapterIndex) ?? null;
  const audioChapterIndex = playback?.chapterIndex ?? null;
  const audioChapter =
    audioChapterIndex !== null
      ? (chapters.find((chapter) => chapter.index === audioChapterIndex) ??
        null)
      : null;
  const currentSegmentText =
    selectedChapter && playback?.chapterIndex === selectedChapter.index
      ? playback.segmentText || ""
      : "";
  const currentSearchCount = useMemo(() => {
    if (!selectedChapter || !deferredSearch) {
      return 0;
    }
    return countMatches(selectedChapter.text, deferredSearch);
  }, [selectedChapter, deferredSearch]);
  const readerPages = useMemo(() => {
    if (!selectedChapter) {
      return [];
    }
    return buildReaderPages(
      selectedChapter.html,
      selectedChapter.text,
      {
        audioText: currentSegmentText,
        searchText: deferredSearch,
      },
      prefs,
    );
  }, [selectedChapter, currentSegmentText, deferredSearch, prefs]);
  const currentPage = readerPages[pageIndex] ?? readerPages[0] ?? null;
  const renderedCss = useMemo(
    () => selectedChapter?.css || "",
    [selectedChapter],
  );

  useEffect(() => {
    setPageIndex(0);
  }, [selectedChapterIndex]);

  useEffect(() => {
    const nextIndex = readerPages.findIndex((page) => page.hasAudio);
    if (nextIndex >= 0 && nextIndex !== pageIndex) {
      setPageIndex(nextIndex);
    } else if (pageIndex >= readerPages.length && readerPages.length > 0) {
      setPageIndex(readerPages.length - 1);
    }
  }, [pageIndex, readerPages]);

  useEffect(() => {
    const host = articleHostRef.current;
    if (!host) {
      return;
    }
    const shadow = host.shadowRoot ?? host.attachShadow({ mode: "open" });
    shadow.innerHTML = `
      <style>${READER_CONTENT_BASE_CSS}\n${renderedCss}</style>
      <div class="reader-root">${currentPage?.html || "<p></p>"}</div>
    `;
    // Scroll the article shell back to the top whenever page content changes.
    const shell = host.closest(".ebook-reader__article");
    if (shell) {
      shell.scrollTop = 0;
    }
  }, [currentPage?.html, renderedCss]);

  const resolvedTitle =
    document?.bookTitle || bookTitle || t.status.bookFallbackTitle;
  const resolvedAuthor =
    document?.bookAuthor || bookAuthor || t.status.bookFallbackAuthor;
  const playbackStarted = Boolean(playback?.started);

  if (!jobId) {
    return null;
  }

  return (
    <section
      className={`ebook-reader ebook-reader--${prefs.theme} ${compact ? "ebook-reader--compact" : ""}`}
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
                : ""}
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
              {prefs.followAudio
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
          {loading && (
            <div className="ebook-reader__state">{t.status.readerLoading}</div>
          )}
          {!loading && loadError && (
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
          {!loading && !loadError && (
            <div className="ebook-reader__chapter-list">
              {chapters.map((chapter) => {
                const status = chapterStatusMap.get(chapter.index);
                const isSelected = selectedChapterIndex === chapter.index;
                const isAudio = audioChapterIndex === chapter.index;
                return (
                  <button
                    key={chapter.index}
                    type="button"
                    className={[
                      "ebook-reader__chapter-item",
                      isSelected ? "is-selected" : "",
                      isAudio ? "is-audio" : "",
                    ]
                      .filter(Boolean)
                      .join(" ")}
                    onClick={() => {
                      setSelectedChapterIndex(chapter.index);
                      // Pause follow temporarily without persisting to localStorage.
                      // Resumes automatically when audio advances to a new chapter.
                      if (prefs.followAudio) {
                        setFollowPaused(true);
                      }
                    }}
                  >
                    <span className="ebook-reader__chapter-index">
                      {chapter.index}
                    </span>
                    <span className="ebook-reader__chapter-copy">
                      <strong>{chapter.name}</strong>
                      <small>
                        {chapter.charCount.toLocaleString(
                          locale === "pt" ? "pt-BR" : "en-US",
                        )}{" "}
                        chars
                      </small>
                    </span>
                    {status && (
                      <span
                        className={`ebook-reader__chapter-badge is-${status.status}`}
                      >
                        {t.status.chapterStatuses[status.status]}
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          )}
        </aside>

        <div className="ebook-reader__article-shell">
          {selectedChapter ? (
            <>
              <div className="ebook-reader__article-header">
                <div>
                  <div className="ebook-reader__article-eyebrow">
                    {t.status.summaryCurrent}
                  </div>
                  <h4>{selectedChapter.name}</h4>
                </div>
                {readerPages.length > 0 && (
                  <div className="ebook-reader__pager">
                    <button
                      type="button"
                      className="ebook-reader__page-button"
                      onClick={() =>
                        setPageIndex((current) => Math.max(0, current - 1))
                      }
                      disabled={pageIndex <= 0}
                    >
                      {t.status.readerPrevPage}
                    </button>
                    <span className="ebook-reader__page-label">
                      {t.status.readerPageLabel(
                        pageIndex + 1,
                        readerPages.length,
                      )}
                    </span>
                    <button
                      type="button"
                      className="ebook-reader__page-button"
                      onClick={() =>
                        setPageIndex((current) =>
                          Math.min(readerPages.length - 1, current + 1),
                        )
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
                    <span>
                      {t.status.readerSegmentLabel(playback.segmentIndex + 1)}
                    </span>
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
                    "--reader-font-scale": prefs.fontScale,
                    "--reader-line-height": prefs.lineHeight,
                    "--reader-width": `${prefs.widthRem}rem`,
                  } as CSSProperties
                }
              >
                <div
                  ref={articleHostRef}
                  className="ebook-reader__content-host"
                />
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

function countMatches(text: string, query: string): number {
  if (!text || !query) {
    return 0;
  }
  const escaped = escapeRegExp(query);
  const regex = new RegExp(escaped, "gi");
  return Array.from(text.matchAll(regex)).length;
}

interface ReaderPage {
  html: string;
  hasAudio: boolean;
}

function buildReaderPages(
  sourceHtml: string | undefined,
  fallbackText: string,
  options: { audioText: string; searchText: string },
  prefs: ReaderPrefs,
): ReaderPage[] {
  if (typeof window === "undefined") {
    return [{ html: buildReaderHtmlFallback(fallbackText), hasAudio: false }];
  }

  const parser = new DOMParser();
  const baseMarkup =
    sourceHtml?.trim() || buildReaderHtmlFallback(fallbackText);
  const doc = parser.parseFromString(baseMarkup, "text/html");
  const root = doc.body;

  sanitizeReaderTree(root, doc);
  applyReaderHighlight(root, doc, options.audioText.trim(), "audio");
  applyReaderHighlight(root, doc, options.searchText.trim(), "search");
  const pages = paginateReaderRoot(root, prefs);
  return pages.length > 0
    ? pages
    : [{ html: buildReaderHtmlFallback(fallbackText), hasAudio: false }];
}

function buildReaderHtmlFallback(text: string): string {
  const source = (text || "").trim();
  if (!source) {
    return "<p></p>";
  }
  return source
    .split(/\n{2,}/)
    .map(
      (paragraph) => `<p>${escapeHtml(paragraph).replace(/\n/g, "<br />")}</p>`,
    )
    .join("");
}

function paginateReaderRoot(
  root: HTMLElement,
  prefs: ReaderPrefs,
): ReaderPage[] {
  const pageSource = resolvePaginationSource(root);
  const blocks = Array.from(pageSource.childNodes)
    .map((node) => {
      if (node.nodeType === Node.TEXT_NODE) {
        const text = node.textContent?.trim() || "";
        return text ? `<p>${escapeHtml(text)}</p>` : "";
      }
      return node instanceof Element ? node.outerHTML : "";
    })
    .filter(Boolean);

  if (blocks.length === 0) {
    return [];
  }

  const charBudget = estimateReaderPageChars(prefs);
  const pages: ReaderPage[] = [];
  let currentBlocks: string[] = [];
  let currentChars = 0;
  let currentHasAudio = false;

  blocks.forEach((block) => {
    const blockTextLength = stripHtml(block).length;
    const nextChars = currentChars + blockTextLength;
    const blockHasAudio =
      block.includes("data-reader-audio='true'") ||
      block.includes('data-reader-audio="true"');
    if (currentBlocks.length > 0 && nextChars > charBudget) {
      pages.push({
        html: currentBlocks.join(""),
        hasAudio: currentHasAudio,
      });
      currentBlocks = [];
      currentChars = 0;
      currentHasAudio = false;
    }
    currentBlocks.push(block);
    currentChars += blockTextLength;
    currentHasAudio = currentHasAudio || blockHasAudio;
  });

  if (currentBlocks.length > 0) {
    pages.push({
      html: currentBlocks.join(""),
      hasAudio: currentHasAudio,
    });
  }

  return pages;
}

function resolvePaginationSource(root: HTMLElement): HTMLElement {
  if (root.children.length !== 1) {
    return root;
  }
  const child = root.firstElementChild;
  if (
    child instanceof HTMLElement &&
    ["section", "article", "div", "main"].includes(
      child.tagName.toLowerCase(),
    ) &&
    child.children.length > 1
  ) {
    return child;
  }
  return root;
}

function estimateReaderPageChars(prefs: ReaderPrefs): number {
  const widthFactor = prefs.widthRem / 48;
  const fontFactor = 1.05 / prefs.fontScale;
  const lineFactor = 1.75 / prefs.lineHeight;
  return Math.max(
    900,
    Math.min(4200, Math.round(2200 * widthFactor * fontFactor * lineFactor)),
  );
}

function stripHtml(value: string): string {
  return value
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function sanitizeReaderTree(root: HTMLElement, doc: Document): void {
  const allowedTags = new Set([
    "a",
    "blockquote",
    "br",
    "code",
    "div",
    "em",
    "figcaption",
    "figure",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "hr",
    "i",
    "li",
    "mark",
    "ol",
    "p",
    "pre",
    "section",
    "small",
    "span",
    "strong",
    "sub",
    "sup",
    "u",
    "ul",
  ]);
  const allowedStyleProps = new Set([
    "font-style",
    "font-weight",
    "font-family",
    "font-size",
    "text-align",
    "text-decoration",
    "text-transform",
    "letter-spacing",
    "margin-left",
    "margin-right",
    "padding-left",
    "padding-right",
  ]);
  const elements = Array.from(root.querySelectorAll("*"));

  elements.forEach((element) => {
    const tag = element.tagName.toLowerCase();
    if (tag === "script" || tag === "style" || tag === "iframe") {
      element.remove();
      return;
    }
    if (tag === "img" || tag === "svg" || tag === "canvas") {
      const alt = element.getAttribute("alt")?.trim();
      if (alt) {
        const fallback = doc.createElement("p");
        fallback.textContent = alt;
        fallback.className = "ebook-reader__media-note";
        element.replaceWith(fallback);
      } else {
        element.remove();
      }
      return;
    }
    if (!allowedTags.has(tag)) {
      element.replaceWith(...Array.from(element.childNodes));
      return;
    }

    Array.from(element.attributes).forEach((attribute) => {
      const name = attribute.name.toLowerCase();
      if (name.startsWith("on")) {
        element.removeAttribute(attribute.name);
        return;
      }
      if (name === "href") {
        const value = attribute.value.trim();
        if (
          value &&
          !value.startsWith("#") &&
          !/^https?:\/\//i.test(value) &&
          !/^mailto:/i.test(value)
        ) {
          element.removeAttribute(attribute.name);
        }
        return;
      }
      if (name === "style") {
        const style = attribute.value
          .split(";")
          .map((entry) => entry.trim())
          .filter(Boolean)
          .map((entry) => {
            const [prop, ...rest] = entry.split(":");
            return [prop?.trim().toLowerCase(), rest.join(":").trim()] as const;
          })
          .filter(
            ([prop, value]) => prop && value && allowedStyleProps.has(prop),
          )
          .map(([prop, value]) => `${prop}: ${value}`);
        if (style.length > 0) {
          element.setAttribute("style", style.join("; "));
        } else {
          element.removeAttribute("style");
        }
        return;
      }
      if (name === "class") {
        return;
      }
      if (name === "id") {
        return;
      }
      if (!["href", "style", "title", "class", "id"].includes(name)) {
        element.removeAttribute(attribute.name);
      }
    });
  });
}

function applyReaderHighlight(
  root: HTMLElement,
  doc: Document,
  needle: string,
  kind: "audio" | "search",
): void {
  if (!needle) {
    return;
  }
  const matcher =
    kind === "search" ? new RegExp(escapeRegExp(needle), "gi") : null;
  const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const textNodes: Text[] = [];

  let current = walker.nextNode();
  while (current) {
    const parent = current.parentElement;
    if (
      current.nodeType === Node.TEXT_NODE &&
      parent &&
      !parent.closest(".ebook-reader__inline-highlight")
    ) {
      textNodes.push(current as Text);
    }
    current = walker.nextNode();
  }

  let audioAssigned = false;

  textNodes.forEach((textNode) => {
    const source = textNode.textContent || "";
    if (!source.trim()) {
      return;
    }

    const matches =
      kind === "audio"
        ? collectAudioMatches(source, needle, audioAssigned)
        : collectRegexMatches(source, matcher);
    if (matches.length === 0) {
      return;
    }

    const fragment = doc.createDocumentFragment();
    let cursor = 0;

    matches.forEach((match) => {
      if (match.start > cursor) {
        fragment.append(source.slice(cursor, match.start));
      }
      const marker = doc.createElement("mark");
      marker.className = `ebook-reader__inline-highlight is-${kind}`;
      if (kind === "audio" && !audioAssigned) {
        marker.setAttribute("data-reader-audio", "true");
        audioAssigned = true;
      }
      marker.textContent = source.slice(match.start, match.end);
      fragment.append(marker);
      cursor = match.end;
    });

    if (cursor < source.length) {
      fragment.append(source.slice(cursor));
    }

    textNode.replaceWith(fragment);
  });
}

function collectAudioMatches(
  source: string,
  needle: string,
  alreadyAssigned: boolean,
): Array<{ start: number; end: number }> {
  if (alreadyAssigned) {
    return [];
  }
  const start = source.indexOf(needle);
  if (start < 0) {
    return [];
  }
  return [{ start, end: start + needle.length }];
}

function collectRegexMatches(
  source: string,
  matcher: RegExp | null,
): Array<{ start: number; end: number }> {
  if (!matcher) {
    return [];
  }
  const matches: Array<{ start: number; end: number }> = [];
  for (const match of source.matchAll(matcher)) {
    const start = match.index ?? -1;
    if (start < 0) {
      continue;
    }
    matches.push({ start, end: start + match[0].length });
  }
  return matches;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
