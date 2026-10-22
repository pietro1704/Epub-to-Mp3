import { useDeferredValue, useEffect, useMemo, useRef, useState } from 'react';
import { conversionClient } from '../services/ConversionService';
import { latencyObservations } from '../services/LatencyObservation';
import { reportUiIssue } from '../services/uiIssueMonitor';
import { safeScrollIntoView } from '../utils/safeScrollIntoView';
import { sanitizeReaderCss, sanitizeReaderHtml } from '../utils/readerSanitizer';
import { BookTextDocument, ChapterProgressEntry, PlaybackIndicator } from '../types/conversion';
import { useI18n, useTranslations } from '../i18n/I18nProvider';
import {
  ReaderPrefs,
  PREFS_KEY,
  DEFAULT_PREFS,
  READER_CONTENT_BASE_CSS,
} from './reader_preferences';
import { buildReaderPages } from './reader_pagination';
import { countMatches } from './reader_highlighting';

export interface EbookReaderPanelProps {
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

export function useReaderPosition({
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
}: EbookReaderPanelProps) {
  const t = useTranslations();
  const { locale } = useI18n();
  const [document, setDocument] = useState<BookTextDocument | null>(null);
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [reloadToken, setReloadToken] = useState(0);
  const [selectedChapterIndex, setSelectedChapterIndex] = useState<number>(0);
  const [pageIndex, setPageIndex] = useState(0);
  const [search, setSearch] = useState('');
  const [prefs, setPrefs] = useState<ReaderPrefs>(DEFAULT_PREFS);
  // In-memory override: user clicked a chapter manually, temporarily pause followAudio
  // without persisting the change. Clears automatically when audio advances to a new chapter.
  const [followPaused, setFollowPaused] = useState(false);
  const articleHostRef = useRef<HTMLDivElement | null>(null);
  const articleShellRef = useRef<HTMLDivElement | null>(null);
  const readerJourneyRef = useRef<string | null>(null);
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
    let retryTimer: ReturnType<typeof setTimeout> | null = null;

    // Backoff schedule for transient pending/network errors. The reader is
    // commonly opened immediately after upload, before the server has had a
    // chance to parse the EPUB — retry quickly first, then back off.
    const RETRY_DELAYS_MS = [800, 1500, 3000, 6000, 12000];

    async function fetchOnce() {
      if (conversionClient.getJobFullTextResult) {
        return conversionClient.getJobFullTextResult(jobId!);
      }
      // Backwards-compatible fallback for client implementations (and unit
      // tests) that still mock the legacy `getJobFullText` API.
      if (conversionClient.getJobFullText) {
        const document = await conversionClient.getJobFullText(jobId!);
        if (document && document.chapters.length > 0) {
          return { kind: 'ok', document } as const;
        }
        return { kind: 'missing', status: 404 } as const;
      }
      return { kind: 'missing', status: 404 } as const;
    }

    async function loadDocument(attempt = 0) {
      if (!jobId) {
        if (readerJourneyRef.current) latencyObservations.cancel(readerJourneyRef.current);
        readerJourneyRef.current = null;
        setDocument(null);
        return;
      }
      if (!conversionClient.getJobFullText && !conversionClient.getJobFullTextResult) {
        setDocument(null);
        return;
      }
      if (attempt === 0) {
        if (readerJourneyRef.current) latencyObservations.cancel(readerJourneyRef.current);
        readerJourneyRef.current = latencyObservations.begin('reader_open', 'open_requested');
        setLoading(true);
        setLoadError(null);
      }
      const result = await fetchOnce();
      if (cancelled) {
        return;
      }
      if (result.kind === 'ok') {
        setDocument(result.document);
        setSelectedChapterIndex((current) => {
          if (result.document.chapters.some((chapter) => chapter.index === current)) {
            return current;
          }
          return result.document.chapters[0]?.index ?? 0;
        });
        setLoading(false);
        setLoadError(null);
        if (readerJourneyRef.current) {
          latencyObservations.record(readerJourneyRef.current, 'readable_content');
          latencyObservations.record(readerJourneyRef.current, 'controls_usable');
          latencyObservations.finish(readerJourneyRef.current);
          readerJourneyRef.current = null;
        }
        return;
      }
      const isTransient = result.kind === 'pending' || result.kind === 'network-error';
      if (isTransient && attempt < RETRY_DELAYS_MS.length) {
        // Show "still loading" while we wait — never the permanent error.
        setLoadError(null);
        setLoading(true);
        const delay = RETRY_DELAYS_MS[attempt];
        retryTimer = setTimeout(() => {
          if (!cancelled) {
            void loadDocument(attempt + 1);
          }
        }, delay);
        return;
      }
      // Permanent failure or transient retries exhausted.
      setDocument(null);
      const message =
        result.kind === 'pending'
          ? t.status.readerStillExtracting
          : result.kind === 'unprocessable'
            ? t.status.readerExtractionFailed
            : t.status.readerUnavailable;
      setLoadError(message);
      reportUiIssue('reader', message, {
        severity: 'warning',
        details: `job=${jobId} kind=${result.kind}`,
      });
      setLoading(false);
    }

    void loadDocument(0);

    return () => {
      cancelled = true;
      if (readerJourneyRef.current) latencyObservations.cancel(readerJourneyRef.current);
      readerJourneyRef.current = null;
      if (retryTimer !== null) {
        clearTimeout(retryTimer);
      }
    };
  }, [
    jobId,
    reloadToken,
    t.status.readerUnavailable,
    t.status.readerStillExtracting,
    t.status.readerExtractionFailed,
  ]);

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
    const marker = articleHostRef.current?.shadowRoot?.querySelector("[data-reader-audio='true']");
    if (!marker) {
      return;
    }
    safeScrollIntoView(marker, { block: 'center', behavior: 'smooth' });
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
      ? (chapters.find((chapter) => chapter.index === audioChapterIndex) ?? null)
      : null;
  const currentSegmentText =
    selectedChapter && playback?.chapterIndex === selectedChapter.index
      ? playback.segmentText || ''
      : '';
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
  const renderedCss = useMemo(() => selectedChapter?.css || '', [selectedChapter]);

  useEffect(() => {
    setPageIndex(0);
  }, [selectedChapterIndex]);

  // Keyboard shortcuts: ← / → to flip pages (only when no text input is focused).
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
      const target = event.target as HTMLElement;
      if (
        target.tagName === 'INPUT' ||
        target.tagName === 'TEXTAREA' ||
        target.tagName === 'SELECT'
      ) {
        return;
      }
      event.preventDefault();
      if (event.key === 'ArrowLeft') {
        setPageIndex((current) => Math.max(0, current - 1));
      } else {
        setPageIndex((current) => Math.min(readerPages.length - 1, current + 1));
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [readerPages.length]);

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
    const shadow = host.shadowRoot ?? host.attachShadow({ mode: 'open' });
    shadow.innerHTML = `
      <style>${READER_CONTENT_BASE_CSS}\n${sanitizeReaderCss(renderedCss)}</style>
      <div class="reader-root">${sanitizeReaderHtml(currentPage?.html || '<p></p>')}</div>
    `;
    // Scroll the article shell into view at the top whenever page content changes.
    safeScrollIntoView(articleShellRef.current, {
      behavior: 'instant',
      block: 'start',
    });
  }, [currentPage?.html, renderedCss]);

  const resolvedTitle = document?.bookTitle || bookTitle || t.status.bookFallbackTitle;
  const resolvedAuthor = document?.bookAuthor || bookAuthor || t.status.bookFallbackAuthor;
  const playbackStarted = Boolean(playback?.started);

  return {
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
  };
}

export type EbookReaderPanelScope = ReturnType<typeof useReaderPosition>;
