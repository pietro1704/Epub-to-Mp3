import { useCallback, useEffect, useState } from "react";
import { resolveApiUrl } from "../config";
import { useI18n } from "../i18n/I18nProvider";

const PAGE_SIZE = 10;

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
  const known = ["edge", "kokoro", "piper"];
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
  const [page, setPage] = useState(0);
  const [clearing, setClearing] = useState(false);

  const pt = locale === "pt";
  const label = pt ? "Histórico de conversões" : "Conversion history";
  const showMoreLabel = pt ? "Próxima página" : "Next page";
  const showLessLabel = pt ? "Página anterior" : "Previous page";
  const totalLabel = pt ? "conversões" : "conversions";
  const chaptersLabel = pt ? "capítulos" : "chapters";
  const clearLabel = pt ? "Limpar histórico" : "Clear history";
  const clearConfirm = pt
    ? "Apagar todo o histórico de conversões?"
    : "Delete all conversion history?";

  const loadSessions = useCallback(() => {
    let cancelled = false;
    setLoading(true);
    fetch(resolveApiUrl("/api/sessions?last=500"))
      .then((r) => (r.ok ? r.json() : null))
      .then(
        (data: { sessions?: SessionRecord[]; stats?: SessionStats } | null) => {
          if (cancelled || !data) return;
          setSessions((data.sessions ?? []).slice().reverse()); // newest first
          setStats(data.stats ?? null);
          setPage(0);
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

  useEffect(() => {
    return loadSessions();
  }, [loadSessions]);

  const handleClear = useCallback(async () => {
    if (!window.confirm(clearConfirm)) return;
    setClearing(true);
    try {
      await fetch(resolveApiUrl("/api/sessions"), { method: "DELETE" });
      setSessions([]);
      setStats(null);
      setPage(0);
    } catch {
      /* best effort */
    } finally {
      setClearing(false);
    }
  }, [clearConfirm]);

  if (loading || sessions.length === 0) return null;

  const totalPages = Math.ceil(sessions.length / PAGE_SIZE);
  const visible = sessions.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);

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
        <>
          <ul className="history-panel__list">
            {visible.map((s, i) => (
              <li
                key={page * PAGE_SIZE + i}
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
          </ul>
          <div className="history-panel__footer">
            {totalPages > 1 && (
              <div className="history-panel__pagination">
                <button
                  type="button"
                  className="history-panel__page-btn"
                  onClick={() => setPage((p) => Math.max(0, p - 1))}
                  disabled={page === 0}
                  aria-label={showLessLabel}
                >
                  ‹
                </button>
                <span className="history-panel__page-info">
                  {page + 1} / {totalPages}
                </span>
                <button
                  type="button"
                  className="history-panel__page-btn"
                  onClick={() =>
                    setPage((p) => Math.min(totalPages - 1, p + 1))
                  }
                  disabled={page >= totalPages - 1}
                  aria-label={showMoreLabel}
                >
                  ›
                </button>
              </div>
            )}
            <button
              type="button"
              className="history-panel__clear-btn"
              onClick={handleClear}
              disabled={clearing}
            >
              {clearing ? "…" : clearLabel}
            </button>
          </div>
        </>
      )}
    </div>
  );
}
