import { useCallback, useEffect, useRef, useState } from 'react';
import { ChapterProgressEntry, ChapterStreamManifest } from '../types/conversion';
import { useChapterManifestStore } from './useChapterManifestStore';
import { useI18n, useTranslations } from '../i18n/I18nProvider';
import { safeScrollIntoView } from '../utils/safeScrollIntoView';
import { STREAM_REFRESH_MS } from './ChapterProgressPresentation';

export interface ChapterProgressListProps {
  entries: ChapterProgressEntry[];
  jobId?: string;
  playingSegment?: { chapterIndex: number; segmentIndex: number } | null;
}

export function useChapterProgress({ entries, jobId, playingSegment }: ChapterProgressListProps) {
  const t = useTranslations();
  const { locale } = useI18n();
  const containerRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLUListElement>(null);
  const headerRef = useRef<HTMLDivElement>(null);
  const hasEntries = entries.length > 0;
  const [expanded, setExpanded] = useState<Record<number, boolean>>({});
  const [expandAllChapters, setExpandAllChapters] = useState(false);
  const [expandAllTexts, setExpandAllTexts] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [searchHits, setSearchHits] = useState(0);
  const [activeMatchIndex, setActiveMatchIndex] = useState(0);
  const { manifests, manifestLoading, manifestErrors, fetchManifest, fetchAllManifests } =
    useChapterManifestStore(jobId);
  const matchCounterRef = useRef(0);
  // Track which segment texts are expanded (key: "chapterIndex-segmentIndex")
  const [expandedTexts, setExpandedTexts] = useState<Record<string, boolean>>({});

  const toggleSegmentText = (chapterIndex: number, segmentIndex: number) => {
    const key = `${chapterIndex}-${segmentIndex}`;
    setExpandedTexts((prev) => ({ ...prev, [key]: !prev[key] }));
  };

  const completedCount = entries.filter((entry) => entry.status === 'completed').length;

  const scrollToCurrent = useCallback(
    (behavior: ScrollBehavior = 'smooth') => {
      const container = containerRef.current;
      const list = listRef.current;
      if (!container || !list) return;

      // Find first processing/retrying item, or last completed item
      const processingIndex = entries.findIndex(
        (entry) => entry.status === 'processing' || entry.status === 'retrying',
      );
      const targetIndex =
        processingIndex >= 0
          ? processingIndex
          : entries.findIndex((entry) => entry.status === 'completed');

      if (targetIndex >= 0) {
        const items = list.children;
        const target = items[targetIndex] as HTMLElement | undefined;
        if (target) {
          const containerRect = container.getBoundingClientRect();
          const targetRect = target.getBoundingClientRect();
          const headerHeight = headerRef.current?.offsetHeight ?? 0;
          const relativeTop =
            targetRect.top - containerRect.top + container.scrollTop - headerHeight;
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
      const allAudios = container.querySelectorAll('audio');
      allAudios.forEach((audio) => {
        if (audio !== playingAudio && !audio.paused) {
          audio.pause();
        }
      });
    };

    // Add event listener to container (event delegation)
    container.addEventListener('play', handlePlay, true);

    return () => {
      container.removeEventListener('play', handlePlay, true);
    };
  }, []);

  const toggleChapter = (chapterIndex: number) => {
    setExpanded((prev) => {
      const next = { ...prev, [chapterIndex]: !prev[chapterIndex] };
      return next;
    });
  };

  const handleSearchChange = (value: string) => {
    setSearchQuery(value);
  };

  const highlightMatches = useCallback(
    (text: string, query: string) => {
      if (!query.trim()) return text;
      try {
        const safe = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const regex = new RegExp(safe, 'gi');
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
                  isActive ? ' chapter-progress__highlight--active' : ''
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

  const buildFullText = useCallback(
    (availableManifests: Record<number, ChapterStreamManifest | null>) => {
      const chapters = [...entries].sort((a, b) => a.index - b.index);
      const lines: string[] = [];
      chapters.forEach((entry) => {
        lines.push(`${entry.index}. ${entry.name}`);
        lines.push('');
        const manifest = availableManifests[entry.index];
        const chunks = (manifest?.chunks || []).slice().sort((a, b) => a.index - b.index);
        const chunkText = chunks
          .map((chunk) => chunk.text)
          .filter((text): text is string => Boolean(text && text.trim()));
        if (chunkText.length > 0) {
          lines.push(chunkText.join('\n'));
        } else {
          lines.push(locale === 'pt' ? '[texto indisponível]' : '[text unavailable]');
        }
        lines.push('\n');
      });
      return lines.join('\n').trim();
    },
    [entries, locale],
  );

  const handleDownloadText = useCallback(async () => {
    if (!jobId) return;
    setExpandAllChapters(true);
    const resolved = await fetchAllManifests(entries.map((entry) => entry.index));
    if (!resolved) return;
    const fullText = buildFullText(resolved);
    if (!fullText) return;
    const blob = new Blob([fullText], { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
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
    containerRef.current?.scrollTo({ top: 0, behavior: 'smooth' });
  }, []);

  const scrollToMatch = useCallback(
    (index: number) => {
      const container = containerRef.current;
      if (!container) return;
      const marks = container.querySelectorAll('.chapter-progress__highlight');
      if (marks.length === 0) return;
      const normalized = ((index % marks.length) + marks.length) % marks.length;
      const target = marks[normalized] as HTMLElement;
      safeScrollIntoView(target, { behavior: 'smooth', block: 'center' });
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
      setSearchQuery('');
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
      const allExpanded = entries.reduce<Record<number, boolean>>((acc, entry) => {
        acc[entry.index] = true;
        return acc;
      }, {});
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
      const allExpanded = entries.reduce<Record<number, boolean>>((acc, entry) => {
        acc[entry.index] = true;
        return acc;
      }, {});
      setExpanded(allExpanded);
      void fetchAllManifests(entries.map((entry) => entry.index));
    }
  }, [entries, expandAllTexts, fetchAllManifests]);

  // Auto-expand processing chapters so segments are visible immediately
  useEffect(() => {
    if (!jobId) return;
    const processingIndices = entries
      .filter((entry) => entry.status === 'processing' || entry.status === 'retrying')
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
          behavior: 'smooth',
          block: 'center',
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
    if (typeof value !== 'number' || !Number.isFinite(value)) return null;
    const minutes = Math.floor(value / 60);
    const seconds = Math.round(value % 60);
    return `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
  }, []);

  return {
    hasEntries,
    matchCounterRef,
    containerRef,
    headerRef,
    t,
    scrollToCurrent,
    handleToggleAllChapters,
    jobId,
    expandAllChapters,
    handleToggleAllTexts,
    expandAllTexts,
    handleScrollTop,
    handleDownloadText,
    searchQuery,
    handleSearchChange,
    searchHits,
    handlePrevMatch,
    handleNextMatch,
    completedCount,
    entries,
    listRef,
    expanded,
    manifests,
    manifestLoading,
    manifestErrors,
    toggleChapter,
    fetchManifest,
    locale,
    segmentCountLabel,
    expandedTexts,
    playingSegment,
    segmentDurationLabel,
    toggleSegmentText,
    highlightMatches,
  };
}

export type ChapterProgressListScope = ReturnType<typeof useChapterProgress>;
