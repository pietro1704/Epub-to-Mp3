import { useCallback, useEffect, useRef, useState } from "react";
import {
  AudioChunkEntry,
  ChapterProgressEntry,
  ChapterStreamManifest,
} from "../types/conversion";
import { conversionClient } from "../services/ConversionService";
import { useI18n, useTranslations } from "../i18n/I18nProvider";

interface ChapterProgressListProps {
  entries: ChapterProgressEntry[];
  jobId?: string;
}

const STATUS_ICONS: Record<ChapterProgressEntry["status"], string> = {
  completed: "✅",
  processing: "⏳",
  pending: "•",
  skipped: "↷",
  failed: "⚠️",
  cancelled: "⛔",
  retrying: "🔄",
};

const STREAM_REFRESH_MS = 3000;

export default function ChapterProgressList({
  entries,
  jobId,
}: ChapterProgressListProps): JSX.Element | null {
  const t = useTranslations();
  const { locale } = useI18n();
  const containerRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLUListElement>(null);
  const headerRef = useRef<HTMLDivElement>(null);
  const hasEntries = entries.length > 0;
  const [expanded, setExpanded] = useState<Record<number, boolean>>({});
  const [manifests, setManifests] = useState<
    Record<number, ChapterStreamManifest | null>
  >({});
  const [manifestLoading, setManifestLoading] = useState<
    Record<number, boolean>
  >({});
  const [manifestErrors, setManifestErrors] = useState<
    Record<number, string | null>
  >({});
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
          err instanceof Error ? err.message : "Falha ao carregar segments";
        setManifestErrors((prev) => ({ ...prev, [chapterIndex]: message }));
      } finally {
        if (!silent) {
          setManifestLoading((prev) => ({ ...prev, [chapterIndex]: false }));
        }
      }
    },
    [jobId],
  );

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
    (count: number) => {
      if (count <= 0)
        return locale === "pt" ? "sem segmentos" : "no segments yet";
      return locale === "pt" ? `${count} segmentos` : `${count} segments`;
    },
    [locale],
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

  return (
    <div className="chapter-progress" aria-live="polite" ref={containerRef}>
      <div className="chapter-progress__header" ref={headerRef}>
        <h3>{t.status.chapterProgressTitle}</h3>
        <div style={{ display: "flex", gap: "0.75rem", alignItems: "center" }}>
          <button
            type="button"
            className="status-panel__toggle"
            onClick={() => scrollToCurrent("smooth")}
            title={
              locale === "pt"
                ? "Ir para o capítulo atual"
                : "Go to current chapter"
            }
            style={{ fontSize: "0.8rem", padding: "0.35rem 0.75rem" }}
          >
            ↓ {locale === "pt" ? "Ver atual" : "Go to current"}
          </button>
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
                  {statusLabel}
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
                      {formatChapterDuration(entry.elapsedSeconds, locale) ??
                        "--"}
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
                                ? `Sucesso após ${entry.retryCount} tentativa(s)`
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
                      <strong>
                        {locale === "pt"
                          ? "Capítulo completo:"
                          : "Full chapter:"}
                      </strong>
                      <audio
                        controls
                        preload="metadata"
                        className="chapter-progress__audio"
                      >
                        <source src={entry.downloadUrl} type="audio/mpeg" />
                        {locale === "pt"
                          ? "Seu navegador não suporta áudio"
                          : "Your browser does not support audio"}
                      </audio>
                    </div>
                  )}
                  <div className="chapter-progress__segments">
                    <div className="chapter-progress__segments-header">
                      <strong>
                        {locale === "pt"
                          ? "Segmentos do capítulo"
                          : "Chapter segments"}
                      </strong>
                      <span className="chapter-progress__segments-meta">
                        {segments.length > 0
                          ? segmentCountLabel(segments.length)
                          : status === "completed" && !loading
                            ? locale === "pt"
                              ? "Sem segmentos disponíveis"
                              : "No segments available"
                            : locale === "pt"
                              ? "Aguardando segmentos..."
                              : "Waiting for segments..."}
                      </span>
                    </div>
                    {manifestError && (
                      <p className="chapter-progress__error">{manifestError}</p>
                    )}
                    {loading && (
                      <p className="chapter-progress__loading">
                        {locale === "pt"
                          ? "Carregando segmentos..."
                          : "Loading segments..."}
                      </p>
                    )}
                    {segments.length > 0 && (
                      <ul className="chapter-progress__segments-list">
                        {segments.map((segment: AudioChunkEntry) => {
                          const textKey = `${entry.index}-${segment.index}`;
                          const isTextExpanded = Boolean(
                            expandedTexts[textKey],
                          );
                          const hasText = Boolean(segment.text?.trim());
                          return (
                            <li
                              key={`segment-${entry.index}-${segment.index}`}
                              className="chapter-progress__segment"
                            >
                              <div className="chapter-progress__segment-header">
                                <div className="chapter-progress__segment-meta">
                                  <span className="chapter-progress__segment-title">
                                    {locale === "pt"
                                      ? `Segmento ${segment.index + 1}`
                                      : `Segment ${segment.index + 1}`}
                                  </span>
                                  {segment.durationSeconds !== undefined && (
                                    <span className="chapter-progress__segment-duration">
                                      {segmentDurationLabel(
                                        segment.durationSeconds,
                                      )}
                                    </span>
                                  )}
                                </div>
                                {hasText && (
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
                                      locale === "pt"
                                        ? isTextExpanded
                                          ? "Ocultar texto"
                                          : "Ver texto"
                                        : isTextExpanded
                                          ? "Hide text"
                                          : "Show text"
                                    }
                                  >
                                    {isTextExpanded ? "▾" : "▸"}{" "}
                                    {locale === "pt" ? "Texto" : "Text"}
                                  </button>
                                )}
                              </div>
                              <audio
                                controls
                                preload="metadata"
                                className="chapter-progress__audio"
                              >
                                <source src={segment.url} type="audio/mpeg" />
                                {locale === "pt"
                                  ? "Seu navegador não suporta áudio"
                                  : "Your browser does not support audio"}
                              </audio>
                              {isTextExpanded && hasText && (
                                <div className="chapter-progress__segment-text">
                                  {segment.text}
                                </div>
                              )}
                            </li>
                          );
                        })}
                      </ul>
                    )}
                    {!loading && segments.length === 0 && (
                      <p className="chapter-progress__empty">
                        {locale === "pt"
                          ? "Nenhum segmento disponível ainda."
                          : "No segments available yet."}
                      </p>
                    )}
                    {!jobId && (
                      <p className="chapter-progress__hint">
                        {locale === "pt"
                          ? "Inicie uma conversão para carregar os segmentos."
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

function formatChapterDuration(value?: number, locale?: string): string | null {
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
  const prefix = locale === "pt" ? "Concluído em" : "Completed in";
  return `${prefix} ${parts.join(" ")}`;
}
