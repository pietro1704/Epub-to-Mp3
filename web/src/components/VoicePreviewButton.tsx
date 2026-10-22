import { useEffect, useRef, useState } from 'react';
import { resolveApiUrl } from '../config';

/* ── Voice Preview Button ─────────────────────────────────────────────── */
export function VoicePreviewButton({
  engine,
  voice,
  language,
  t,
}: {
  engine: string;
  voice: string;
  language: string;
  t: {
    form: {
      voicePreviewPlay: string;
      voicePreviewStop: string;
      voicePreviewLoading: string;
      voicePreviewError: string;
    };
  };
}) {
  const [state, setState] = useState<'idle' | 'loading' | 'playing' | 'error'>('idle');
  const audioRef = useRef<HTMLAudioElement | null>(null);

  const stop = () => {
    if (audioRef.current) {
      audioRef.current.pause();
      audioRef.current.src = '';
      audioRef.current = null;
    }
    setState('idle');
  };

  const play = async () => {
    stop();
    setState('loading');
    try {
      const url = resolveApiUrl(
        `/api/voice-preview?engine=${encodeURIComponent(engine)}&voice=${encodeURIComponent(voice)}&language=${encodeURIComponent(language || 'pt')}`,
      );
      const res = await fetch(url);
      if (!res.ok) throw new Error(res.statusText);
      const blob = await res.blob();
      const objectUrl = URL.createObjectURL(blob);
      const audio = new Audio(objectUrl);
      audioRef.current = audio;
      audio.onended = () => {
        URL.revokeObjectURL(objectUrl);
        setState('idle');
      };
      audio.onerror = () => {
        URL.revokeObjectURL(objectUrl);
        setState('error');
      };
      await audio.play();
      setState('playing');
    } catch {
      setState('error');
    }
  };

  // Cleanup on unmount or engine/voice change
  useEffect(() => stop, [engine, voice]);

  const label =
    state === 'loading'
      ? t.form.voicePreviewLoading
      : state === 'playing'
        ? t.form.voicePreviewStop
        : state === 'error'
          ? t.form.voicePreviewError
          : t.form.voicePreviewPlay;

  return (
    <button
      type="button"
      className={`voice-preview-btn voice-preview-btn--${state}`}
      onClick={state === 'playing' ? stop : play}
      disabled={state === 'loading'}
      title={label}
    >
      {state === 'loading' && <span className="voice-preview-btn__spinner" />}
      {state === 'playing' && <span className="voice-preview-btn__icon">&#9632;</span>}
      {state === 'idle' && <span className="voice-preview-btn__icon">&#9654;</span>}
      {state === 'error' && <span className="voice-preview-btn__icon">&#9888;</span>}
      <span className="voice-preview-btn__label">{label}</span>
    </button>
  );
}
