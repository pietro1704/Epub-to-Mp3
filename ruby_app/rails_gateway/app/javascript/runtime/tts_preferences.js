// Saved narration policy. Port of the former React client's TtsPreferences.ts (removed in the Rails cutover) with the
// same localStorage key and shape, so both clients read each other's choice.
// Storage is injected because access to localStorage itself can throw.

/**
 * @typedef {import("./tts_catalog.js").TtsSelection} TtsSelection
 * @typedef {object} TtsPreferences
 * @property {number} [policy_version]
 * @property {TtsSelection} primary
 * @property {TtsSelection | null} secondary
 * @property {boolean} allow_online_fallback
 */

export const TTS_PREFERENCES_KEY = "ebook-tts.preferences.v1"
export const faber = Object.freeze({ engine: "piper", model_id: "pt_BR-faber-medium", voice: null })
export const system = Object.freeze({ engine: "system", model_id: null, voice: null })
export const edge = Object.freeze({ engine: "edge", model_id: null, voice: null })

/**
 * @param {Pick<Storage, "getItem"> | undefined} storage
 * @returns {TtsPreferences}
 */
export function loadTtsPreferences(storage) {
  try {
    const stored = storage?.getItem(TTS_PREFERENCES_KEY)
    if (stored) {
      const value = JSON.parse(stored)
      if ([ "piper", "edge", "system" ].includes(value?.primary?.engine)) return value
    }
  } catch { /* An inaccessible or malformed store uses fresh defaults. */ }
  return { policy_version: 2, primary: { ...faber }, secondary: { ...system }, allow_online_fallback: false }
}

/**
 * @param {Pick<Storage, "setItem"> | undefined} storage
 * @param {TtsPreferences} value
 */
export function saveTtsPreferences(storage, value) {
  if (!storage) throw new Error("Preferences cannot be saved in this browser.")
  storage.setItem(TTS_PREFERENCES_KEY, JSON.stringify(value))
}

/**
 * Per-job overrides never mutate defaults or silently retain a saved secondary.
 * @param {TtsPreferences} saved
 * @param {TtsSelection | null} override
 * @param {boolean} [useSecondary]
 * @returns {TtsPreferences}
 */
export function effectiveTtsPreferences(saved, override, useSecondary = false) {
  const secondary = useSecondary && saved.secondary && override && !(
    override.engine === saved.secondary.engine &&
    (override.model_id ?? null) === (saved.secondary.model_id ?? null) &&
    (override.voice ?? null) === (saved.secondary.voice ?? null)
  ) ? saved.secondary : null
  return structuredClone(override ? {
    ...(secondary && saved.policy_version !== undefined ? { policy_version: saved.policy_version } : {}),
    primary: override,
    secondary,
    allow_online_fallback: secondary !== null && saved.allow_online_fallback,
  } : saved)
}
