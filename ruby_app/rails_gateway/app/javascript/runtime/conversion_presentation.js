// Pure text helpers shared by the conversion controllers. Every word comes
// from the strings the server rendered in the request locale
// (ConversionHelper#conversion_strings); this module only fills placeholders.

import { formatEtaDuration, remainingEtaSeconds } from "runtime/conversion_eta"

/**
 * @typedef {import("./conversion_workspace.js").WorkspaceState} WorkspaceState
 * @typedef {import("./conversion_workspace.js").LogEntry} LogEntry
 * @typedef {Record<string, any>} Strings
 */

/** Replaces `{name}` placeholders. @param {string} pattern @param {Record<string, unknown>} [params] */
export function format(pattern, params = {}) {
  return String(pattern ?? "").replace(/\{(\w+)\}/g, (match, name) => (name in params ? String(params[name]) : match))
}

/** Picks the `one` / `other` form of a pluralised entry. @param {string | {one: string, other: string}} entry @param {number} count */
export function plural(entry, count) {
  if (typeof entry === "string") return entry
  return count === 1 ? entry.one : entry.other
}

/**
 * The React phase key of the workspace state, used for status.phases.
 * @param {Pick<WorkspaceState, "phase" | "cancelling">} state
 */
export function phaseKey({ phase, cancelling }) {
  if (cancelling && phase === "converting") return "cancelling"
  return { idle: "idle", converting: "polling", finished: "success", failed: "error", cancelled: "cancelled" }[phase] ?? "idle"
}

/** @param {Strings} strings @param {WorkspaceState} state @param {number} now */
export function etaText(strings, state, now) {
  const key = phaseKey(state)
  if (key === "success") return strings.etaDone
  if (key !== "polling" && key !== "cancelling") return "—"
  const seconds = remainingEtaSeconds(state.eta, now)
  if (typeof seconds !== "number") return strings.etaCalculating
  if (seconds <= 1) return strings.etaSoon
  return `≈ ${formatEtaDuration(seconds)}`
}

/** @param {WorkspaceState} state */
export function progressPercent(state) {
  const snapshot = state.snapshot
  if (typeof snapshot?.progressPercent === "number") return Math.max(0, Math.min(100, snapshot.progressPercent))
  if (snapshot?.chaptersTotal > 0) return Math.max(0, Math.min(100, (100 * (snapshot.chaptersCompleted ?? 0)) / snapshot.chaptersTotal))
  return 0
}

/** @param {Strings} strings @param {WorkspaceState} state */
export function batchText(strings, state) {
  return state.batchPosition ? format(strings.batchPosition, state.batchPosition) : ""
}

/** Error text and category hint of a failed or cancelled job (P-27). @param {Strings} strings @param {WorkspaceState} state */
export function failureText(strings, state) {
  const snapshot = state.snapshot
  if (!snapshot || (snapshot.state !== "failed" && snapshot.state !== "cancelled") || !snapshot.error) return null
  return {
    error: format(strings.errorPrefix, { message: snapshot.error }),
    hint: (snapshot.errorCategory && strings.errorCategoryHints?.[snapshot.errorCategory]) ?? "",
  }
}

/**
 * One event log line: local time and the localised message (P-28).
 * @param {Strings} strings @param {LogEntry} entry @param {string} locale
 */
export function logLine(strings, entry, locale) {
  const time = new Date(entry.at).toLocaleTimeString(locale, { hour: "2-digit", minute: "2-digit", second: "2-digit" })
  const params = entry.params ?? {}
  let pattern = strings.log?.[entry.key]
  if (entry.key === "job_failed" && !params.message) pattern = strings.defaultFailure
  if (pattern && typeof pattern === "object") pattern = plural(pattern, Number(params.remaining ?? params.count ?? 0))
  return `[${time}] ${format(pattern ?? entry.key, params)}`
}
