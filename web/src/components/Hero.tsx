import {
  memo,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { useI18n, useTranslations } from "../i18n/I18nProvider";
import type { ConversionSummary, ConversionState } from "../types/conversion";
import { formatEta } from "../utils/formatEta";

interface HeroProps {
  title?: string;
  author?: string;
  coverUrl?: string;
  summary?: ConversionSummary;
  etaSeconds?: number | null;
  phase: ConversionState["phase"];
  voiceLabel?: string;
  engineLabel?: string;
  languageLabel?: string;
  queuePosition?: number;
  queueTotal?: number;
}

const Hero = memo(function Hero({
  title,
  author,
  coverUrl,
  summary,
  etaSeconds,
  phase,
  voiceLabel,
  engineLabel,
  languageLabel,
  queuePosition,
  queueTotal,
}: HeroProps): JSX.Element | null {
  const t = useTranslations();
  const { locale } = useI18n();
  const [isCollapsed, setIsCollapsed] = useState(false);
  const [coverFailed, setCoverFailed] = useState(false);
  const heroRef = useRef<HTMLElement | null>(null);
  const spacerRef = useRef<HTMLDivElement | null>(null);
  const expandedHeightRef = useRef(0);
  const baseSpacerHeightRef = useRef(0);
  const lastScrollYRef = useRef(0);
  const collapseLockRef = useRef(0);

  const progressValue = useMemo(() => {
    if (
      summary?.progressPercent !== undefined &&
      summary?.progressPercent !== null
    ) {
      return Math.min(100, Math.max(0, summary.progressPercent));
    }
    if (
      typeof summary?.chaptersCompleted === "number" &&
      typeof summary?.chaptersTotal === "number" &&
      summary.chaptersTotal > 0
    ) {
      const computed =
        (summary.chaptersCompleted / summary.chaptersTotal) * 100;
      return Math.min(100, Math.max(0, computed));
    }
    return null;
  }, [summary]);

  const hasMetadata = Boolean(
    (title && title.trim()) ||
    (author && author.trim()) ||
    (coverUrl && !coverFailed) ||
    progressValue !== null ||
    (summary?.currentChapter && summary.currentChapter.trim()),
  );
  const shouldShowStatusCard = hasMetadata || phase !== "idle";
  const collapseEnabled = true;
  const etaDisplay = formatEta(phase, etaSeconds, locale, t);

  useEffect(() => {
    setCoverFailed(false);
  }, [coverUrl]);
  const displayTitle = title?.trim() || t.status.bookFallbackTitle;
  const displayAuthor = author?.trim() || t.status.bookFallbackAuthor;
  const displayVoice = voiceLabel ?? "";
  const displayEngine = engineLabel ?? "";
  const displayLanguage = languageLabel ?? "";

  const chapterInfo = useMemo(() => {
    if (
      typeof summary?.chaptersCompleted === "number" &&
      typeof summary?.chaptersTotal === "number"
    ) {
      return `${summary.chaptersCompleted}/${summary.chaptersTotal}`;
    }
    if (typeof summary?.chaptersTotal === "number") {
      return `${summary.chaptersTotal}`;
    }
    return null;
  }, [summary]);

  useEffect(() => {
    if (!collapseEnabled) {
      return;
    }
    if (typeof window === "undefined") {
      return;
    }
    if (!shouldShowStatusCard) {
      setIsCollapsed(false);
      return;
    }
    const collapseThreshold = 180;
    const expandThreshold = 120;
    let ticking = false;

    const onScroll = () => {
      if (ticking) return;
      ticking = true;
      window.requestAnimationFrame(() => {
        const currentY = window.scrollY;
        const delta = currentY - lastScrollYRef.current;
        const now = Date.now();
        lastScrollYRef.current = currentY;
        if (now >= collapseLockRef.current) {
          setIsCollapsed((prev) => {
            if (!prev && currentY > collapseThreshold && delta > 0) {
              collapseLockRef.current = now + 250;
              return true;
            }
            if (prev && currentY < expandThreshold && delta < 0) {
              collapseLockRef.current = now + 250;
              return false;
            }
            return prev;
          });
        }
        ticking = false;
      });
    };
    lastScrollYRef.current = window.scrollY;
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, [collapseEnabled, shouldShowStatusCard]);

  useEffect(() => {
    if (typeof ResizeObserver === "undefined") {
      return;
    }
    if (!shouldShowStatusCard || isCollapsed) {
      return;
    }
    const hero = heroRef.current;
    const spacer = spacerRef.current;
    if (!hero || !spacer) {
      return;
    }
    const updateMeasurements = () => {
      expandedHeightRef.current = hero.getBoundingClientRect().height;
      baseSpacerHeightRef.current = spacer.getBoundingClientRect().height;
    };
    updateMeasurements();
    const observer = new ResizeObserver(updateMeasurements);
    observer.observe(hero);
    observer.observe(spacer);
    return () => observer.disconnect();
  }, [isCollapsed, shouldShowStatusCard]);

  useLayoutEffect(() => {
    if (!shouldShowStatusCard) {
      if (spacerRef.current) {
        spacerRef.current.style.height = "";
      }
      return;
    }
    const hero = heroRef.current;
    const spacer = spacerRef.current;
    if (!hero || !spacer) {
      return;
    }
    const heroHeight = hero.getBoundingClientRect().height;
    if (!isCollapsed) {
      expandedHeightRef.current = heroHeight;
      baseSpacerHeightRef.current = spacer.getBoundingClientRect().height;
      spacer.style.height = "";
      return;
    }
    const expandedHeight = expandedHeightRef.current || heroHeight;
    const baseSpacing =
      baseSpacerHeightRef.current || spacer.getBoundingClientRect().height;
    const targetHeight = Math.max(
      baseSpacing,
      expandedHeight - heroHeight + baseSpacing,
    );
    if (!Number.isFinite(targetHeight)) {
      return;
    }
    spacer.style.height = `${targetHeight}px`;
  }, [isCollapsed, shouldShowStatusCard]);

  const heroClasses = [
    "hero",
    shouldShowStatusCard ? "hero--active" : "",
    shouldShowStatusCard && isCollapsed ? "hero--collapsed" : "",
  ]
    .filter(Boolean)
    .join(" ");

  if (!shouldShowStatusCard) {
    return null;
  }

  return (
    <>
      <header
        className={heroClasses}
        ref={(node) => {
          heroRef.current = node;
        }}
      >
        {shouldShowStatusCard ? (
          <div className="hero__book">
            <div className="hero__book-cover">
              {coverUrl && !coverFailed ? (
                <img
                  src={coverUrl}
                  alt={displayTitle}
                  loading="lazy"
                  decoding="async"
                  onError={() => setCoverFailed(true)}
                />
              ) : (
                <span aria-hidden="true" role="img">
                  📘
                </span>
              )}
            </div>
            <div className="hero__book-body">
              <p className="badge badge--muted">
                {t.hero.badge}
                {queuePosition && queueTotal && queueTotal > 1 && (
                  <span style={{ marginLeft: "0.5rem", opacity: 0.8 }}>
                    · {queuePosition}/{queueTotal}
                  </span>
                )}
              </p>
              <h1>{displayTitle}</h1>
              <p className="hero__author">{displayAuthor}</p>
              {(summary?.currentChapter || chapterInfo) && (
                <p className="hero__chapter">
                  {summary?.currentChapter ?? ""}
                  {summary?.currentChapter && chapterInfo ? " · " : ""}
                  {chapterInfo ?? ""}
                </p>
              )}
              {(displayEngine || displayVoice || displayLanguage) && (
                <div className="hero__meta">
                  {displayEngine && (
                    <span>
                      {t.activeConversion.engineLabel}:{" "}
                      <strong>{displayEngine}</strong>
                    </span>
                  )}
                  {displayVoice && (
                    <span>
                      {t.activeConversion.voiceLabel}:{" "}
                      <strong>{displayVoice}</strong>
                    </span>
                  )}
                  {displayLanguage && (
                    <span>
                      {t.activeConversion.languageLabel}:{" "}
                      <strong>{displayLanguage}</strong>
                    </span>
                  )}
                </div>
              )}
              <div className="hero__progress">
                <div className="hero__progress-info">
                  <span>{t.status.progressLabel}</span>
                  <strong>
                    {progressValue !== null
                      ? `${progressValue.toFixed(1)}%`
                      : "—"}
                  </strong>
                </div>
                <div
                  className="hero__progress-bar"
                  role="progressbar"
                  aria-valuemin={0}
                  aria-valuemax={100}
                  aria-valuenow={progressValue ?? 0}
                >
                  <div
                    className="hero__progress-fill"
                    style={{ width: `${progressValue ?? 0}%` }}
                  />
                </div>
                <div className="hero__progress-info hero__progress-info--eta">
                  <span>{t.status.etaLabel}</span>
                  <strong>{etaDisplay}</strong>
                </div>
              </div>
            </div>
          </div>
        ) : null}
        {shouldShowStatusCard && (
          <div className="hero__collapsed-summary" aria-live="polite">
            <div className="hero__collapsed-cover">
              {coverUrl && !coverFailed ? (
                <img
                  src={coverUrl}
                  alt={displayTitle}
                  loading="lazy"
                  decoding="async"
                  onError={() => setCoverFailed(true)}
                />
              ) : (
                <span aria-hidden="true">📘</span>
              )}
            </div>
            <div className="hero__collapsed-body">
              <p className="hero__collapsed-title">{displayTitle}</p>
              <p className="hero__collapsed-progress">
                {progressValue !== null ? `${progressValue.toFixed(1)}%` : "—"}{" "}
                · {etaDisplay}
              </p>
              <div
                className="hero__collapsed-bar"
                role="progressbar"
                aria-valuemin={0}
                aria-valuemax={100}
                aria-valuenow={progressValue ?? 0}
              >
                <div
                  className="hero__collapsed-fill"
                  style={{ width: `${progressValue ?? 0}%` }}
                />
              </div>
            </div>
          </div>
        )}
      </header>
      {shouldShowStatusCard && (
        <div
          ref={spacerRef}
          className={[
            "hero__spacer",
            isCollapsed ? "hero__spacer--collapsed" : "",
          ]
            .filter(Boolean)
            .join(" ")}
          aria-hidden="true"
        />
      )}
    </>
  );
});

export default Hero;
