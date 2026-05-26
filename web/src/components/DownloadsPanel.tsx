import { useCallback, useEffect, useRef, useState } from "react";
import { useI18n, useTranslations } from "../i18n/I18nProvider";
import type { Locale } from "../i18n/translations";
import { downloadFile, isTauri } from "../lib/tauri";
import {
  ConversionState,
  DownloadAsset,
  StatusEntry,
} from "../types/conversion";

interface DownloadsPanelContext {
  title: string;
  subtitle?: string;
  actionLabel: string;
  onAction: () => void;
}

interface DownloadsPanelProps {
  downloads: DownloadAsset[];
  phase: ConversionState["phase"];
  onReset: () => void;
  isBusy: boolean;
  cliCommand?: string;
  log: StatusEntry[];
  rawLog?: string[] | null;
  showRawLog?: boolean;
  context?: DownloadsPanelContext;
  shareTitle?: string;
}

export default function DownloadsPanel({
  downloads,
  phase,
  onReset,
  isBusy,
  cliCommand,
  log,
  rawLog,
  showRawLog = false,
  context,
  shareTitle,
}: DownloadsPanelProps): JSX.Element {
  const t = useTranslations();
  const { locale } = useI18n();
  const hasDownloads = downloads.length > 0;
  const [logPreview, setLogPreview] = useState<{
    open: boolean;
    loading: boolean;
    content: string;
    error: string | null;
  }>({
    open: false,
    loading: false,
    content: "",
    error: null,
  });
  const verboseLogRef = useRef<HTMLPreElement>(null);
  const [downloadProgress, setDownloadProgress] = useState<Map<string, number>>(
    new Map(),
  );

  useEffect(() => {
    const handlePlay = (event: Event) => {
      const target = event.target;
      if (!(target instanceof HTMLAudioElement)) {
        return;
      }
      if (!target.classList.contains("chapter-item__player")) {
        return;
      }
      const players = document.querySelectorAll<HTMLAudioElement>(
        "audio.chapter-item__player",
      );
      players.forEach((audio) => {
        if (audio !== target && !audio.paused) {
          audio.pause();
        }
      });
    };
    document.addEventListener("play", handlePlay, true);
    return () => document.removeEventListener("play", handlePlay, true);
  }, []);

  const zipFile = downloads.find((d) => d.name.toLowerCase().endsWith(".zip"));
  const logFile = downloads.find((d) => d.name.toLowerCase().endsWith(".log"));
  const chapters = downloads.filter((d) =>
    d.name.toLowerCase().endsWith(".mp3"),
  );

  const shareUrl = zipFile?.url ?? downloads[0]?.url;
  const shareBookTitle = shareTitle?.trim() || t.status.bookFallbackTitle;
  const [shareFeedback, setShareFeedback] = useState<string | null>(null);

  useEffect(() => {
    setShareFeedback(null);
  }, [shareTitle, shareUrl]);

  useEffect(() => {
    if (!shareFeedback) {
      return;
    }
    if (typeof window === "undefined") {
      return;
    }
    const timeout = window.setTimeout(() => setShareFeedback(null), 3500);
    return () => window.clearTimeout(timeout);
  }, [shareFeedback]);

  useEffect(() => {
    setLogPreview({ open: false, loading: false, content: "", error: null });
  }, [logFile?.url]);

  const toggleLogPreview = async () => {
    if (!logFile) return;
    if (logPreview.open) {
      setLogPreview((prev) => ({ ...prev, open: false }));
      return;
    }
    setLogPreview({ open: true, loading: true, content: "", error: null });
    try {
      const response = await fetch(logFile.url);
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
      const text = await response.text();
      setLogPreview({ open: true, loading: false, content: text, error: null });
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown";
      setLogPreview({
        open: true,
        loading: false,
        content: "",
        error: t.downloads.logError(message),
      });
    }
  };

  const handleDownload = useCallback(
    (e: React.MouseEvent<HTMLAnchorElement>, url: string, filename: string) => {
      if (!isTauri()) return; // let browser handle it normally
      e.preventDefault();
      setDownloadProgress((prev) => new Map(prev).set(url, 0));
      downloadFile(url, filename, (loaded, total) => {
        setDownloadProgress((prev) =>
          new Map(prev).set(url, Math.round((loaded / total) * 100)),
        );
      })
        .then(() => {
          setDownloadProgress((prev) => {
            const next = new Map(prev);
            next.delete(url);
            return next;
          });
        })
        .catch((err) => {
          console.error("[DownloadsPanel] download failed", err);
          setDownloadProgress((prev) => {
            const next = new Map(prev);
            next.delete(url);
            return next;
          });
        });
    },
    [],
  );

  const shareMessage = t.downloads.shareMessage(shareBookTitle);

  const handleCopyLink = async () => {
    if (!shareUrl) {
      setShareFeedback(t.downloads.shareUnavailable);
      return;
    }
    try {
      if (
        typeof navigator !== "undefined" &&
        navigator.clipboard &&
        typeof navigator.clipboard.writeText === "function"
      ) {
        await navigator.clipboard.writeText(shareUrl);
      } else if (typeof document !== "undefined") {
        const textarea = document.createElement("textarea");
        textarea.value = shareUrl;
        textarea.style.position = "fixed";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand("copy");
        document.body.removeChild(textarea);
      } else {
        throw new Error("clipboard-not-supported");
      }
      setShareFeedback(t.downloads.shareCopied);
    } catch (error) {
      console.warn("[DownloadsPanel] Failed to copy share link", error);
      setShareFeedback(t.downloads.shareCopyError);
    }
  };

  const handleNativeShare = async () => {
    if (!shareUrl) {
      setShareFeedback(t.downloads.shareUnavailable);
      return;
    }
    try {
      if (
        typeof navigator !== "undefined" &&
        typeof navigator.share === "function"
      ) {
        await navigator.share({
          title: shareBookTitle,
          text: shareMessage,
          url: shareUrl,
        });
        setShareFeedback(null);
        return;
      }
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") {
        return;
      }
      console.warn("[DownloadsPanel] Native share failed", error);
    }
    setShareFeedback(t.downloads.shareNativeUnavailable);
  };

  const handleWhatsappShare = () => {
    if (!shareUrl) {
      setShareFeedback(t.downloads.shareUnavailable);
      return;
    }
    if (typeof window === "undefined") {
      return;
    }
    const encoded = encodeURIComponent(`${shareMessage} ${shareUrl}`);
    const url = `https://wa.me/?text=${encoded}`;
    window.open(url, "_blank", "noopener,noreferrer");
  };

  return (
    <div className="downloads-panel">
      {context && (
        <div className="downloads-panel__context">
          <div>
            <p className="downloads-panel__context-title">{context.title}</p>
            {context.subtitle && (
              <p className="downloads-panel__context-subtitle">
                {context.subtitle}
              </p>
            )}
          </div>
          <button
            type="button"
            className="downloads-panel__context-action"
            onClick={context.onAction}
          >
            {context.actionLabel}
          </button>
        </div>
      )}

      {cliCommand && (
        <div className="downloads-panel__command-section">
          <h3>Executed command</h3>
          <code className="downloads-panel__command">{cliCommand}</code>
        </div>
      )}

      {showRawLog && (rawLog?.length || log.length) > 0 && (
        <div className="downloads-panel__command-section">
          <h3>Terminal output (verbose)</h3>
          <pre className="downloads-panel__log" ref={verboseLogRef}>
            {Array.isArray(rawLog) && rawLog.length > 0
              ? rawLog.join("\n")
              : log.map((entry) => entry.message).join("\n")}
          </pre>
        </div>
      )}

      {!hasDownloads && (
        <p className="downloads-panel__placeholder">
          {phase === "success"
            ? t.downloads.noDownloadsAfterSuccess
            : t.downloads.placeholder}
        </p>
      )}

      {hasDownloads && (
        <>
          {zipFile && (
            <div className="downloads-panel__primary">
              <a
                href={zipFile.url}
                download={zipFile.name}
                className="downloads-panel__zip-button"
                onClick={(e) => handleDownload(e, zipFile.url, zipFile.name)}
              >
                <span className="downloads-panel__zip-icon">📦</span>
                <span className="downloads-panel__zip-text">
                  <strong>{t.downloads.downloadZip}</strong>
                  <small>
                    {downloadProgress.has(zipFile.url)
                      ? `${downloadProgress.get(zipFile.url)}%`
                      : t.downloads.downloadZipHint(chapters.length)}
                  </small>
                </span>
              </a>
            </div>
          )}
          {logFile && (
            <div className="downloads-panel__logfile">
              <div className="downloads-panel__logfile-actions">
                <button
                  type="button"
                  className="downloads-panel__log-button"
                  onClick={toggleLogPreview}
                >
                  {logPreview.open ? t.downloads.hideLog : t.downloads.viewLog}
                </button>
                <a
                  href={logFile.url}
                  download={logFile.name}
                  className="downloads-panel__log-link"
                  onClick={(e) => handleDownload(e, logFile.url, logFile.name)}
                >
                  {t.downloads.downloadLog}
                </a>
              </div>
              {logPreview.open && (
                <div className="downloads-panel__log-preview">
                  {logPreview.loading && <p>{t.downloads.logLoading}</p>}
                  {!logPreview.loading && logPreview.error && (
                    <p className="downloads-panel__log-error">
                      {logPreview.error}
                    </p>
                  )}
                  {!logPreview.loading && !logPreview.error && (
                    <pre>{logPreview.content}</pre>
                  )}
                </div>
              )}
            </div>
          )}

          <div className="downloads-share downloads-share--top">
            <div className="downloads-share__text">
              <p className="downloads-share__title">{t.downloads.shareTitle}</p>
              <p className="downloads-share__subtitle">
                {t.downloads.shareSubtitle(shareBookTitle)}
              </p>
            </div>
            <div className="downloads-share__actions">
              <button
                type="button"
                className="downloads-share__button downloads-share__button--primary"
                onClick={handleNativeShare}
              >
                {t.downloads.shareNative}
              </button>
              <button
                type="button"
                className="downloads-share__button downloads-share__button--whatsapp"
                onClick={handleWhatsappShare}
              >
                {t.downloads.shareWhatsapp}
              </button>
              <button
                type="button"
                className="downloads-share__button downloads-share__button--secondary"
                onClick={handleCopyLink}
              >
                {t.downloads.shareCopyLink}
              </button>
            </div>
            {(shareFeedback || !shareUrl) && (
              <div className="downloads-share__feedback">
                {shareFeedback ?? t.downloads.shareUnavailable}
              </div>
            )}
          </div>

          {chapters.length > 0 && (
            <>
              <div className="downloads-panel__divider">
                <span>{t.downloads.orIndividual}</span>
              </div>
              <div className="downloads-chapters">
                {chapters.map((asset) => {
                  return (
                    <div
                      key={asset.url}
                      className="chapter-item chapter-item--expanded"
                    >
                      <div className="chapter-item__header">
                        <span
                          className="chapter-item__name chapter-item__name--multiline"
                          title={asset.name}
                        >
                          {asset.name}
                        </span>
                        {typeof asset.durationSeconds === "number" && (
                          <span className="chapter-item__duration">
                            {formatDuration(asset.durationSeconds, locale)}
                          </span>
                        )}
                      </div>
                      <div className="chapter-item__content">
                        <audio
                          controls
                          className="chapter-item__player"
                          preload="metadata"
                        >
                          <source src={asset.url} type="audio/mpeg" />
                          {t.downloads.audioNotSupported}
                        </audio>
                        <a
                          href={asset.url}
                          download={asset.name}
                          className="chapter-item__download"
                          onClick={(e) =>
                            handleDownload(e, asset.url, asset.name)
                          }
                        >
                          {downloadProgress.has(asset.url)
                            ? `${downloadProgress.get(asset.url)}%`
                            : t.downloads.downloadChapter}
                        </a>
                      </div>
                    </div>
                  );
                })}
              </div>
            </>
          )}
        </>
      )}

      <button
        type="button"
        className="downloads-panel__cta"
        onClick={onReset}
        disabled={isBusy}
      >
        {hasDownloads
          ? t.downloads.resetWithDownloads
          : t.downloads.resetWithoutDownloads}
      </button>
    </div>
  );
}

function formatDuration(seconds: number, locale: Locale): string {
  const totalMinutes = Math.round(seconds / 60);
  if (totalMinutes < 1) return locale === "pt" ? "< 1 min" : "< 1 min";
  if (totalMinutes < 60) return `${totalMinutes} min`;
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (minutes === 0) {
    return locale === "pt" ? `${hours} h` : `${hours} h`;
  }
  return locale === "pt"
    ? `${hours} h ${minutes} min`
    : `${hours} h ${minutes} min`;
}
