// Validation of installed Piper models, shared by the module worker and its
// node tests. It imports nothing, so it runs unchanged in both places. Ported
// from the former React client's BrowserPiperRuntime.ts (removed in the Rails cutover).

export const MAX_SEGMENT_CODE_POINTS = 800

/**
 * @typedef {object} PiperConfig
 * @property {{sample_rate: number}} audio
 * @property {{voice: string}} espeak
 * @property {{noise_scale: number, length_scale: number, noise_w: number}} inference
 * @property {Record<string, number>} [speaker_id_map]
 */

/** Model IDs name OPFS files, so they can never address another directory. @param {string} modelId */
export function assertInstalledModelId(modelId) {
  const unsafe = !modelId || /[\\/]/.test(modelId) || Array.from(modelId).some((character) => character.charCodeAt(0) < 32) ||
    modelId === "." || modelId === ".."
  if (unsafe) throw new Error("Invalid installed model ID")
}

/** @param {unknown} value @returns {PiperConfig} */
export function validatedConfig(value) {
  const config = /** @type {any} */ (value)
  const valid = Number.isInteger(config?.audio?.sample_rate) && config.audio.sample_rate >= 8000 && config.audio.sample_rate <= 96000 &&
    Boolean(config.espeak?.voice) && Object.values(config.inference ?? {}).every(Number.isFinite) &&
    Number.isFinite(config.inference?.noise_scale) && Number.isFinite(config.inference?.length_scale) &&
    Number.isFinite(config.inference?.noise_w)
  if (!valid) throw new Error("Unsupported Piper model configuration")
  return config
}

/** @param {string} text */
export function assertSegmentLength(text) {
  if (!text.trim() || Array.from(text).length > MAX_SEGMENT_CODE_POINTS) throw new Error("Invalid Piper segment length")
}

/**
 * Speaker index for the requested voice; the default speaker is 0.
 * @param {PiperConfig} config
 * @param {string | undefined} requestedVoice
 * @returns {{speaker: number, voice: string}}
 */
export function speakerFor(config, requestedVoice) {
  const speakers = config.speaker_id_map ?? {}
  const speaker = requestedVoice === undefined ? 0 : speakers[requestedVoice]
  if (!Number.isSafeInteger(speaker) || speaker < 0) throw new Error("Voice is unavailable in the selected model")
  return { speaker, voice: Object.keys(speakers).find((key) => speakers[key] === speaker) ?? String(speaker) }
}

/** @param {unknown} ids @returns {number[]} */
export function validatedPhonemeIds(ids, phonemeError) {
  if (!Array.isArray(ids) || !ids.length || ids.some((id) => !Number.isSafeInteger(id) || id < 0))
    throw new Error(phonemeError ?? "Piper phonemizer returned no valid IDs")
  return ids
}

/** SHA-256 hex of each artifact joined by ":", the revision React records. @param {ArrayBuffer[]} artifacts */
export async function modelRevision(...artifacts) {
  const hashes = []
  for (const bytes of artifacts) {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))
    hashes.push(Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join(""))
  }
  return hashes.join(":")
}
