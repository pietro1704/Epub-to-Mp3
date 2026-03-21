import { useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties } from "react";
import { conversionClient } from "../services/ConversionService";
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
  onRequestStart?: () => void;
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

export default function EbookReaderPanel({
  jobId,
  bookTitle,
  bookAuthor,
  chapterProgress,
  playback,
  onRequestStart,
}: EbookReaderPanelProps): JSX.Element | null {
  const t = useTranslations();
  const { locale } = useI18n();
  const [document, setDocument] = useState<BookTextDocument | null>(null);
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [selectedChapterIndex, setSelectedChapterIndex] = useState<number>(0);
  const [search, setSearch] = useState("");
  const [prefs, setPrefs] = useState<ReaderPrefs>(DEFAULT_PREFS);
  const activeAudioRef = useRef<HTMLSpanElement | null>(null);
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
  }, [jobId, t.status.readerUnavailable]);

  useEffect(() => {
    if (!prefs.followAudio || !playback) {
      return;
    }
    setSelectedChapterIndex(playback.chapterIndex);
  }, [prefs.followAudio, playback]);

  useEffect(() => {
    const marker = activeAudioRef.current;
    if (!marker) {
      return;
    }
    marker.scrollIntoView({ block: "center", behavior: "smooth" });
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
  const renderedParagraphs = useMemo(() => {
    if (!selectedChapter) {
      return [];
    }
    return buildParagraphs(selectedChapter.text, {
      audioText: currentSegmentText,
      searchText: deferredSearch,
    });
  }, [selectedChapter, currentSegmentText, deferredSearch]);

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
      className={`ebook-reader ebook-reader--${prefs.theme}`}
      aria-label={t.status.readerTitle}
    >
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
          {audioChapter && (
            <span className="ebook-reader__hero-chip ebook-reader__hero-chip--live">
              {locale === "pt"
                ? `Áudio no cap. ${audioChapter.index}`
                : `Audio on ch. ${audioChapter.index}`}
            </span>
          )}
        </div>
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
            onChange={(event) =>
              setPrefs((current) => ({
                ...current,
                followAudio: event.target.checked,
              }))
            }
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
            <h4>{t.status.chapterProgressTitle}</h4>
            <span>{chapters.length}</span>
          </div>
          {loading && (
            <div className="ebook-reader__state">{t.status.readerLoading}</div>
          )}
          {!loading && loadError && (
            <div className="ebook-reader__state ebook-reader__state--error">
              {loadError}
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
                      setPrefs((current) => ({
                        ...current,
                        followAudio: false,
                      }));
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
                {(() => {
                  let audioMarkerAssigned = false;
                  return renderedParagraphs.map((paragraph, paragraphIndex) => (
                    <p key={`${selectedChapter.index}-${paragraphIndex}`}>
                      {paragraph.length === 0 ? <br /> : null}
                      {paragraph.map((part, partIndex) => {
                        const className = [
                          "ebook-reader__fragment",
                          part.isAudio ? "is-audio" : "",
                          part.isSearch ? "is-search" : "",
                        ]
                          .filter(Boolean)
                          .join(" ");
                        const shouldAttachRef =
                          part.isAudio && !audioMarkerAssigned;
                        if (shouldAttachRef) {
                          audioMarkerAssigned = true;
                        }
                        return (
                          <span
                            key={`${selectedChapter.index}-${paragraphIndex}-${partIndex}`}
                            className={className}
                            ref={shouldAttachRef ? activeAudioRef : undefined}
                          >
                            {part.text}
                          </span>
                        );
                      })}
                    </p>
                  ));
                })()}
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

interface HighlightPart {
  text: string;
  isAudio: boolean;
  isSearch: boolean;
}

function countMatches(text: string, query: string): number {
  if (!text || !query) {
    return 0;
  }
  const escaped = escapeRegExp(query);
  const regex = new RegExp(escaped, "gi");
  return Array.from(text.matchAll(regex)).length;
}

function buildParagraphs(
  text: string,
  options: { audioText: string; searchText: string },
): HighlightPart[][] {
  const source = text || "";
  const ranges: Array<{
    start: number;
    end: number;
    type: "audio" | "search";
  }> = [];
  const audioNeedle = options.audioText.trim();
  const searchNeedle = options.searchText.trim();

  if (audioNeedle) {
    const audioStart = source.indexOf(audioNeedle);
    if (audioStart >= 0) {
      ranges.push({
        start: audioStart,
        end: audioStart + audioNeedle.length,
        type: "audio",
      });
    }
  }

  if (searchNeedle) {
    const regex = new RegExp(escapeRegExp(searchNeedle), "gi");
    for (const match of source.matchAll(regex)) {
      const start = match.index ?? -1;
      if (start < 0) {
        continue;
      }
      ranges.push({
        start,
        end: start + match[0].length,
        type: "search",
      });
    }
  }

  const boundaries = new Set<number>([0, source.length]);
  for (const range of ranges) {
    boundaries.add(range.start);
    boundaries.add(range.end);
  }

  const sortedBoundaries = [...boundaries].sort((a, b) => a - b);
  const parts: HighlightPart[] = [];
  for (let index = 0; index < sortedBoundaries.length - 1; index += 1) {
    const start = sortedBoundaries[index];
    const end = sortedBoundaries[index + 1];
    if (end <= start) {
      continue;
    }
    const chunk = source.slice(start, end);
    const isAudio = ranges.some(
      (range) =>
        range.type === "audio" && range.start <= start && range.end >= end,
    );
    const isSearch = ranges.some(
      (range) =>
        range.type === "search" && range.start <= start && range.end >= end,
    );
    parts.push({ text: chunk, isAudio, isSearch });
  }

  const paragraphs: HighlightPart[][] = [];
  let current: HighlightPart[] = [];
  for (const part of parts) {
    const pieces = part.text.split("\n\n");
    pieces.forEach((piece, pieceIndex) => {
      if (piece) {
        current.push({
          ...part,
          text: piece,
        });
      }
      if (pieceIndex < pieces.length - 1) {
        paragraphs.push(current);
        current = [];
      }
    });
  }
  if (current.length > 0 || paragraphs.length === 0) {
    paragraphs.push(current);
  }
  return paragraphs;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
