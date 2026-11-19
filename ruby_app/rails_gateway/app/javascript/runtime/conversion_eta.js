// Client-side ETA of a running job. Port of estimateEtaSeconds,
// estimateWordsBasedEtaSeconds and resolveCurrentCharsPerSecond from
// web/src/hooks/conversion_eta.ts and of the duration part of
// web/src/utils/formatEta.ts. The adaptive health tolerances of that file
// served the HTTP backend only and are not carried over.

/**
 * @typedef {{status?: string, wordCount?: number, chars?: number, charsProcessed?: number, progressRatio?: number, charsPerSecond?: number}} ChapterEntry
 * @typedef {{etaSeconds?: number, progress?: number, progressPercent?: number, chapterProgress?: ChapterEntry[]}} EtaSnapshot
 * @typedef {{seconds: number, at: number}} EtaReading an estimate and the time it was taken
 */

const positive = (/** @type {unknown} */ value) => typeof value === "number" && Number.isFinite(value) && value > 0

/** @param {ChapterEntry[]} entries @returns {number | undefined} */
export function resolveCurrentCharsPerSecond(entries) {
  const inFlight = entries.filter((entry) => (entry.status === "processing" || entry.status === "retrying") && positive(entry.charsPerSecond))
  if (inFlight.length) return inFlight[inFlight.length - 1].charsPerSecond
  const measured = entries.filter((entry) => positive(entry.charsPerSecond))
  return measured.length ? measured[measured.length - 1].charsPerSecond : undefined
}

/** @param {EtaSnapshot} snapshot @returns {number | undefined} */
export function estimateWordsBasedEtaSeconds(snapshot) {
  const entries = snapshot.chapterProgress
  if (!Array.isArray(entries) || entries.length === 0) return undefined
  let totalWords = 0
  let totalChars = 0
  let weightedWords = 0
  for (const entry of entries) {
    if (!positive(entry.wordCount)) continue
    totalWords += /** @type {number} */ (entry.wordCount)
    if (positive(entry.chars)) {
      totalChars += /** @type {number} */ (entry.chars)
      weightedWords += /** @type {number} */ (entry.wordCount)
    }
  }
  if (totalWords <= 0 || totalChars <= 0 || weightedWords <= 0) return undefined
  const charsPerWord = totalChars / weightedWords
  const completedWords = entries.reduce((sum, entry) => {
    const words = positive(entry.wordCount) ? /** @type {number} */ (entry.wordCount) : 0
    if (!words) return sum
    if (entry.status === "completed" || entry.status === "skipped" || entry.status === "cancelled") return sum + words
    if (positive(entry.chars) && positive(entry.charsProcessed))
      return sum + words * Math.max(0, Math.min(1, /** @type {number} */ (entry.charsProcessed) / /** @type {number} */ (entry.chars)))
    if (positive(entry.progressRatio)) return sum + words * Math.min(1, /** @type {number} */ (entry.progressRatio))
    return sum
  }, 0)
  const remainingWords = Math.max(0, totalWords - completedWords)
  if (remainingWords <= 0) return 0
  const cps = resolveCurrentCharsPerSecond(entries)
  if (!positive(cps)) return undefined
  const wordsPerMinute = (/** @type {number} */ (cps) / charsPerWord) * 60
  return positive(wordsPerMinute) ? Math.ceil((remainingWords / wordsPerMinute) * 60) : undefined
}

/**
 * @param {EtaSnapshot} snapshot
 * @param {number | null} startedAt epoch milliseconds when this page started following the job
 * @param {number} [now]
 * @returns {number | undefined}
 */
export function estimateEtaSeconds(snapshot, startedAt, now = Date.now()) {
  const wordsBased = estimateWordsBasedEtaSeconds(snapshot)
  if (typeof snapshot.etaSeconds === "number")
    return typeof wordsBased === "number" ? Math.max(snapshot.etaSeconds, wordsBased) : snapshot.etaSeconds
  if (typeof wordsBased === "number") return wordsBased
  let progress = typeof snapshot.progress === "number" ? snapshot.progress : null
  if (progress === null && typeof snapshot.progressPercent === "number") progress = snapshot.progressPercent / 100
  if (!startedAt || progress === null || progress <= 0 || progress >= 1) return undefined
  const elapsed = (now - startedAt) / 1000
  if (elapsed <= 0) return undefined
  return elapsed * ((1 - progress) / progress)
}

/**
 * The one-second countdown between estimates: the value drops by one each
 * whole second and stops at one, as the React reducer did.
 * @param {EtaReading | undefined} reading
 * @param {number} now
 * @returns {number | undefined}
 */
export function remainingEtaSeconds(reading, now) {
  if (!reading) return undefined
  const seconds = Math.max(0, reading.seconds)
  const elapsed = Math.floor(Math.max(0, now - reading.at) / 1000)
  if (seconds <= 1 || elapsed === 0) return seconds
  return Math.max(1, Math.ceil(seconds) - elapsed)
}

/**
 * Two largest units, as formatEta: `1h 5m`, `42s`. The surrounding words
 * (calculating, almost there, finished) come from the Rails locale.
 * @param {number} seconds
 */
export function formatEtaDuration(seconds) {
  let remainder = Math.max(0, Math.round(seconds))
  const parts = []
  for (const [ label, size ] of /** @type {const} */ ([ [ "d", 86400 ], [ "h", 3600 ], [ "m", 60 ], [ "s", 1 ] ])) {
    const quantity = Math.floor(remainder / size)
    if (quantity > 0) {
      parts.push(`${quantity}${label}`)
      remainder -= quantity * size
    }
    if (parts.length >= 2) break
  }
  return parts.length ? parts.join(" ") : "0s"
}
