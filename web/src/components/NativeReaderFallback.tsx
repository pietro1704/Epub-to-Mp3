import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useTranslations } from '../i18n/I18nProvider';
import { conversionClient } from '../services/ConversionService';
import { browserNativeSpeech } from '../services/BrowserNativeSpeech';
import {
  createNativePlaybackPublication,
  useNativePlayback,
  type NativePlaybackPublication,
} from '../services/NativePlaybackPresentation';

type NativePolicy = { language: string; voice: string | null };

/** Native narration is independent of converted MP3 state and can never finish a job. */
export default function NativeReaderFallback({
  jobId,
  chapterIndex,
  text,
}: {
  jobId: string;
  chapterIndex: number;
  text: string;
}): JSX.Element | null {
  const labels = useTranslations().form.ttsPreferences;
  const owner = useMemo(() => Symbol('reader-native-narration'), [jobId, chapterIndex, text]);
  const snapshot = useNativePlayback(jobId);
  const playback = snapshot?.owner === owner ? snapshot : null;
  const phase = playback?.phase ?? 'idle';
  const active = phase === 'starting' || phase === 'playing' || phase === 'paused';
  const [capturedPolicy, setPolicy] = useState<{
    jobId: string;
    value: NativePolicy | null;
  } | null>(null);
  const policy = capturedPolicy?.jobId === jobId ? capturedPolicy.value : null;
  const [unavailableOwner, setUnavailableOwner] = useState<symbol | null>(null);
  const [retryFailureOwner, setRetryFailureOwner] = useState<symbol | null>(null);
  const requestGeneration = useRef(0);
  const unavailable = useRef<{ owner: symbol; publication: NativePlaybackPublication } | null>(
    null,
  );
  const cancelOwned = useCallback(() => {
    requestGeneration.current++;
    browserNativeSpeech()?.cancel(owner);
    if (unavailable.current?.owner === owner) {
      unavailable.current.publication.release();
      unavailable.current = null;
    }
  }, [owner]);

  useEffect(() => {
    let current = true;
    setPolicy(null);
    const refresh = async () => {
      try {
        const value = await conversionClient.getNativePlaybackPolicy?.(jobId);
        if (current) setPolicy({ jobId, value: value ?? null });
      } catch {
        /* A transient refresh failure does not revoke captured job policy. */
      }
    };
    void refresh();
    const timer = setInterval(() => void refresh(), 1000);
    return () => {
      current = false;
      clearInterval(timer);
    };
  }, [jobId]);

  useEffect(() => {
    setUnavailableOwner(null);
    setRetryFailureOwner(null);
    const primaryPlay = () => {
      cancelOwned();
      setUnavailableOwner(null);
      setRetryFailureOwner(null);
    };
    document.addEventListener('play', primaryPlay, true);
    return () => {
      document.removeEventListener('play', primaryPlay, true);
      cancelOwned();
    };
  }, [cancelOwned]);

  useEffect(() => {
    if (!policy || !text.trim()) cancelOwned();
  }, [policy, text, cancelOwned]);

  if (!policy || !text.trim()) return null;
  const start = () => {
    requestGeneration.current++;
    setUnavailableOwner(null);
    setRetryFailureOwner(null);
    unavailable.current?.publication.release();
    unavailable.current = null;
    const speech = browserNativeSpeech();
    const context = { owner, jobId, chapterIndex };
    if (!speech) {
      const publication = createNativePlaybackPublication(context);
      unavailable.current = { owner, publication };
      publication.start();
      publication.update({ phase: 'failed' });
      setUnavailableOwner(owner);
      return;
    }
    void speech
      .speak(text, policy.language, policy.voice, () => undefined, context)
      .catch(() => undefined); // The engine publishes failure; cancellation retires it.
  };
  const retry = () => {
    cancelOwned();
    setUnavailableOwner(null);
    setRetryFailureOwner(null);
    const generation = requestGeneration.current;
    void conversionClient.resume?.(jobId).catch(() => {
      if (generation === requestGeneration.current) setRetryFailureOwner(owner);
    });
  };
  const message =
    retryFailureOwner === owner
      ? labels.nativeRetryFailure
      : unavailableOwner === owner
        ? labels.nativeUnavailable
        : phase === 'failed'
          ? labels.nativeFailure
          : (playback?.voice ?? '');
  return (
    <div aria-label="System narration fallback">
      <p>{labels.nativeNotice}</p>
      <p role="status">{message}</p>
      <button type="button" onClick={start} disabled={active}>
        {labels.nativeListen}
      </button>
      <button
        type="button"
        disabled={!active || phase === 'starting'}
        onClick={() => {
          if (phase === 'paused') browserNativeSpeech()?.resume(owner);
          else browserNativeSpeech()?.pause(owner);
        }}
      >
        {phase === 'paused' ? labels.nativeResume : labels.nativePause}
      </button>
      <button type="button" disabled={!active} onClick={cancelOwned}>
        {labels.nativeStop}
      </button>
      <button type="button" onClick={retry}>
        {labels.nativeRetry}
      </button>
    </div>
  );
}
