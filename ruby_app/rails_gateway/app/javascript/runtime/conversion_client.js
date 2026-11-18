// Browser API and input policy for conversion jobs; Rust owns segment
// planning and audio acceptance. Port of the live half of
// web/src/services/BrowserConversionClient.ts. Books arrive already inspected
// by the book queue, so there is no upload step: the document never leaves
// this page.

import { isTerminal } from "runtime/job_execution"

/**
 * @typedef {import("./job_repository.js").ConversionJob} ConversionJob
 * @typedef {import("./job_repository.js").JobRepository} JobRepository
 * @typedef {import("./job_execution.js").JobExecution} JobExecution
 * @typedef {import("./conversion_runtime.js").ConversionRuntime} ConversionRuntime
 * @typedef {import("./tts_preferences.js").TtsPreferences} TtsPreferences
 * @typedef {{bookTitle?: string, bookAuthor?: string, language?: string, chapters: Array<{name: string, text: string}>}} InspectedBook
 * @typedef {object} SubmitRequest
 * @property {InspectedBook} document inspected by Rust (inspect_epub)
 * @property {string} [chapters] "N" or "N-M", one-based and inclusive
 * @property {string} [language] omitted for "auto"
 * @property {TtsPreferences} [preferences] omitted to use the saved policy
 */

export const CHAPTER_RANGE_FORMAT_ERROR = "Browser chapter selection must be a chapter number or inclusive range, for example 1-2."
export const CHAPTER_RANGE_ERROR = "Invalid chapter range."
export const EDGE_UNAVAILABLE_ERROR = "Edge is unavailable in this browser. Choose a compatible offline audio model without an online secondary voice."

/**
 * Selects the chapters of a one-based inclusive range.
 * @template T
 * @param {T[]} chapters
 * @param {string | undefined} range
 * @returns {T[]}
 */
export function selectChapters(chapters, range) {
  if (!range?.trim()) return chapters
  const match = /^(\d+)(?:-(\d+))?$/.exec(range.trim())
  if (!match) throw new Error(CHAPTER_RANGE_FORMAT_ERROR)
  const start = Number(match[1])
  const end = Number(match[2] ?? match[1])
  if (start < 1 || end < start || end > chapters.length) throw new Error(CHAPTER_RANGE_ERROR)
  return chapters.slice(start - 1, end)
}

export class ConversionClient {
  /**
   * @param {{runtime: ConversionRuntime, repository: JobRepository, execution: JobExecution, loadPreferences: () => TtsPreferences, randomId?: () => string}} dependencies
   */
  constructor({ runtime, repository, execution, loadPreferences, randomId = () => crypto.randomUUID() }) {
    this.runtime = runtime
    this.repository = repository
    this.execution = execution
    this.loadPreferences = loadPreferences
    this.randomId = randomId
  }

  /** @param {SubmitRequest} request @returns {Promise<{jobId: string}>} */
  async submit(request) {
    let preferences = structuredClone(request.preferences ?? this.loadPreferences())
    // A system or Edge primary, or an online secondary, is rejected rather than switched (P-25).
    if (preferences.primary.engine === "system" || preferences.primary.engine === "edge" || preferences.secondary?.engine === "edge")
      throw new Error(EDGE_UNAVAILABLE_ERROR)
    await this.runtime.validateSelection(preferences.primary)
    preferences = await this.runtime.capturePreferences(preferences)
    await this.repository.ensureRestored()
    if (!request.document) throw new Error("Select an EPUB in this browser session.")
    // Same normalisation as the React upload: positional index, UTF-16 length.
    const all = request.document.chapters.map((chapter, index) => ({ ...chapter, index, charCount: chapter.text.length }))
    const chapters = selectChapters(all, request.chapters)
    if (!chapters.some((chapter) => chapter.text.trim())) throw new Error("Selected chapters contain no readable text.")
    const jobId = this.randomId()
    const document = { ...request.document, chapters, jobId }
    const language = request.language || request.document.language || "pt-BR"
    /** @type {ConversionJob} */
    const job = {
      document,
      preferences,
      language,
      audio: new Map(),
      chunks: new Map(),
      done: Promise.resolve(),
      snapshot: {
        jobId,
        state: "queued",
        bookTitle: document.bookTitle,
        bookAuthor: document.bookAuthor,
        chaptersTotal: chapters.length,
        chaptersCompleted: 0,
        progressPercent: 0,
        engine: preferences.primary.engine,
        voice: preferences.primary.model_id ?? preferences.primary.voice ?? undefined,
        outputs: [],
        chapterProgress: chapters.map((chapter) => ({ index: chapter.index, name: chapter.name, chars: chapter.charCount, status: "pending" })),
      },
    }
    await this.repository.commitNew(job)
    this.execution.enqueue(job)
    return { jobId }
  }

  /** @param {string} jobId */
  async fetch(jobId) {
    await this.repository.ensureRestored()
    return structuredClone(this.repository.get(jobId).snapshot)
  }

  /**
   * @param {string} jobId
   * @param {{signal?: AbortSignal, intervalMs?: number, onSnapshot?: (snapshot: any) => void}} [options]
   */
  async poll(jobId, options = {}) {
    for (;;) {
      if (options.signal?.aborted) throw new DOMException("Aborted", "AbortError")
      const snapshot = await this.fetch(jobId)
      options.onSnapshot?.(snapshot)
      if (isTerminal(snapshot.state)) return snapshot
      await new Promise((resolve) => setTimeout(resolve, options.intervalMs ?? 100))
    }
  }

  /**
   * Browser speech is offered only after a provider failure under a policy
   * that allows the system voice (P-36).
   * @param {string} jobId
   * @returns {Promise<{language: string, voice: string | null} | null>}
   */
  async getNativePlaybackPolicy(jobId) {
    await this.repository.ensureRestored()
    const job = this.repository.get(jobId)
    if (job.snapshot.state !== "failed" || job.snapshot.errorCategory !== "tts_provider" ||
      (job.preferences.policy_version !== 2 && job.preferences.secondary?.engine !== "system"))
      return null
    return {
      language: job.language,
      voice: job.preferences.secondary?.engine === "system" ? job.preferences.secondary.voice ?? null : null,
    }
  }

  /** @param {string} jobId */
  async getJobFullText(jobId) {
    await this.repository.ensureRestored()
    return structuredClone(this.repository.get(jobId).document)
  }

  /** @param {string} jobId @param {number} index */
  async getChapterManifest(jobId, index) {
    await this.repository.ensureRestored()
    return structuredClone(this.repository.get(jobId).chunks.get(index) ?? null)
  }

  async getRecentJobs() {
    await this.repository.ensureRestored()
    return [ ...this.repository.all() ].map((job) => ({
      jobId: job.snapshot.jobId,
      state: job.snapshot.state,
      bookTitle: job.snapshot.bookTitle ?? "",
      fileName: "",
      savedAt: job.snapshot.completedAt ?? job.snapshot.startedAt,
      hasOutputs: Boolean(job.snapshot.outputs?.length),
      outputs: structuredClone(job.snapshot.outputs),
    }))
  }

  async getResumableJobs() {
    await this.repository.ensureRestored()
    return [ ...this.repository.all() ]
      .filter((job) => [ "interrupted", "failed", "cancelled" ].includes(job.snapshot.state))
      .map((job) => ({
        jobId: job.snapshot.jobId,
        state: job.snapshot.state,
        bookTitle: job.snapshot.bookTitle ?? "",
        fileName: "",
        savedAt: job.snapshot.startedAt ?? new Date().toISOString(),
        chaptersCompleted: job.audio.size,
        chaptersTotal: job.document.chapters.length,
        engine: job.preferences.primary.engine,
        voice: job.preferences.primary.model_id ?? job.preferences.primary.voice ?? undefined,
        language: job.language,
      }))
  }

  /** @param {string} jobId */
  cancel(jobId) { return this.execution.cancel(jobId) }

  /** @param {string} jobId @param {number} chapter @param {number} [textOffset] */
  listenFrom(jobId, chapter, textOffset = 0) { return this.execution.listenFrom(jobId, chapter, textOffset) }

  /** @param {string} jobId @param {number} chapter @param {number} remaining @param {number} rate */
  playbackFeedback(jobId, chapter, remaining, rate) { return this.execution.playbackFeedback(jobId, chapter, remaining, rate) }

  /** @param {string} jobId */
  resume(jobId) { return this.execution.resume(jobId) }

  /** Cancels, waits for the running loop to let go, then deletes the job. @param {string} jobId */
  async removeJob(jobId) {
    await this.cancel(jobId)
    const job = this.repository.get(jobId)
    await job.done.catch(() => undefined)
    await this.repository.remove(job)
    return { status: "removed" }
  }
}
