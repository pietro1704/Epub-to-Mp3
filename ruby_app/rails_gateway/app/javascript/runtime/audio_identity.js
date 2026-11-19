// Seals stored chapter audio against the exact source text, selection,
// synthesis receipts and bytes, using the Rust cache-identity schema. Port of
// the former React client's BrowserAudioIdentity.ts (removed in the Rails cutover);
// jobs sealed by the former client must keep verifying, so the sealed format
// must stay byte-for-byte identical.

/**
 * @typedef {object} AudioReceipt
 * @property {2} version
 * @property {string} session_id
 * @property {number} source_index
 * @property {number} segment_index
 * @property {{encoding: string}} format
 * @property {{selection: object, runtime_revision: string, artifacts: object, reusable: boolean}} identity
 */
/**
 * @typedef {object} AudioRange
 * @property {number} index
 * @property {string} [text]
 * @property {number} [durationSeconds]
 * @property {number} byteOffset
 * @property {number} byteLength
 */
/**
 * @typedef {object} StoredAudio
 * @property {number} chapterIndex
 * @property {string} name
 * @property {Blob} blob
 * @property {number} [textOffset]
 * @property {AudioRange[]} [chunks]
 * @property {string} [cacheIdentity] IndexedDB v1 integrity seal written by the former React client
 * @property {string} [synthesisCacheIdentity] seal under the producing Rust synthesis profile
 * @property {AudioReceipt[]} [ttsReceipts]
 */
/**
 * @typedef {object} AudioSource
 * @property {object} document
 * @property {{primary: {session?: object}, secondary?: {session?: object} | null}} preferences
 * @property {string} language
 */
/**
 * tts_request_cache_material_v2 from converter-wasm.
 * @typedef {(source: string, language: string, preferences: string, receipts: string) => string} CacheMaterial
 */

/** @param {ArrayBuffer | Uint8Array} value */
async function digest(value) {
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", value))
  return Array.from(hash, (byte) => byte.toString(16).padStart(2, "0")).join("")
}

/**
 * Returns the storage and synthesis seals for the audio, or undefined for legacy audio
 * captured without receipts, which keeps its original contract.
 * @param {AudioSource} source
 * @param {StoredAudio} audio
 * @param {CacheMaterial} cacheMaterial
 * @returns {Promise<{cacheIdentity: string, synthesisCacheIdentity: string} | undefined>}
 */
export async function audioSeals(source, audio, cacheMaterial) {
  const receipts = audio.ttsReceipts
  if (!receipts?.length) return undefined
  const conflicting = receipts.some((receipt, index) =>
    receipt.version !== 2 ||
    receipt.format.encoding !== "mp3" ||
    !receipt.session_id ||
    !receipt.identity.reusable ||
    receipt.source_index !== audio.chapterIndex ||
    (index > 0 && receipt.segment_index !== receipts[index - 1].segment_index + 1))
  if (conflicting) throw new Error("Audio has an opaque or conflicting source identity")
  if (new Set(receipts.map((receipt) => receipt.session_id)).size !== 1)
    throw new Error("Audio mixes retired synthesis sessions")
  const material = cacheMaterial(
    JSON.stringify([ source.document, audio.chapterIndex, audio.textOffset ?? 0, audio.chunks ?? null ]),
    source.language,
    JSON.stringify(source.preferences),
    JSON.stringify(receipts.map((receipt) => JSON.stringify(receipt))),
  )
  // IndexedDB v1 shipped with [2, "text-v1", source, language, preferences, receipts].
  // Rust #1040 added a digital-silence profile between the text schema and the source to
  // invalidate synthesis cache hits. Keep that profile for reuse, and preserve every
  // original serialized byte after the header for readers of the older storage format.
  const storageMaterial = material.replace(/^\[2,"text-v1","digital-silence-[a-zA-Z0-9.-]+",/, '[2,"text-v1",')
  const encoder = new TextEncoder()
  const [profileHash, blobHash] = await Promise.all([digest(encoder.encode(material)), digest(await audio.blob.arrayBuffer())])
  const storageHash = material === storageMaterial ? profileHash : await digest(encoder.encode(storageMaterial))
  return { cacheIdentity: storageHash + ":" + blobHash, synthesisCacheIdentity: profileHash + ":" + blobHash }
}

/**
 * Only a seal for this Rust processing profile permits a resumed synthesis to
 * skip the chapter. A verified pre-profile recording remains playable.
 * @param {AudioSource} source
 * @param {StoredAudio} audio
 * @param {CacheMaterial} cacheMaterial
 * @returns {Promise<boolean | "playback">} false for an invalid artifact
 */
export async function storedAudioUse(source, audio, cacheMaterial) {
  if (!audio.ttsReceipts?.length) {
    const legacy = !audio.cacheIdentity && !audio.synthesisCacheIdentity && !source.preferences.primary.session && !source.preferences.secondary?.session
    return legacy ? "playback" : false
  }
  if (!audio.cacheIdentity) return false
  try {
    const seals = await audioSeals(source, audio, cacheMaterial)
    if (!seals) return false
    if (audio.cacheIdentity !== seals.cacheIdentity && audio.cacheIdentity !== seals.synthesisCacheIdentity) return false
    return (audio.synthesisCacheIdentity ?? audio.cacheIdentity) === seals.synthesisCacheIdentity ? true : "playback"
  } catch {
    return false
  }
}
