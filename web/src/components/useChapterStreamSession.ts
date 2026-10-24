import { browserNativeSpeech } from '../services/BrowserNativeSpeech';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { conversionClient } from '../services/ConversionService';
import { latencyObservations } from '../services/LatencyObservation';
import { useI18n } from '../i18n/I18nProvider';
import {
  ChapterProgressEntry,
  ChapterStreamManifest,
  PlaybackIndicator,
} from '../types/conversion';
import { POLL_INTERVAL_MS, PLAYBACK_RATES, SPEED_KEY, positionKey } from './playback_preferences';

export interface StreamingAudioPlayerProps {
  jobId?: string;
  chapters?: ChapterProgressEntry[] | null;
  bookTitle?: string;
  bookAuthor?: string;
  coverUrl?: string;
  onPlayingSegment?: (chapterIndex: number, segmentIndex: number) => void;
  onPlaybackStateChange?: (state: PlaybackIndicator | null) => void;
  startRequestId?: number;
  hideStartButton?: boolean;
  embedded?: boolean;
}

export function useChapterStreamSession({
  jobId,
  chapters,
  bookTitle,
  bookAuthor,
  coverUrl,
  onPlayingSegment,
  onPlaybackStateChange,
  startRequestId = 0,
  hideStartButton = false,
  embedded = false,
}: StreamingAudioPlayerProps) {
  const { locale } = useI18n();
  const [started, setStarted] = useState(false);
  const [currentChapter, setCurrentChapter] = useState<number>(0);
  const [currentSegment, setCurrentSegment] = useState(0);
  const [manifest, setManifest] = useState<ChapterStreamManifest | null>(null);
  const [waiting, setWaiting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [isPlaying, setIsPlaying] = useState(false);
  const audioRef = useRef<HTMLAudioElement>(null);
  const [src, setSrc] = useState<string | null>(null);
  const [currentSegmentText, setCurrentSegmentText] = useState<string>('');
  const pollTimeoutRef = useRef<number | null>(null);
  // One lease per playback context; retire pending fetches on stop or effect cleanup.
  const pollGenerationRef = useRef<number>(0);
  const playbackJourneyRef = useRef<string | null>(null);
  const seekJourneyRef = useRef<string | null>(null);
  const [playbackRate, setPlaybackRate] = useState<number>(() => {
    try {
      const saved = window.localStorage.getItem(SPEED_KEY);
      const parsed = saved !== null ? Number(saved) : NaN;
      return (PLAYBACK_RATES as ReadonlyArray<number>).includes(parsed) ? parsed : 1;
    } catch {
      return 1;
    }
  });

  // Get sorted chapters
  const sortedChapters = useMemo(() => {
    if (!chapters) return [];
    return [...chapters].sort((a, b) => a.index - b.index);
  }, [chapters]);

  const currentChapterEntry = useMemo(() => {
    return sortedChapters.find((ch) => ch.index === currentChapter);
  }, [sortedChapters, currentChapter]);

  const currentChapterLabel = useMemo(() => {
    if (!currentChapterEntry) return '';
    return `${currentChapterEntry.index}. ${currentChapterEntry.name}`;
  }, [currentChapterEntry]);

  // Update MediaSession API
  useEffect(() => {
    if (!('mediaSession' in navigator)) return;
    const title = bookTitle || 'Audiobook';
    const artist = bookAuthor || 'Converter';
    const album = currentChapterLabel || title;
    try {
      navigator.mediaSession.metadata = new MediaMetadata({
        title,
        artist,
        album,
        artwork: coverUrl
          ? [
              {
                src: coverUrl,
                sizes: '512x512',
                type: 'image/png',
              },
            ]
          : [],
      });
    } catch {
      // Best effort only
    }
  }, [bookTitle, bookAuthor, coverUrl, currentChapterLabel]);

  // Persist playback rate globally.
  useEffect(() => {
    try {
      window.localStorage.setItem(SPEED_KEY, String(playbackRate));
    } catch {
      // Persistence is optional.
    }
  }, [playbackRate]);

  // Apply playback rate to the audio element whenever it changes or a new src loads.
  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return;
    audio.playbackRate = playbackRate;
  }, [playbackRate, src]);

  // Persist current position (chapter + segment) per job so it can be restored.
  useEffect(() => {
    if (!started || !jobId) return;
    try {
      window.localStorage.setItem(
        positionKey(jobId),
        JSON.stringify({
          chapterIndex: currentChapter,
          segmentIndex: currentSegment,
        }),
      );
    } catch {
      // Persistence is optional.
    }
  }, [started, jobId, currentChapter, currentSegment]);

  // Notify parent about current playing segment
  useEffect(() => {
    if (isPlaying && onPlayingSegment) {
      onPlayingSegment(currentChapter, currentSegment);
    }
  }, [isPlaying, currentChapter, currentSegment, onPlayingSegment]);

  useEffect(() => {
    if (!onPlaybackStateChange) {
      return;
    }
    if (!started) {
      onPlaybackStateChange(null);
      return;
    }
    onPlaybackStateChange({
      chapterIndex: currentChapter,
      segmentIndex: currentSegment,
      segmentText: currentSegmentText,
      isPlaying,
      started,
      waiting,
    });
  }, [
    currentChapter,
    currentSegment,
    currentSegmentText,
    isPlaying,
    onPlaybackStateChange,
    started,
    waiting,
  ]);

  // Poll for next chunk
  const pollForChunk = useCallback(async () => {
    if (!jobId || !started) return;
    const generation = pollGenerationRef.current;

    try {
      const manifest = await conversionClient.getChapterManifest?.(jobId, currentChapter);

      // Only the active job/chapter/segment effect may publish or retry.
      if (pollGenerationRef.current !== generation) return;

      if (!manifest) {
        setWaiting(true);
        pollTimeoutRef.current = window.setTimeout(pollForChunk, POLL_INTERVAL_MS);
        return;
      }

      const sortedChunks = (manifest.chunks || []).slice().sort((a, b) => a.index - b.index);
      const normalizedManifest = { ...manifest, chunks: sortedChunks };
      setManifest(normalizedManifest);

      if (manifest.legacyWholeChapter && currentSegment > 0) {
        // A legacy merged file cannot identify a saved segment. Retain progress
        // until the listener explicitly selects a chapter to restart it.
        setWaiting(false);
        setError('Saved audio has no segment map. Select a chapter to restart playback.');
        return;
      }

      // Exact match only — do not skip ahead to a later segment if the current
      // one has not been generated yet.  If missing, fall through to re-poll.
      const nextChunk = sortedChunks.find((chunk) => chunk.index === currentSegment);

      if (nextChunk && nextChunk.url) {
        if (playbackJourneyRef.current) {
          latencyObservations.record(playbackJourneyRef.current, 'audio_queued');
        }
        setSrc(nextChunk.url);
        setCurrentSegmentText(nextChunk.text || '');
        setCurrentSegment(nextChunk.index);
        setWaiting(false);
      } else {
        setWaiting(true);
        pollTimeoutRef.current = window.setTimeout(pollForChunk, POLL_INTERVAL_MS);
      }
    } catch (fetchErr) {
      if (pollGenerationRef.current !== generation) return;
      console.warn('[StreamingAudio] manifest fetch failed', fetchErr);
      setWaiting(true);
      pollTimeoutRef.current = window.setTimeout(pollForChunk, POLL_INTERVAL_MS);
    }
  }, [jobId, started, currentChapter, currentSegment]);

  useEffect(() => {
    pollGenerationRef.current += 1;
    if (pollTimeoutRef.current) {
      window.clearTimeout(pollTimeoutRef.current);
    }
    if (started && jobId) {
      pollForChunk();
    }
    return () => {
      pollGenerationRef.current += 1;
      if (pollTimeoutRef.current) {
        window.clearTimeout(pollTimeoutRef.current);
      }
    };
  }, [jobId, started, currentChapter, currentSegment, pollForChunk]);

  // Auto-play when src changes
  useEffect(() => {
    if (!started || !src) return;
    const audio = audioRef.current;
    if (!audio) return;

    browserNativeSpeech()?.cancel();
    audio.src = src;
    audio.play().catch((err) => {
      console.error('[StreamingPlayer] Playback failed:', err);
      setError(err?.message || 'Playback failed');
    });
  }, [src, started]);

  useEffect(() => {
    if (!startRequestId || started) {
      return;
    }
    handleStart();
  }, [startRequestId, started]);

  const handleStart = () => {
    setError(null);
    setWaiting(true);
    setStarted(true);
    playbackJourneyRef.current = latencyObservations.begin(
      'progressive_playback',
      'play_requested',
    );

    let startChapter = sortedChapters[0]?.index ?? 0;
    let startSegment = 0;
    if (jobId) {
      try {
        const saved = window.localStorage.getItem(positionKey(jobId));
        if (saved) {
          const pos = JSON.parse(saved) as {
            chapterIndex: number;
            segmentIndex: number;
          };
          if (
            typeof pos.chapterIndex === 'number' &&
            Number.isSafeInteger(pos.segmentIndex) &&
            pos.segmentIndex >= 0 &&
            sortedChapters.some((ch) => ch.index === pos.chapterIndex)
          ) {
            startChapter = pos.chapterIndex;
            startSegment = pos.segmentIndex;
          }
        }
      } catch {
        // Ignore invalid saved position.
      }
    }
    setCurrentChapter(startChapter);
    setCurrentSegment(startSegment);
  };

  const handleChapterJump = (chapterIndex: number) => {
    setError(null);
    seekJourneyRef.current = latencyObservations.begin('seek', 'seek_requested');
    const audio = audioRef.current;
    if (audio) {
      audio.pause();
      audio.src = '';
    }
    setCurrentChapter(chapterIndex);
    setCurrentSegment(0);
    setManifest(null);
    setSrc(null);
    setCurrentSegmentText('');
  };

  const handleStop = () => {
    if (playbackJourneyRef.current) latencyObservations.cancel(playbackJourneyRef.current);
    if (seekJourneyRef.current) latencyObservations.cancel(seekJourneyRef.current);
    playbackJourneyRef.current = null;
    seekJourneyRef.current = null;
    pollGenerationRef.current += 1;
    if (pollTimeoutRef.current) {
      window.clearTimeout(pollTimeoutRef.current);
      pollTimeoutRef.current = null;
    }
    const audio = audioRef.current;
    if (audio) {
      audio.pause();
      audio.src = '';
    }
    setSrc(null);
    setManifest(null);
    setCurrentSegmentText('');
    setWaiting(false);
    setIsPlaying(false);
    setError(null);
    setStarted(false);
  };

  const handlePause = () => {
    setIsPlaying(false);
  };

  const handlePlay = () => {
    setIsPlaying(true);
  };

  const handleCanPlay = () => {
    if (playbackJourneyRef.current) {
      latencyObservations.record(playbackJourneyRef.current, 'audio_playable');
    }
  };

  useEffect(() => {
    if (started && jobId)
      void conversionClient
        .listenFrom?.(jobId, currentChapter)
        .catch((error: unknown) => setError(String(error)));
  }, [started, jobId, currentChapter]);

  const handleTimeUpdate = () => {
    const audio = audioRef.current;
    if (!audio || audio.currentTime <= 0) return;
    if (jobId && currentChapterEntry?.status === 'completed' && manifest?.chunks) {
      const durations = manifest.chunks
        .slice(currentSegment + 1)
        .map((chunk) => chunk.durationSeconds);
      if (
        Number.isFinite(audio.duration) &&
        durations.every((duration) => duration !== undefined && Number.isFinite(duration))
      ) {
        const remaining =
          Math.max(0, audio.duration - audio.currentTime) +
          durations.reduce<number>((sum, duration) => sum + (duration ?? 0), 0);
        void conversionClient
          .playbackFeedback?.(jobId, currentChapter, remaining, playbackRate)
          .catch((error: unknown) => setError(String(error)));
      }
    }
    if (playbackJourneyRef.current) {
      latencyObservations.record(playbackJourneyRef.current, 'audio_audible');
      latencyObservations.finish(playbackJourneyRef.current);
      playbackJourneyRef.current = null;
    }
    if (seekJourneyRef.current) {
      latencyObservations.record(seekJourneyRef.current, 'seek_target_reached');
      latencyObservations.finish(seekJourneyRef.current);
      seekJourneyRef.current = null;
    }
  };

  const handleEnded = () => {
    const nextSegmentIndex = currentSegment + 1;

    // If the chapter is still being processed, advance to next segment index and
    // let pollForChunk wait for it — never skip over gaps in segment indices.
    const chapterDone =
      currentChapterEntry &&
      (currentChapterEntry.status === 'completed' ||
        currentChapterEntry.status === 'failed' ||
        currentChapterEntry.status === 'skipped' ||
        currentChapterEntry.status === 'cancelled');

    if (!chapterDone) {
      // Chapter still in progress — move to next index and poll for it
      setCurrentSegment(nextSegmentIndex);
      return;
    }

    // Chapter is done: only advance segment if it already exists in the manifest
    if (manifest && manifest.chunks) {
      const nextSegment = manifest.chunks.find((chunk) => chunk.index === nextSegmentIndex);
      if (nextSegment) {
        setCurrentSegment(nextSegmentIndex);
        return;
      }
    }

    // No more segments in current chapter, try next chapter
    const currentChapterIdx = sortedChapters.findIndex((ch) => ch.index === currentChapter);
    if (currentChapterIdx >= 0 && currentChapterIdx < sortedChapters.length - 1) {
      const nextChapter = sortedChapters[currentChapterIdx + 1];
      setCurrentChapter(nextChapter.index);
      setCurrentSegment(0);
      setManifest(null);
      setSrc(null);
      setCurrentSegmentText('');
    } else {
      // Reached the end of the book
      if (jobId) {
        try {
          window.localStorage.removeItem(positionKey(jobId));
        } catch {
          // Persistence is optional.
        }
      }
      setStarted(false);
      setIsPlaying(false);
      setWaiting(false);
    }
  };

  const handleNextChapter = () => {
    const currentIdx = sortedChapters.findIndex((ch) => ch.index === currentChapter);
    if (currentIdx >= 0 && currentIdx < sortedChapters.length - 1) {
      const nextChapter = sortedChapters[currentIdx + 1];
      setCurrentChapter(nextChapter.index);
      setCurrentSegment(0);
      setManifest(null);
      setSrc(null);
      setCurrentSegmentText('');
    }
  };

  const handlePrevChapter = () => {
    const currentIdx = sortedChapters.findIndex((ch) => ch.index === currentChapter);
    if (currentIdx > 0) {
      const prevChapter = sortedChapters[currentIdx - 1];
      setCurrentChapter(prevChapter.index);
      setCurrentSegment(0);
      setManifest(null);
      setSrc(null);
      setCurrentSegmentText('');
    }
  };

  return {
    jobId,
    chapters,
    manifest,
    currentSegment,
    waiting,
    locale,
    embedded,
    isPlaying,
    currentChapterLabel,
    started,
    hideStartButton,
    handleStart,
    sortedChapters,
    handlePrevChapter,
    currentChapter,
    handleNextChapter,
    playbackRate,
    setPlaybackRate,
    handleChapterJump,
    handleStop,
    audioRef,
    handleEnded,
    handlePlay,
    handlePause,
    handleCanPlay,
    handleTimeUpdate,
    src,
    error,
    currentSegmentText,
  };
}

export type StreamingAudioPlayerScope = ReturnType<typeof useChapterStreamSession>;
