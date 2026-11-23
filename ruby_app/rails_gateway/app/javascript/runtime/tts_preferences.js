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
export function isLowPiperSelection(selection) {
  const modelId = selection?.model_id ?? selection?.session?.model_id
  const stem = typeof modelId === "string" ? modelId.trim().toLowerCase().split(".")[0] : ""
  return selection?.engine === "piper" && /(?:^|[-_])low$/.test(stem)
}

export function availableTtsPreferences(preferences, installedManual) {
  const selection = preferences.primary
  if (!isLowPiperSelection(selection)) return preferences
  const revision = selection.session?.model_revision
  if (revision && (installedManual === null || installedManual.some(choice =>
    choice.model_id === selection.model_id && choice.session.model_revision === revision
  ))) return preferences
  return {
    ...preferences,
    primary: faber,
    secondary: preferences.secondary?.model_id === faber.model_id ? null : preferences.secondary,
  }
}

function withoutLowFallback(preferences) {
  return isLowPiperSelection(preferences.secondary)
    ? { ...preferences, secondary: null, allow_online_fallback: false }
    : preferences
}


/**
 * @param {Pick<Storage, "getItem"> | undefined} storage
 * @returns {TtsPreferences}
 */
export function loadTtsPreferences(storage) {
  try {
    const stored = storage?.getItem(TTS_PREFERENCES_KEY)
    if (stored) {
      const value = JSON.parse(stored)
      if ([ "piper", "edge", "system" ].includes(value?.primary?.engine)) return withoutLowFallback(value)
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
 * The saved online consent follows an override only where Edge is actually used:
 * as the requested secondary, or as the override primary itself (Edge as primary
 * needs that consent, and without it the converter refuses the job).
 * @param {TtsPreferences} saved
 * @param {TtsSelection | null} override
 * @param {boolean} [useSecondary]
 * @returns {TtsPreferences}
 */
export function effectiveTtsPreferences(saved, override, useSecondary = false) {
  saved = withoutLowFallback(saved)
  const secondary = useSecondary && saved.secondary && override && !(
    override.engine === saved.secondary.engine &&
    (override.model_id ?? null) === (saved.secondary.model_id ?? null) &&
    (override.voice ?? null) === (saved.secondary.voice ?? null)
  ) ? saved.secondary : null
  return structuredClone(override ? {
    ...(secondary && saved.policy_version !== undefined ? { policy_version: saved.policy_version } : {}),
    primary: override,
    secondary,
    allow_online_fallback: (secondary !== null || override.engine === "edge") && saved.allow_online_fallback,
  } : saved)
}
