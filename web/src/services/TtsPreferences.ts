import type { TtsPreferences, TtsSelection } from "../types/conversion";
const key = "ebook-tts.preferences.v1";
export const faber: TtsSelection = { engine: "piper", model_id: "pt_BR-faber-medium", voice: null };
export const system: TtsSelection = { engine: "system", model_id: null, voice: null };
export const edge: TtsSelection = { engine: "edge", model_id: null, voice: null };
export function loadTtsPreferences(): TtsPreferences {
  try {
    const stored = localStorage.getItem(key);
    if (stored) {
      const value = JSON.parse(stored) as TtsPreferences;
      if (["piper", "edge", "system"].includes(value.primary.engine)) return value;
    }
  } catch { /* An inaccessible store uses fresh defaults. */ }
  return { policy_version: 2, primary: { ...faber }, secondary: { ...system }, allow_online_fallback: false };
}
export function saveTtsPreferences(value: TtsPreferences): void {
  localStorage.setItem(key, JSON.stringify(value));
}

/** Per-job overrides never mutate defaults or silently retain a saved secondary. */
export function effectiveTtsPreferences(saved: TtsPreferences, override: TtsSelection | null, useSecondary = false): TtsPreferences {
  const secondary = useSecondary && saved.secondary && override && !(
    override.engine === saved.secondary.engine &&
    (override.model_id ?? null) === (saved.secondary.model_id ?? null) &&
    (override.voice ?? null) === (saved.secondary.voice ?? null)
  ) ? saved.secondary : null;
  return structuredClone(override ? {
    ...(secondary && saved.policy_version !== undefined ? { policy_version: saved.policy_version } : {}),
    primary: override,
    secondary,
    allow_online_fallback: secondary !== null && saved.allow_online_fallback,
  } : saved);
}
