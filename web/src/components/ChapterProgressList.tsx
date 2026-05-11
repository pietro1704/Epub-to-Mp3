import { useCallback, useEffect, useRef, useState } from "react";
import {
  AudioChunkEntry,
  ChapterProgressEntry,
  ChapterStreamManifest,
} from "../types/conversion";
import { conversionClient } from "../services/ConversionService";
import { useI18n, useTranslations } from "../i18n/I18nProvider";
import { safeScrollIntoView } from "../utils/safeScrollIntoView";

interface ChapterProgressListProps {
  entries: ChapterProgressEntry[];
  jobId?: string;
  playingSegment?: { chapterIndex: number; segmentIndex: number } | null;
}

function engineBadgeClass(engine: string): string {
  const key = engine.toLowerCase().split(/[-_]/)[0];
  const known = ["edge", "piper"];
  return known.includes(key)
    ? `engine-badge engine-badge--${key}`
    : "engine-badge";
}

function EngineBadges({ entry }: { entry: ChapterProgressEntry }) {
  // Prefer engineSequence (full fallback trail) over single engine field
  const seq = entry.engineSequence?.filter(Boolean);
  const engines =
    seq && seq.length > 0 ? seq : entry.engine ? [entry.engine] : [];
  if (engines.length === 0) return null;
  // Deduplicate consecutive identical engines
  const deduped = engines.filter((e, i) => i === 0 || e !== engines[i - 1]);
  return (
    <span className="chapter-progress__engine">
      {deduped.map((eng, i) => (
        <span key={i}>
          {i > 0 && <span className="engine-badge-arrow">→</span>}
          <span className={engineBadgeClass(eng)}>{eng}</span>
        </span>
      ))}
    </span>
  );
}

const STATUS_ICONS: Record<ChapterProgressEntry["status"], string> = {
  completed: "✅",
  processing: "⏳",
  pending: "•",
  skipped: "⏭️",
  failed: "⚠️",
  cancelled: "⛔",
  retrying: "🔄",
};

const STREAM_REFRESH_MS = 1500;

export default function ChapterProgressList({
  entries,
  jobId,
  playingSegment,
}: ChapterProgressListProps): JSX.Element | null {
  const t = useTranslations();
  const { locale } = useI18n();
  const containerRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLUListElement>(null);
  const headerRef = useRef<HTMLDivElement>(null);
  const hasEntries = entries.length > 0;
  const [expanded, setExpanded] = useState<Record<number, boolean>>({});
  const [expandAllChapters, setExpandAllChapters] = useState(false);
  const [expandAllTexts, setExpandAllTexts] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");
  const [searchHits, setSearchHits] = useState(0);
  const [activeMatchIndex, setActiveMatchIndex] = useState(0);
  const [manifests, setManifests] = useState<
    Record<number, ChapterStreamManifest | null>
  >({});
  const [manifestLoading, setManifestLoading] = useState<
    Record<number, boolean>
  >({});
  const [manifestErrors, setManifestErrors] = useState<
    Record<number, string | null>
  >({});
  const matchCounterRef = useRef(0);
  // Track which segment texts are expanded (key: "chapterIndex-segmentIndex")
  const [expandedTexts, setExpandedTexts] = useState<Record<string, boolean>>(
    {},
  );

  const toggleSegmentText = (chapterIndex: number, segmentIndex: number) => {
    const key = `${chapterIndex}-${segmentIndex}`;
    setExpandedTexts((prev) => ({ ...prev, [key]: !prev[key] }));
  };

  const completedCount = entries.filter(
    (entry) => entry.status === "completed",
  ).length;

  const scrollToCurrent = useCallback(
    (behavior: ScrollBehavior = "smooth") => {
      const container = containerRef.current;
      const list = listRef.current;
      if (!container || !list) return;

      // Find first processing/retrying item, or last completed item
      const processingIndex = entries.findIndex(
        (entry) => entry.status === "processing" || entry.status === "retrying",
      );
      const targetIndex =
        processingIndex >= 0
          ? processingIndex
          : entries.findIndex((entry) => entry.status === "completed");

      if (targetIndex >= 0) {
        const items = list.children;
        const target = items[targetIndex] as HTMLElement | undefined;
        if (target) {
          const containerRect = container.getBoundingClientRect();
          const targetRect = target.getBoundingClientRect();
          const headerHeight = headerRef.current?.offsetHeight ?? 0;
          const relativeTop =
            targetRect.top -
            containerRect.top +
            container.scrollTop -
            headerHeight;
          const viewportHeight = container.clientHeight - headerHeight;
          const offset = Math.max(
            0,
            relativeTop - Math.max(0, (viewportHeight - targetRect.height) / 2),
          );
          container.scrollTo({ top: offset, behavior });
        }
      }
    },
    [entries],
  );

  // Handle audio playback - pause other audios when one starts playing
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const handlePlay = (event: Event) => {
      const playingAudio = event.target as HTMLAudioElement;
      // Pause all other audio elements
      const allAudios = container.querySelectorAll("audio");
      allAudios.forEach((audio) => {
        if (audio !== playingAudio && !audio.paused) {
          audio.pause();
        }
      });
    };

    // Add event listener to container (event delegation)
    container.addEventListener("play", handlePlay, true);

    return () => {
      container.removeEventListener("play", handlePlay, true);
    };
  }, []);

  const toggleChapter = (chapterIndex: number) => {
    setExpanded((prev) => {
      const next = { ...prev, [chapterIndex]: !prev[chapterIndex] };
      return next;
    });
  };

  const fetchManifest = useCallback(
    async (chapterIndex: number, silent = false) => {
      if (!jobId || !conversionClient.getChapterManifest) return;
      if (!silent) {
        setManifestLoading((prev) => ({ ...prev, [chapterIndex]: true }));
        setManifestErrors((prev) => ({ ...prev, [chapterIndex]: null }));
      }
      try {
        const data = await conversionClient.getChapterManifest(
          jobId,
          chapterIndex,
        );
        if (data) {
          setManifests((prev) => ({ ...prev, [chapterIndex]: data }));
          setManifestErrors((prev) => ({ ...prev, [chapterIndex]: null }));
        }
      } catch (err) {
        const message =
          err instanceof Error ? err.message : "Failed to load segments";
        setManifestErrors((prev) => ({ ...prev, [chapterIndex]: message }));
      } finally {
        if (!silent) {
          setManifestLoading((prev) => ({ ...prev, [chapterIndex]: false }));
        }
      }
    },
    [jobId],
  );

  const fetchAllManifests = useCallback(
    async (chapterIndices: number[]) => {
      if (!jobId) return;
      const pending = chapterIndices.filter((index) => !manifests[index]);
      if (pending.length === 0) return;
      const queue = [...pending];
      const concurrency = 4;
      const workers = Array.from({ length: concurrency }).map(async () => {
        while (queue.length > 0) {
          const index = queue.shift();
          if (index === undefined) break;
          await fetchManifest(index, true);
        }
      });
      await Promise.all(workers);
    },
    [fetchManifest, jobId, manifests],
  );

  const handleSearchChange = (value: string) => {
    setSearchQuery(value);
  };

  const highlightMatches = useCallback(
    (text: string, query: string) => {
      if (!query.trim()) return text;
      try {
        const safe = query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const regex = new RegExp(safe, "gi");
        const parts = text.split(regex);
        const matches = text.match(regex) || [];
        const result: (string | JSX.Element)[] = [];
        parts.forEach((part, idx) => {
          result.push(part);
          if (idx < matches.length) {
            const matchIndex = matchCounterRef.current;
            const isActive = matchIndex === activeMatchIndex;
            matchCounterRef.current += 1;
            result.push(
              <mark
                key={`hit-${idx}-${matchIndex}`}
                className={`chapter-progress__highlight${
                  isActive ? " chapter-progress__highlight--active" : ""
                }`}
              >
                {matches[idx]}
              </mark>,
            );
          }
        });
        return result;
      } catch {
        return text;
      }
    },
    [activeMatchIndex],
  );

  const buildFullText = useCallback(() => {
    const chapters = [...entries].sort((a, b) => a.index - b.index);
    const lines: string[] = [];
    chapters.forEach((entry) => {
      lines.push(`${entry.index}. ${entry.name}`);
      lines.push("");
      const manifest = manifests[entry.index];
      const chunks = (manifest?.chunks || [])
        .slice()
        .sort((a, b) => a.index - b.index);
      const chunkText = chunks
        .map((chunk) => chunk.text)
        .filter((text): text is string => Boolean(text && text.trim()));
      if (chunkText.length > 0) {
        lines.push(chunkText.join("\n"));
      } else {
        lines.push(
          locale === "pt" ? "[texto indisponível]" : "[text unavailable]",
        );
      }
      lines.push("\n");
    });
    return lines.join("\n").trim();
  }, [entries, locale, manifests]);

  const handleDownloadText = useCallback(async () => {
    if (!jobId) return;
    setExpandAllChapters(true);
    await fetchAllManifests(entries.map((entry) => entry.index));
    const fullText = buildFullText();
    if (!fullText) return;
    const blob = new Blob([fullText], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `book-${jobId}.txt`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  }, [buildFullText, entries, fetchAllManifests, jobId]);

  useEffect(() => {
    if (!expandAllTexts || !searchQuery.trim()) {
      setSearchHits(0);
      return;
    }
    const query = searchQuery.trim().toLowerCase();
    let hits = 0;
    Object.values(manifests).forEach((manifest) => {
      (manifest?.chunks || []).forEach((chunk) => {
        if (chunk.text) {
          const text = chunk.text.toLowerCase();
          const count = text.split(query).length - 1;
          if (count > 0) {
            hits += count;
          }
        }
      });
    });
    setSearchHits(hits);
  }, [expandAllTexts, manifests, searchQuery]);

  const handleScrollTop = useCallback(() => {
    containerRef.current?.scrollTo({ top: 0, behavior: "smooth" });
  }, []);

  const scrollToMatch = useCallback(
    (index: number) => {
      const container = containerRef.current;
      if (!container) return;
      const marks = container.querySelectorAll(".chapter-progress__highlight");
      if (marks.length === 0) return;
      const normalized = ((index % marks.length) + marks.length) % marks.length;
      const target = marks[normalized] as HTMLElement;
      safeScrollIntoView(target, { behavior: "smooth", block: "center" });
      setActiveMatchIndex(normalized);
    },
    [setActiveMatchIndex],
  );

  const handleNextMatch = useCallback(() => {
    if (!searchHits) return;
    scrollToMatch(activeMatchIndex + 1);
  }, [activeMatchIndex, scrollToMatch, searchHits]);

  const handlePrevMatch = useCallback(() => {
    if (!searchHits) return;
    scrollToMatch(activeMatchIndex - 1);
  }, [activeMatchIndex, scrollToMatch, searchHits]);

  useEffect(() => {
    if (!expandAllTexts) {
      setSearchQuery("");
      setSearchHits(0);
      setActiveMatchIndex(0);
    }
  }, [expandAllTexts]);

  useEffect(() => {
    if (!expandAllTexts || !searchQuery.trim()) {
      setActiveMatchIndex(0);
      return;
    }
    scrollToMatch(0);
  }, [expandAllTexts, searchQuery, scrollToMatch, searchHits]);

  const handleToggleAllChapters = useCallback(() => {
    const next = !expandAllChapters;
    setExpandAllChapters(next);
    if (next) {
      const allExpanded = entries.reduce<Record<number, boolean>>(
        (acc, entry) => {
          acc[entry.index] = true;
          return acc;
        },
        {},
      );
      setExpanded(allExpanded);
      void fetchAllManifests(entries.map((entry) => entry.index));
    } else {
      setExpanded({});
    }
  }, [entries, expandAllChapters, fetchAllManifests]);

  const handleToggleAllTexts = useCallback(() => {
    const next = !expandAllTexts;
    setExpandAllTexts(next);
    if (next) {
      setExpandAllChapters(true);
      const allExpanded = entries.reduce<Record<number, boolean>>(
        (acc, entry) => {
          acc[entry.index] = true;
          return acc;
        },
        {},
      );
      setExpanded(allExpanded);
      void fetchAllManifests(entries.map((entry) => entry.index));
    }
  }, [entries, expandAllTexts, fetchAllManifests]);

  // Auto-expand processing chapters so segments are visible immediately
  useEffect(() => {
    if (!jobId) return;
    const processingIndices = entries
      .filter(
        (entry) => entry.status === "processing" || entry.status === "retrying",
      )
      .map((entry) => entry.index);

    if (processingIndices.length > 0) {
      setExpanded((prev) => {
        const next = { ...prev };
        let changed = false;
        for (const idx of processingIndices) {
          if (!next[idx]) {
            next[idx] = true;
            changed = true;
          }
        }
        return changed ? next : prev;
      });
    }
  }, [jobId, entries]);

  // Auto-expand and scroll to playing segment
  useEffect(() => {
    if (!playingSegment) return;
    const { chapterIndex, segmentIndex } = playingSegment;

    // Auto-expand the chapter being played
    setExpanded((prev) => {
      if (prev[chapterIndex]) return prev;
      return { ...prev, [chapterIndex]: true };
    });

    // Scroll to the playing segment after a short delay (to allow expansion animation)
    const timer = window.setTimeout(() => {
      const container = containerRef.current;
      if (!container) return;

      const segmentElement = container.querySelector(
        `[data-segment-key="${chapterIndex}-${segmentIndex}"]`,
      );

      if (segmentElement) {
        safeScrollIntoView(segmentElement, {
          behavior: "smooth",
          block: "center",
        });
      }
    }, 300);

    return () => window.clearTimeout(timer);
  }, [playingSegment]);

  useEffect(() => {
    if (!expandAllChapters) return;
    setExpanded((prev) => {
      const next = { ...prev };
      let changed = false;
      for (const entry of entries) {
        if (!next[entry.index]) {
          next[entry.index] = true;
          changed = true;
        }
      }
      return changed ? next : prev;
    });
  }, [entries, expandAllChapters]);

  useEffect(() => {
    // Keep streaming chapters refreshed while they process
    if (!jobId) return;
    const openIndices = entries
      .filter((entry) => expanded[entry.index])
      .map((entry) => entry.index);
    if (openIndices.length === 0) return;

    const refresh = () => {
      openIndices.forEach((index) => fetchManifest(index, true));
    };
    refresh();
    const id = window.setInterval(refresh, STREAM_REFRESH_MS);
    return () => window.clearInterval(id);
  }, [jobId, entries, expanded, fetchManifest]);

  const segmentCountLabel = useCallback(
    (count: number) => t.status.chapterSegmentCount(count),
    [t.status],
  );

  const segmentDurationLabel = useCallback((value?: number) => {
    if (typeof value !== "number" || !Number.isFinite(value)) return null;
    const minutes = Math.floor(value / 60);
    const seconds = Math.round(value % 60);
    return `${minutes.toString().padStart(2, "0")}:${seconds
      .toString()
      .padStart(2, "0")}`;
  }, []);

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
            onClick={() => scrollToCurrent("smooth")}
            title={t.status.chapterGoToCurrentTitle}
            style={{ fontSize: "0.8rem", padding: "0.35rem 0.75rem" }}
          >
            ↓ {t.status.chapterGoToCurrent}
          </button>
          <button
            type="button"
            className="status-panel__toggle"
            onClick={handleToggleAllChapters}
            disabled={!jobId}
          >
            {expandAllChapters
              ? t.status.collapseAllChapters
              : t.status.expandAllChapters}
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
              <button
                type="button"
                className="status-panel__toggle"
                onClick={handleScrollTop}
              >
                {t.status.scrollToTop}
              </button>
              <button
                type="button"
                className="status-panel__toggle"
                onClick={handleDownloadText}
              >
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
                  {searchQuery.trim() ? t.status.searchCount(searchHits) : ""}
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
                  {STATUS_ICONS[status] ?? "•"}
                </span>
                <span className="chapter-progress__name">
                  {entry.index}. {entry.name}
                </span>
                <span
                  className="chapter-progress__status"
                  aria-label={statusLabel}
                >
                  {statusLabel} <EngineBadges entry={entry} />
                  {/* Retry information */}
                  {entry.status === "retrying" && (
                    <span className="chapter-progress__retry">
                      {entry.retryCount !== undefined &&
                        entry.maxRetries !== undefined && (
                          <span className="chapter-progress__retry-count">
                            ({entry.retryCount}/{entry.maxRetries})
                          </span>
                        )}
                      {entry.paramAdjustment && (
                        <span
                          className="chapter-progress__param-adj"
                          title={entry.retryReason}
                        >
                          {entry.paramAdjustment}
                        </span>
                      )}
                    </span>
                  )}
                  {entry.status === "completed" && (
                    <span className="chapter-progress__time">
                      {formatChapterDuration(
                        entry.elapsedSeconds,
                        t.status.chapterCompletedIn,
                      ) ?? "--"}
                      {typeof entry.charsPerSecond === "number"
                        ? ` • ~${entry.charsPerSecond} chars/s`
                        : ""}
                      {/* Show if retry was needed */}
                      {entry.retryCount !== undefined &&
                        entry.retryCount > 0 && (
                          <span
                            className="chapter-progress__retry-badge"
                            title={
                              locale === "pt"
                                ? `Success after ${entry.retryCount} attempt(s)`
                                : `Success after ${entry.retryCount} retry(s)`
                            }
                          >
                            🔄{entry.retryCount}
                          </span>
                        )}
                    </span>
                  )}
                  <span
                    className="chapter-progress__chevron"
                    aria-hidden="true"
                  >
                    {isExpanded ? "▾" : "▸"}
                  </span>
                </span>
              </button>
              {isExpanded && (
                <div className="chapter-progress__details">
                  {entry.downloadUrl && (
                    <div className="chapter-progress__download-audio">
                      <strong>{t.status.chapterFullAudio}</strong>
                      <audio
                        controls
                        preload="metadata"
                        className="chapter-progress__audio"
                      >
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
                          : status === "completed" && !loading
                            ? t.status.chapterSegmentsNone
                            : t.status.chapterSegmentsWaiting}
                      </span>
                    </div>
                    {manifestError && (
                      <p className="chapter-progress__error">{manifestError}</p>
                    )}
                    {loading && (
                      <p className="chapter-progress__loading">
                        {t.status.chapterSegmentsLoading}
                      </p>
                    )}
                    {segments.length > 0 && (
                      <ul className="chapter-progress__segments-list">
                        {segments.map((segment: AudioChunkEntry) => {
                          const textKey = `${entry.index}-${segment.index}`;
                          const isTextExpanded = Boolean(
                            expandAllTexts || expandedTexts[textKey],
                          );
                          const hasText = Boolean(segment.text?.trim());
                          const isPlaying =
                            playingSegment?.chapterIndex === entry.index &&
                            playingSegment?.segmentIndex === segment.index;
                          return (
                            <li
                              key={`segment-${entry.index}-${segment.index}`}
                              className={`chapter-progress__segment ${
                                isPlaying
                                  ? "chapter-progress__segment--playing"
                                  : ""
                              }`}
                              data-segment-key={`${entry.index}-${segment.index}`}
                            >
                              <div className="chapter-progress__segment-header">
                                <div className="chapter-progress__segment-meta">
                                  <span className="chapter-progress__segment-title">
                                    {t.status.chapterSegmentTitle(
                                      segment.index + 1,
                                    )}
                                  </span>
                                  {segment.durationSeconds !== undefined && (
                                    <span className="chapter-progress__segment-duration">
                                      {segmentDurationLabel(
                                        segment.durationSeconds,
                                      )}
                                    </span>
                                  )}
                                </div>
                                {hasText && !expandAllTexts && (
                                  <button
                                    type="button"
                                    className="chapter-progress__segment-toggle"
                                    onClick={() =>
                                      toggleSegmentText(
                                        entry.index,
                                        segment.index,
                                      )
                                    }
                                    title={
                                      isTextExpanded
                                        ? t.status.chapterSegmentHideText
                                        : t.status.chapterSegmentShowText
                                    }
                                  >
                                    {isTextExpanded ? "▾" : "▸"}{" "}
                                    {t.status.chapterSegmentText}
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
                                    expandAllTexts
                                      ? " chapter-progress__segment-text--full"
                                      : ""
                                  }`}
                                >
                                  {expandAllTexts && searchQuery.trim()
                                    ? highlightMatches(
                                        segment.text || "",
                                        searchQuery,
                                      )
                                    : segment.text}
                                </div>
                              )}
                            </li>
                          );
                        })}
                      </ul>
                    )}
                    {!loading && segments.length === 0 && (
                      <p className="chapter-progress__empty">
                        {t.status.chapterSegmentsEmpty}
                      </p>
                    )}
                    {!jobId && (
                      <p className="chapter-progress__hint">
                        {locale === "pt"
                          ? "Start a conversion to load the segments."
                          : "Start a conversion to load segments."}
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

function formatChapterDuration(
  value: number | undefined,
  formatLabel: (value: string) => string,
): string | null {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return null;
  }
  const total = Math.max(0, Math.round(value));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const parts: string[] = [];
  if (hours > 0) {
    parts.push(`${hours.toString().padStart(2, "0")}h`);
  }
  if (hours > 0 || minutes > 0) {
    parts.push(`${minutes.toString().padStart(2, "0")}m`);
  }
  parts.push(`${seconds.toString().padStart(2, "0")}s`);
  return formatLabel(parts.join(" "));
}
