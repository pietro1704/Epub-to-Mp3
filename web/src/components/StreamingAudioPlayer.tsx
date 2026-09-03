import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { conversionClient } from "../services/ConversionService";
import { latencyObservations } from "../services/LatencyObservation";
import { useI18n } from "../i18n/I18nProvider";
import {
  AudioChunkEntry,
  ChapterProgressEntry,
  ChapterStreamManifest,
  PlaybackIndicator,
} from "../types/conversion";

interface StreamingAudioPlayerProps {
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

const POLL_INTERVAL_MS = 1500;
const PLAYBACK_RATES = [0.75, 1, 1.25, 1.5, 2] as const;
const SPEED_KEY = "epub-to-mp3:player-speed";
const positionKey = (id: string) => `epub-to-mp3:player-pos:${id}`;

export default function StreamingAudioPlayer({
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
}: StreamingAudioPlayerProps): JSX.Element | null {
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
  const [currentSegmentText, setCurrentSegmentText] = useState<string>("");
  const pollTimeoutRef = useRef<number | null>(null);
  // Incremented on stop to cancel in-flight pollForChunk callbacks.
  const pollGenerationRef = useRef<number>(0);
  const playbackJourneyRef = useRef<string | null>(null);
  const seekJourneyRef = useRef<string | null>(null);
  const [playbackRate, setPlaybackRate] = useState<number>(() => {
    try {
      const saved = window.localStorage.getItem(SPEED_KEY);
      const parsed = saved !== null ? Number(saved) : NaN;
      return (PLAYBACK_RATES as ReadonlyArray<number>).includes(parsed)
        ? parsed
        : 1;
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
    if (!currentChapterEntry) return "";
    return `${currentChapterEntry.index}. ${currentChapterEntry.name}`;
  }, [currentChapterEntry]);

  // Update MediaSession API
  useEffect(() => {
    if (!("mediaSession" in navigator)) return;
    const title = bookTitle || "Audiobook";
    const artist = bookAuthor || "Converter";
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
                sizes: "512x512",
                type: "image/png",
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
      const data = await conversionClient.getChapterManifest?.(
        jobId,
        currentChapter,
      );

      // Discard result if stop was called while fetch was in flight.
      if (pollGenerationRef.current !== generation) return;

      if (!data) {
        setWaiting(true);
        pollTimeoutRef.current = window.setTimeout(
          pollForChunk,
          POLL_INTERVAL_MS,
        );
        return;
      }

      const sortedChunks = (data.chunks || [])
        .slice()
        .sort((a, b) => a.index - b.index);
      const normalizedManifest = { ...data, chunks: sortedChunks };
      setManifest(normalizedManifest);

      // Exact match only — do not skip ahead to a later segment if the current
      // one has not been generated yet.  If missing, fall through to re-poll.
      const nextChunk = sortedChunks.find(
        (chunk) => chunk.index === currentSegment,
      );

      if (nextChunk && nextChunk.url) {
        if (playbackJourneyRef.current) {
          latencyObservations.record(playbackJourneyRef.current, "audio_queued");
        }
        setSrc(nextChunk.url);
        setCurrentSegmentText(nextChunk.text || "");
        setCurrentSegment(nextChunk.index);
        setWaiting(false);
      } else {
        setWaiting(true);
        pollTimeoutRef.current = window.setTimeout(
          pollForChunk,
          POLL_INTERVAL_MS,
        );
      }
    } catch (fetchErr) {
      if (pollGenerationRef.current !== generation) return;
      console.warn("[StreamingAudio] manifest fetch failed", fetchErr);
      setWaiting(true);
      pollTimeoutRef.current = window.setTimeout(
        pollForChunk,
        POLL_INTERVAL_MS,
      );
    }
  }, [jobId, started, currentChapter, currentSegment]);

  useEffect(() => {
    if (pollTimeoutRef.current) {
      window.clearTimeout(pollTimeoutRef.current);
    }
    if (started && jobId) {
      pollForChunk();
    }
    return () => {
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

    audio.src = src;
    audio.play().catch((err) => {
      console.error("[StreamingPlayer] Playback failed:", err);
      setError(err?.message || "Playback failed");
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
      "progressive_playback",
      "interaction_requested",
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
            typeof pos.chapterIndex === "number" &&
            typeof pos.segmentIndex === "number" &&
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
    seekJourneyRef.current = latencyObservations.begin("seek", "seek_requested");
    const audio = audioRef.current;
    if (audio) {
      audio.pause();
      audio.src = "";
    }
    setCurrentChapter(chapterIndex);
    setCurrentSegment(0);
    setManifest(null);
    setSrc(null);
    setCurrentSegmentText("");
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
      audio.src = "";
    }
    setSrc(null);
    setManifest(null);
    setCurrentSegmentText("");
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
      latencyObservations.record(playbackJourneyRef.current, "audio_playable");
    }
  };

  const handleTimeUpdate = () => {
    const audio = audioRef.current;
    if (!audio || audio.currentTime <= 0) return;
    if (playbackJourneyRef.current) {
      latencyObservations.record(playbackJourneyRef.current, "audio_audible");
      latencyObservations.finish(playbackJourneyRef.current);
      playbackJourneyRef.current = null;
    }
    if (seekJourneyRef.current) {
      latencyObservations.record(seekJourneyRef.current, "seek_target_reached");
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
      (currentChapterEntry.status === "completed" ||
        currentChapterEntry.status === "failed" ||
        currentChapterEntry.status === "skipped" ||
        currentChapterEntry.status === "cancelled");

    if (!chapterDone) {
      // Chapter still in progress — move to next index and poll for it
      setCurrentSegment(nextSegmentIndex);
      return;
    }

    // Chapter is done: only advance segment if it already exists in the manifest
    if (manifest && manifest.chunks) {
      const nextSegment = manifest.chunks.find(
        (chunk) => chunk.index === nextSegmentIndex,
      );
      if (nextSegment) {
        setCurrentSegment(nextSegmentIndex);
        return;
      }
    }

    // No more segments in current chapter, try next chapter
    const currentChapterIdx = sortedChapters.findIndex(
      (ch) => ch.index === currentChapter,
    );
    if (
      currentChapterIdx >= 0 &&
      currentChapterIdx < sortedChapters.length - 1
    ) {
      const nextChapter = sortedChapters[currentChapterIdx + 1];
      setCurrentChapter(nextChapter.index);
      setCurrentSegment(0);
      setManifest(null);
      setSrc(null);
      setCurrentSegmentText("");
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
    const currentIdx = sortedChapters.findIndex(
      (ch) => ch.index === currentChapter,
    );
    if (currentIdx >= 0 && currentIdx < sortedChapters.length - 1) {
      const nextChapter = sortedChapters[currentIdx + 1];
      setCurrentChapter(nextChapter.index);
      setCurrentSegment(0);
      setManifest(null);
      setSrc(null);
      setCurrentSegmentText("");
    }
  };

  const handlePrevChapter = () => {
    const currentIdx = sortedChapters.findIndex(
      (ch) => ch.index === currentChapter,
    );
    if (currentIdx > 0) {
      const prevChapter = sortedChapters[currentIdx - 1];
      setCurrentChapter(prevChapter.index);
      setCurrentSegment(0);
      setManifest(null);
      setSrc(null);
      setCurrentSegmentText("");
    }
  };

  if (!jobId || !chapters || chapters.length === 0) {
    return null;
  }

  const currentProgress = manifest?.chunks
    ? `${currentSegment + 1} / ${manifest.chunks.length}`
    : waiting
      ? locale === "pt"
        ? "Aguardando"
        : "Waiting..."
      : locale === "pt"
        ? "Pronto"
        : "Ready";
  const title = locale === "pt" ? "Leitura contínua" : "Sequential Player";
  const idleChapterLabel =
    locale === "pt" ? "Selecione um capítulo" : "Select a chapter";
  const listenNowLabel =
    locale === "pt"
      ? "Ouvir agora em sequência"
      : "Listen now (sequential streaming)";
  const prevChapterLabel =
    locale === "pt" ? "Capítulo anterior" : "Prev chapter";
  const nextChapterLabel =
    locale === "pt" ? "Próximo capítulo" : "Next chapter";
  const stopLabel = locale === "pt" ? "Parar" : "Stop";
  const speedLabel = locale === "pt" ? "Velocidade" : "Speed";
  const jumpLabel = locale === "pt" ? "Ir para" : "Jump to";
  const openReaderHint =
    locale === "pt"
      ? "Use o leitor para começar a reprodução."
      : "Open the reader above to start the book.";
  const waitingLabel =
    locale === "pt"
      ? "Aguardando próximo trecho..."
      : "Waiting for next segment...";
  const readyLabel = locale === "pt" ? "Pronto para começar" : "Ready to start";
  const segmentLabel =
    locale === "pt"
      ? `Trecho ${currentProgress}`
      : `Segment ${currentProgress}`;
  const currentSegmentTextLabel =
    locale === "pt" ? "Trecho atual" : "Current segment text";
  const chunksLabel =
    locale === "pt" ? "Trechos do capítulo atual" : "Current chapter segments";

  return (
    <div
      className={`streaming-player${embedded ? " streaming-player--embedded" : ""}`}
    >
      <div className="streaming-player__header">
        <div>
          <div className="streaming-player__title">
            {isPlaying ? "▶" : "❚❚"} {title}
          </div>
          <div className="streaming-player__chapter">
            {currentChapterLabel || idleChapterLabel}
          </div>
        </div>
        {!started && !hideStartButton ? (
          <button
            type="button"
            className="button"
            onClick={handleStart}
            disabled={!jobId || sortedChapters.length === 0}
          >
            {listenNowLabel}
          </button>
        ) : started ? (
          <div className="streaming-player__controls">
            <button
              type="button"
              className="button-secondary"
              onClick={handlePrevChapter}
              disabled={currentChapter === sortedChapters[0]?.index}
            >
              {prevChapterLabel}
            </button>
            <button
              type="button"
              className="button-secondary"
              onClick={handleNextChapter}
              disabled={
                currentChapter ===
                sortedChapters[sortedChapters.length - 1]?.index
              }
            >
              {nextChapterLabel}
            </button>
            <label className="streaming-player__speed">
              <span>{speedLabel}</span>
              <select
                value={playbackRate}
                onChange={(e) => setPlaybackRate(Number(e.target.value))}
              >
                {PLAYBACK_RATES.map((rate) => (
                  <option key={rate} value={rate}>
                    {rate}x
                  </option>
                ))}
              </select>
            </label>
            <label className="streaming-player__jump">
              <span>{jumpLabel}</span>
              <select
                value={currentChapter}
                onChange={(e) => handleChapterJump(Number(e.target.value))}
              >
                {sortedChapters.map((ch) => (
                  <option key={ch.index} value={ch.index}>
                    {ch.index}. {ch.name}
                  </option>
                ))}
              </select>
            </label>
            <button
              type="button"
              className="button-secondary"
              onClick={handleStop}
            >
              {stopLabel}
            </button>
          </div>
        ) : (
          <div className="streaming-player__controls streaming-player__controls--passive">
            <span className="streaming-player__hint">{openReaderHint}</span>
          </div>
        )}
      </div>

      <div className="streaming-player__body">
        <audio
          ref={audioRef}
          controls
          onEnded={handleEnded}
          onPlay={handlePlay}
          onPause={handlePause}
          onCanPlay={handleCanPlay}
          onTimeUpdate={handleTimeUpdate}
          style={{ width: "100%" }}
        />
        <div className="streaming-player__meta">
          <span>
            {waiting ? waitingLabel : src ? segmentLabel : readyLabel}
          </span>
          {error && <span className="streaming-player__error">{error}</span>}
        </div>

        {currentSegmentText && (
          <div className="streaming-player__text">
            <div className="streaming-player__text-label">
              {currentSegmentTextLabel}
            </div>
            <div className="streaming-player__text-content">
              {currentSegmentText}
            </div>
          </div>
        )}
      </div>

      {manifest?.chunks && manifest.chunks.length > 0 && (
        <div className="streaming-player__chunks">
          <div className="streaming-player__chunks-label">{chunksLabel}</div>
          <div className="streaming-player__chunks-list">
            {manifest.chunks.map((chunk: AudioChunkEntry) => (
              <span
                key={`chunk-${chunk.index}`}
                className={`streaming-player__chip ${
                  chunk.index === currentSegment ? "is-active" : ""
                } ${chunk.index < currentSegment ? "is-completed" : ""}`}
              >
                #{chunk.index + 1}
              </span>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
