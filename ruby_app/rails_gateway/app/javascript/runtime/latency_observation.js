// Local-only, bounded timing diagnostics of reader-open, progressive-playback
// and seek journeys (P-44). Port of web/src/services/LatencyObservation.ts
// with the same vocabulary and JSON shape, so evidence from both clients can
// be compared. No job id, text, account, URL or other listener data is kept.

/**
 * @typedef {"reader_open" | "progressive_playback" | "seek"} LatencyJourneyKind
 * @typedef {"open_requested" | "readable_content" | "controls_usable" | "first_pdf_page" | "play_requested" | "audio_queued" |
 *   "audio_playable" | "audio_audible" | "seek_requested" | "seek_target_reached" | "cancelled"} LatencyTransition
 * @typedef {"cold" | "warm" | "unknown"} LatencyCacheState
 * @typedef {"foreground_priority" | "conversion_active" | "unknown"} LatencyResourcePolicy
 * @typedef {{id: string, kind: LatencyJourneyKind, cacheState: LatencyCacheState, resourcePolicy: LatencyResourcePolicy,
 *   records: Array<{transition: LatencyTransition, elapsedMs: number}>, terminal: boolean}} LatencyObservation
 */

const makeId = () => globalThis.crypto?.randomUUID?.() ?? `journey-${Math.random().toString(36).slice(2)}-${Date.now()}`

const INITIAL = Object.freeze({ reader_open: "open_requested", progressive_playback: "play_requested", seek: "seek_requested" })

export class LatencyObservationStore {
  /** @param {() => number} [now] @param {number} [capacity] */
  constructor(now = () => performance.now(), capacity = 200) {
    this.now = now
    this.capacity = Math.max(1, capacity)
    /** @type {Map<string, {startedAt: number, observation: LatencyObservation}>} */
    this.active = new Map()
    /** @type {string[]} */
    this.order = []
  }

  /**
   * @param {LatencyJourneyKind} kind @param {LatencyTransition} initial
   * @param {{cacheState?: LatencyCacheState, resourcePolicy?: LatencyResourcePolicy}} [options]
   * @returns {string} the journey id, or "" for an invalid start
   */
  begin(kind, initial, options = {}) {
    if (INITIAL[kind] !== initial) return ""
    const id = makeId()
    this.active.set(id, {
      startedAt: this.now(),
      observation: {
        id, kind, cacheState: options.cacheState ?? "unknown", resourcePolicy: options.resourcePolicy ?? "unknown",
        records: [ { transition: initial, elapsedMs: 0 } ], terminal: false,
      },
    })
    this.order.push(id)
    while (this.order.length > this.capacity) this.active.delete(/** @type {string} */ (this.order.shift()))
    return id
  }

  /** @param {string} id @param {LatencyTransition} transition */
  record(id, transition) {
    const active = this.active.get(id)
    if (!active || active.observation.terminal || transition === "cancelled") return false
    const records = active.observation.records
    if (records.at(-1)?.transition === transition || !this.isValidTransition(active.observation, transition)) return false
    records.push({ transition, elapsedMs: Math.max(0, this.now() - active.startedAt) })
    return true
  }

  /** @param {string} id */
  finish(id) {
    const active = this.active.get(id)
    if (active) active.observation.terminal = true
  }

  /** @param {string} id */
  cancel(id) {
    const active = this.active.get(id)
    if (!active || active.observation.terminal) return
    active.observation.records.push({ transition: "cancelled", elapsedMs: Math.max(0, this.now() - active.startedAt) })
    active.observation.terminal = true
  }

  /** @returns {LatencyObservation[]} */
  snapshot() {
    return this.order.flatMap((id) => {
      const observation = this.active.get(id)?.observation
      return observation ? [ { ...observation, records: [ ...observation.records ] } ] : []
    })
  }

  /** @param {LatencyObservation} observation @param {LatencyTransition} transition */
  isValidTransition(observation, transition) {
    const recorded = new Set(observation.records.map((record) => record.transition))
    switch (observation.kind) {
      case "reader_open":
        return [ "readable_content", "controls_usable", "first_pdf_page" ].includes(transition) && !recorded.has(transition)
      case "progressive_playback":
        if (transition === "audio_queued") return !recorded.has("audio_queued") && !recorded.has("audio_playable")
        if (transition === "audio_playable") return recorded.has("audio_queued") && !recorded.has("audio_audible")
        if (transition === "audio_audible") return recorded.has("audio_playable") && !recorded.has("audio_audible")
        return false
      case "seek":
        return transition === "seek_target_reached" && !recorded.has("seek_target_reached")
      default:
        return false
    }
  }
}

/** The page-wide store; memory only, lost on reload as in the React client. */
export const latencyObservations = new LatencyObservationStore()

/** Stable JSON export for a user-triggered, controlled-browser evidence run. @param {LatencyObservation[]} observations */
export function serializeLatencyEvidence(observations) {
  return JSON.stringify({ schemaVersion: 1, observations }, null, 2)
}

/** Saves the evidence as a file without the File System Access API. */
export function downloadLatencyEvidence(observations = latencyObservations.snapshot(), filename = "latency-evidence.json") {
  const url = URL.createObjectURL(new Blob([ serializeLatencyEvidence(observations) ], { type: "application/json" }))
  const anchor = document.createElement("a")
  anchor.href = url
  anchor.download = filename
  anchor.click()
  URL.revokeObjectURL(url)
}
