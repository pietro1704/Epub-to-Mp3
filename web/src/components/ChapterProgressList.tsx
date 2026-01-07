import { useCallback, useEffect, useRef } from "react";
import { ChapterProgressEntry } from "../types/conversion";
import { useI18n, useTranslations } from "../i18n/I18nProvider";

interface ChapterProgressListProps {
  entries: ChapterProgressEntry[];
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

export default function ChapterProgressList({
  entries,
}: ChapterProgressListProps): JSX.Element | null {
  const t = useTranslations();
  const { locale } = useI18n();
  const containerRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLUListElement>(null);
  const headerRef = useRef<HTMLDivElement>(null);
  const hasEntries = entries.length > 0;

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
          return (
            <li
              key={`chapter-${entry.index}`}
              className={`chapter-progress__item chapter-progress__item--${status}`}
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
                  <>
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
                    {entry.downloadUrl && (
                      <audio
                        controls
                        preload="metadata"
                        className="chapter-progress__audio"
                        onClick={(e) => e.stopPropagation()}
                      >
                        <source src={entry.downloadUrl} type="audio/mpeg" />
                        {locale === "pt"
                          ? "Seu navegador não suporta áudio"
                          : "Your browser does not support audio"}
                      </audio>
                    )}
                  </>
                )}
              </span>
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
