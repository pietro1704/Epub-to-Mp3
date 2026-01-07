import { useEffect, useMemo, useRef, useState } from "react";
import { conversionClient } from "../services/ConversionService";
import {
  ChapterProgressEntry,
  ChapterStreamManifest,
} from "../types/conversion";

interface StreamingAudioPlayerProps {
  jobId?: string;
  chapters?: ChapterProgressEntry[] | null;
  bookTitle?: string;
  bookAuthor?: string;
  coverUrl?: string;
}

const POLL_INTERVAL_MS = 2000;

function selectInitialChapter(
  chapters?: ChapterProgressEntry[] | null,
): number | null {
  if (!chapters || chapters.length === 0) return null;
  const active = chapters.find(
    (chapter) =>
      chapter.status === "processing" || chapter.status === "retrying",
  );
  if (active) return active.index;
  return chapters[0]?.index ?? null;
}

export default function StreamingAudioPlayer({
  jobId,
  chapters,
  bookTitle,
  bookAuthor,
  coverUrl,
}: StreamingAudioPlayerProps): JSX.Element | null {
  const [started, setStarted] = useState(false);
  const [currentChapter, setCurrentChapter] = useState<number | null>(
    selectInitialChapter(chapters),
  );
  const [currentChunk, setCurrentChunk] = useState(0);
  const [manifest, setManifest] = useState<ChapterStreamManifest | null>(null);
  const [waiting, setWaiting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const audioRef = useRef<HTMLAudioElement>(null);
  const [src, setSrc] = useState<string | null>(null);

  useEffect(() => {
    setCurrentChapter(selectInitialChapter(chapters));
  }, [chapters]);

  const currentChapterLabel = useMemo(() => {
    if (!chapters || currentChapter === null) return "";
    const entry = chapters.find((item) => item.index === currentChapter);
    return entry ? `${entry.index}. ${entry.name}` : "";
  }, [chapters, currentChapter]);

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

  useEffect(() => {
    if (!jobId || !started || currentChapter === null) {
      return;
    }
    let cancelled = false;
    let timeoutId: number | undefined;

    const poll = async () => {
      if (cancelled) return;
      try {
        const data = await conversionClient.getChapterManifest?.(
          jobId,
          currentChapter,
        );
        if (cancelled) return;
        if (!data) {
          setWaiting(true);
          timeoutId = window.setTimeout(poll, POLL_INTERVAL_MS);
          return;
        }
        setManifest(data);
        const nextChunk = (data.chunks || []).find(
          (chunk) =>
            typeof chunk.index === "number" && chunk.index >= currentChunk,
        );
        if (nextChunk && nextChunk.url) {
          setSrc(nextChunk.url);
          setWaiting(false);
        } else {
          setWaiting(true);
          timeoutId = window.setTimeout(poll, POLL_INTERVAL_MS);
        }
      } catch (fetchErr) {
        console.warn("[StreamingAudio] manifest fetch failed", fetchErr);
        setWaiting(true);
        timeoutId = window.setTimeout(poll, POLL_INTERVAL_MS);
      }
    };

    poll();
    return () => {
      cancelled = true;
      if (timeoutId) {
        window.clearTimeout(timeoutId);
      }
    };
  }, [jobId, started, currentChapter, currentChunk]);

  useEffect(() => {
    if (!started || !src) return;
    const audio = audioRef.current;
    if (!audio) return;
    audio.src = src;
    audio.play().catch((err) => {
      setError(err?.message || "Playback failed");
    });
  }, [src, started]);

  const handleStart = async () => {
    setError(null);
    setWaiting(true);
    setStarted(true);
  };

  const handleEnded = () => {
    setCurrentChunk((prev) => prev + 1);
  };

  const handleNextChapter = () => {
    if (!chapters || currentChapter === null) return;
    const next = chapters
      .filter(
        (entry) => entry.index > currentChapter && entry.status !== "failed",
      )
      .sort((a, b) => a.index - b.index)[0];
    if (next) {
      setCurrentChapter(next.index);
      setCurrentChunk(0);
      setManifest(null);
      setSrc(null);
    }
  };

  const isActive = started && jobId && currentChapter !== null;
  if (!jobId || !chapters || chapters.length === 0) {
    return null;
  }

  return (
    <div className="streaming-player">
      <div className="streaming-player__header">
        <div>
          <div className="streaming-player__title">Streaming Player</div>
          <div className="streaming-player__chapter">
            {currentChapterLabel || "Select a chapter"}
          </div>
        </div>
        {!started ? (
          <button
            type="button"
            className="button"
            onClick={handleStart}
            disabled={!jobId}
          >
            ▶️ Start listening
          </button>
        ) : (
          <button
            type="button"
            className="button-secondary"
            onClick={handleNextChapter}
            disabled={!isActive}
          >
            Skip chapter →
          </button>
        )}
      </div>

      <div className="streaming-player__body">
        <audio
          ref={audioRef}
          controls
          playsInline
          onEnded={handleEnded}
          style={{ width: "100%" }}
        />
        <div className="streaming-player__meta">
          <span>
            {waiting
              ? "Waiting for next chunk…"
              : src
                ? `Playing chunk ${currentChunk + 1}`
                : "Ready"}
          </span>
          {error && <span className="streaming-player__error">⚠️ {error}</span>}
        </div>
      </div>

      {manifest?.chunks?.length ? (
        <div className="streaming-player__chunks">
          {manifest.chunks.slice(0, 6).map((chunk) => (
            <span
              key={`chunk-${chunk.index}`}
              className={`streaming-player__chip ${
                chunk.index === currentChunk ? "is-active" : ""
              }`}
            >
              #{chunk.index}
            </span>
          ))}
        </div>
      ) : null}
    </div>
  );
}
