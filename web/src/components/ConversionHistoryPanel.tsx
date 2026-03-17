import { useEffect, useState } from "react";
import { resolveApiUrl } from "../config";
import { useI18n } from "../i18n/I18nProvider";

interface SessionRecord {
  timestamp?: string;
  book_title?: string;
  book_author?: string;
  engine?: string;
  mode?: string;
  duration_seconds?: number;
  chapters_converted?: number;
  chapters_total?: number;
  outcome?: string;
  language?: string;
}

interface SessionStats {
  outcomes: Record<string, number>;
  engines: Record<string, number>;
  modes: Record<string, number>;
  total_duration_seconds: number;
  total_chapters_converted: number;
}

function engineClass(engine: string): string {
  const key = (engine || "").toLowerCase().split(/[-_]/)[0];
  const known = ["edge", "kokoro", "piper", "coqui", "spark"];
  return known.includes(key)
    ? `engine-badge engine-badge--${key}`
    : "engine-badge";
}

function formatDuration(seconds: number): string {
  if (seconds < 60) return `${Math.round(seconds)}s`;
  const m = Math.floor(seconds / 60);
  const s = Math.round(seconds % 60);
  if (m < 60) return s > 0 ? `${m}m ${s}s` : `${m}m`;
  const h = Math.floor(m / 60);
  const rm = m % 60;
  return rm > 0 ? `${h}h ${rm}m` : `${h}h`;
}

function formatDate(iso: string, locale: string): string {
  try {
    return new Date(iso).toLocaleDateString(
      locale === "pt" ? "pt-BR" : "en-US",
      {
        day: "2-digit",
        month: "short",
        year: "numeric",
      },
    );
  } catch {
    return iso.slice(0, 10);
  }
}

export default function ConversionHistoryPanel(): JSX.Element | null {
  const { locale } = useI18n();
  const [sessions, setSessions] = useState<SessionRecord[]>([]);
  const [stats, setStats] = useState<SessionStats | null>(null);
  const [loading, setLoading] = useState(true);
  const [collapsed, setCollapsed] = useState(true);
  const [showAll, setShowAll] = useState(false);

  const label =
    locale === "pt" ? "Histórico de conversões" : "Conversion history";
  const noHistory =
    locale === "pt"
      ? "Nenhuma conversão registrada ainda."
      : "No conversions recorded yet.";
  const showMoreLabel = locale === "pt" ? "Ver mais" : "Show more";
  const showLessLabel = locale === "pt" ? "Ver menos" : "Show less";
  const totalLabel = locale === "pt" ? "conversões" : "conversions";
  const chaptersLabel = locale === "pt" ? "capítulos" : "chapters";

  useEffect(() => {
    let cancelled = false;
    fetch(resolveApiUrl("/api/sessions?last=50"))
      .then((r) => (r.ok ? r.json() : null))
      .then(
        (data: { sessions?: SessionRecord[]; stats?: SessionStats } | null) => {
          if (cancelled || !data) return;
          setSessions((data.sessions ?? []).slice().reverse()); // newest first
          setStats(data.stats ?? null);
        },
      )
      .catch(() => {
        /* best effort */
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (loading || sessions.length === 0) return null;

  const PREVIEW = 5;
  const visible = showAll ? sessions : sessions.slice(0, PREVIEW);

  return (
    <div className="history-panel">
      <button
        type="button"
        className="history-panel__header"
        onClick={() => setCollapsed((c) => !c)}
        aria-expanded={!collapsed}
      >
        <span className="history-panel__title">📋 {label}</span>
        {stats && (
          <span className="history-panel__summary">
            {stats.outcomes.success ?? 0} {totalLabel} •{" "}
            {stats.total_chapters_converted} {chaptersLabel} •{" "}
            {formatDuration(stats.total_duration_seconds)}
          </span>
        )}
        <span className="history-panel__chevron">{collapsed ? "▸" : "▾"}</span>
      </button>

      {!collapsed && (
        <ul className="history-panel__list">
          {visible.map((s, i) => (
            <li
              key={i}
              className={`history-panel__item history-panel__item--${s.outcome ?? "unknown"}`}
            >
              <span className="history-panel__outcome">
                {s.outcome === "success"
                  ? "✅"
                  : s.outcome === "failed"
                    ? "❌"
                    : "⚠️"}
              </span>
              <span className="history-panel__info">
                <span className="history-panel__title-text">
                  {s.book_title ?? "—"}
                </span>
                {s.book_author && (
                  <span className="history-panel__author">
                    {" "}
                    — {s.book_author}
                  </span>
                )}
                <span className="history-panel__meta">
                  {s.engine && (
                    <span className={engineClass(s.engine)}>{s.engine}</span>
                  )}
                  {s.mode && (
                    <span className="history-panel__mode">{s.mode}</span>
                  )}
                  {typeof s.chapters_converted === "number" && (
                    <span>
                      {s.chapters_converted}/{s.chapters_total ?? "?"} ch
                    </span>
                  )}
                  {typeof s.duration_seconds === "number" && (
                    <span>{formatDuration(s.duration_seconds)}</span>
                  )}
                  {s.timestamp && (
                    <span>{formatDate(s.timestamp, locale)}</span>
                  )}
                </span>
              </span>
            </li>
          ))}
          {sessions.length > PREVIEW && (
            <li className="history-panel__more">
              <button
                type="button"
                className="history-panel__more-btn"
                onClick={() => setShowAll((v) => !v)}
              >
                {showAll
                  ? showLessLabel
                  : `${showMoreLabel} (${sessions.length - PREVIEW})`}
              </button>
            </li>
          )}
        </ul>
      )}
    </div>
  );
}
