import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { conversionClient } from "../services/ConversionService";
import {
  ChapterProgressEntry,
  ChapterStreamManifest,
  AudioChunkEntry,
} from "../types/conversion";

interface StreamingAudioPlayerProps {
  jobId?: string;
  chapters?: ChapterProgressEntry[] | null;
  bookTitle?: string;
  bookAuthor?: string;
  coverUrl?: string;
  onPlayingSegment?: (chapterIndex: number, segmentIndex: number) => void;
}

const POLL_INTERVAL_MS = 1500;

export default function StreamingAudioPlayer({
  jobId,
  chapters,
  bookTitle,
  bookAuthor,
  coverUrl,
  onPlayingSegment,
}: StreamingAudioPlayerProps): JSX.Element | null {
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
  const pollTimeoutRef = useRef<number>();

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

  // Notify parent about current playing segment
  useEffect(() => {
    if (isPlaying && onPlayingSegment) {
      onPlayingSegment(currentChapter, currentSegment);
    }
  }, [isPlaying, currentChapter, currentSegment, onPlayingSegment]);

  // Poll for next chunk
  const pollForChunk = useCallback(async () => {
    if (!jobId || !started) return;

    try {
      const data = await conversionClient.getChapterManifest?.(
        jobId,
        currentChapter,
      );

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

      const nextChunk = sortedChunks.find(
        (chunk) => chunk.index >= currentSegment,
      );

      if (nextChunk && nextChunk.url) {
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

  const handleStart = () => {
    setError(null);
    setWaiting(true);
    setStarted(true);
    setCurrentChapter(sortedChapters[0]?.index ?? 0);
    setCurrentSegment(0);
  };

  const handlePause = () => {
    setIsPlaying(false);
  };

  const handlePlay = () => {
    setIsPlaying(true);
  };

  const handleEnded = () => {
    // Try next segment in current chapter
    if (manifest && manifest.chunks) {
      const nextSegment = manifest.chunks.find(
        (chunk) => chunk.index > currentSegment,
      );
      if (nextSegment) {
        setCurrentSegment(nextSegment.index);
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
      ? "Waiting..."
      : "Ready";

  return (
    <div className="streaming-player">
      <div className="streaming-player__header">
        <div>
          <div className="streaming-player__title">
            {isPlaying ? "▶️" : "⏸️"} Sequential Player
          </div>
          <div className="streaming-player__chapter">
            {currentChapterLabel || "Select a chapter"}
          </div>
        </div>
        {!started ? (
          <button
            type="button"
            className="button"
            onClick={handleStart}
            disabled={!jobId || sortedChapters.length === 0}
          >
            ▶️ Listen now (sequential streaming)
          </button>
        ) : (
          <div className="streaming-player__controls">
            <button
              type="button"
              className="button-secondary"
              onClick={handlePrevChapter}
              disabled={currentChapter === sortedChapters[0]?.index}
            >
              ⏮️ Prev chapter
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
              Next chapter ⏭️
            </button>
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
          style={{ width: "100%" }}
        />
        <div className="streaming-player__meta">
          <span>
            {waiting
              ? "⏳ Waiting for next segment..."
              : src
                ? `🎧 Segment ${currentProgress}`
                : "Ready to start"}
          </span>
          {error && <span className="streaming-player__error">⚠️ {error}</span>}
        </div>

        {currentSegmentText && (
          <div className="streaming-player__text">
            <div className="streaming-player__text-label">
              📖 Current segment text:
            </div>
            <div className="streaming-player__text-content">
              {currentSegmentText}
            </div>
          </div>
        )}
      </div>

      {manifest?.chunks && manifest.chunks.length > 0 && (
        <div className="streaming-player__chunks">
          <div className="streaming-player__chunks-label">
            Current chapter segments:
          </div>
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
