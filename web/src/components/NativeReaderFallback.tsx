import { useTranslations } from "../i18n/I18nProvider";
import { useEffect, useRef, useState } from "react";
import { conversionClient } from "../services/ConversionService";
import { browserNativeSpeech } from "../services/BrowserNativeSpeech";

/** Native narration is independent of converted MP3 state and can never finish a job. */
export default function NativeReaderFallback({ jobId, chapterIndex, text }: { jobId: string; chapterIndex: number; text: string }): JSX.Element | null {
  const labels = useTranslations().form.ttsPreferences;
  const [policy, setPolicy] = useState<{ language: string; voice: string | null } | null>(null);
  const [state, setState] = useState<"idle" | "playing" | "paused">("idle");
  const [message, setMessage] = useState("");
  const requestGeneration = useRef(0);
  useEffect(() => {
    let active = true;
    setPolicy(null);
    const refresh = async () => {
      try {
        const value = await conversionClient.getNativePlaybackPolicy?.(jobId);
        if (active) setPolicy(value ?? null);
      } catch { if (active) setPolicy(null); }
    };
    void refresh();
    const primaryPlay = () => { requestGeneration.current++; browserNativeSpeech()?.cancel(); setState("idle"); };
    window.document.addEventListener("play", primaryPlay, true);
    const timer = setInterval(() => void refresh(), 1000);
    return () => { active = false; requestGeneration.current++; window.document.removeEventListener("play", primaryPlay, true); clearInterval(timer); browserNativeSpeech()?.cancel(); };
  }, [jobId]);
  useEffect(() => {
    requestGeneration.current++;
    browserNativeSpeech()?.cancel();
    setState("idle");
    setMessage("");
    return () => { requestGeneration.current++; browserNativeSpeech()?.cancel(); };
  }, [jobId, chapterIndex, text]);
  if (!policy || !text.trim()) return null;
  const start = async () => {
    const speech = browserNativeSpeech();
    if (!speech) { setMessage(labels.nativeUnavailable); return; }
    const generation = ++requestGeneration.current;
    setState("playing");
    try {
      await speech.speak(text, policy.language, policy.voice, voice => {
        if (generation === requestGeneration.current) setMessage(voice);
      });
      if (generation === requestGeneration.current) setState("idle");
    } catch (error) {
      if (generation !== requestGeneration.current) return;
      if (error instanceof DOMException && error.name === "AbortError") return;
      setMessage(String(error)); setState("idle");
    }
  };
  const retry = () => {
    const generation = ++requestGeneration.current;
    browserNativeSpeech()?.cancel();
    setState("idle");
    void conversionClient.resume?.(jobId).catch(error => {
      if (generation === requestGeneration.current) setMessage(String(error));
    });
  };
  return <div aria-label="System narration fallback">
    <p>{labels.nativeNotice}</p>
    <p role="status">{message}</p>
    <button type="button" onClick={() => void start()} disabled={state !== "idle"}>{labels.nativeListen}</button>
    <button type="button" disabled={state === "idle"} onClick={() => { if (state === "paused") { browserNativeSpeech()?.resume(); setState("playing"); } else { browserNativeSpeech()?.pause(); setState("paused"); } }}>{state === "paused" ? labels.nativeResume : labels.nativePause}</button>
    <button type="button" disabled={state === "idle"} onClick={() => { requestGeneration.current++; browserNativeSpeech()?.cancel(); setState("idle"); }}>{labels.nativeStop}</button>
    <button type="button" onClick={retry}>{labels.nativeRetry}</button>
  </div>;
}
