// Application state of the conversion workspace: the active job, the batch
// queue, the event log and the tab intent. Port of the state the React hooks
// keep (useConversionQueue, useConversionState, useWorkspaceIntents,
// ConversionCache's pending batch). Stimulus controllers subscribe and render;
// they never hold conversion state themselves (ADR 3.2).

import { estimateEtaSeconds } from "runtime/conversion_eta"

/**
 * @typedef {import("./conversion_client.js").ConversionClient} ConversionClient
 * @typedef {import("./conversion_client.js").SubmitRequest} SubmitRequest
 * @typedef {SubmitRequest & {fileName?: string, bookId?: string}} BatchItem
 * @typedef {{at: number, key: string, params?: Record<string, string | number>}} LogEntry
 * @typedef {"setup" | "progress" | "downloads"} Tab
 * @typedef {object} WorkspaceState
 * @property {"idle" | "converting" | "finished" | "failed" | "cancelled"} phase
 * @property {string | undefined} [activeBookId] identity of the source in this page’s book queue
 * @property {string | undefined} activeJobId
 * @property {any} snapshot latest snapshot of the active job
 * @property {{index: number, total: number} | undefined} batchPosition set while a batch of two or more runs
 * @property {BatchItem[]} queue books waiting after the active one
 * @property {boolean} queuePaused
 * @property {LogEntry[]} log
 * @property {Tab} tab
 * @property {boolean} canViewProgress
 * @property {string} [viewedDownloadId] finished job explicitly selected from the library
 * @property {boolean} canViewDownloads
 * @property {{total: number, needsFiles: number} | null} savedBatch batch left by a previous page
 * @property {string | undefined} error submit-time failure shown as an alert
 * @property {import("./conversion_eta.js").EtaReading | undefined} eta latest client estimate (P-27)
 * @property {boolean} cancelling a cancel was requested and the job has not stopped yet
 * @property {number} storedRevision bumped whenever a stored job is removed
 */

export const PENDING_BATCH_KEY = "ebook-tts-pending-batch"
export const LOG_LIMIT = 500

/** @param {string} state */
const phaseFor = (state) =>
  state === "finished" ? "finished" : state === "failed" ? "failed" : state === "cancelled" ? "cancelled" : "converting"

export class ConversionWorkspace {
  /**
   * @param {{client: ConversionClient, storage?: Pick<Storage, "getItem" | "setItem" | "removeItem">, now?: () => number, pollIntervalMs?: number}} dependencies
   */
  constructor({ client, storage, now = () => Date.now(), pollIntervalMs = 100 }) {
    this.client = client
    this.storage = storage
    this.now = now
    this.pollIntervalMs = pollIntervalMs
    /** @type {Set<(state: WorkspaceState) => void>} */
    this.listeners = new Set()
    /** @type {BatchItem[]} */
    this.queue = []
    this.draining = false
    this.paused = false
    this.skipping = false
    this.processed = 0
    /** @type {WorkspaceState} */
    this.state = {
      phase: "idle", activeJobId: undefined, snapshot: undefined, batchPosition: undefined, queue: [], queuePaused: false,
      log: [], tab: "setup", canViewProgress: false, canViewDownloads: false, savedBatch: this.loadSavedBatch(), error: undefined,
      eta: undefined, cancelling: false, storedRevision: 0,
    }
    /** Jobs cancelled from this page; they are deleted once their loop stops (P-24). */
    this.removeWhenCancelled = new Set()
    this.sessionDownloads = new Set()
  }

  /** @param {(state: WorkspaceState) => void} listener */
  subscribe(listener) {
    this.listeners.add(listener)
    listener(this.state)
    return () => { this.listeners.delete(listener) }
  }

  /** @param {Partial<WorkspaceState>} values */
  update(values) {
    this.state = { ...this.state, ...values, queue: [ ...this.queue ], queuePaused: this.paused }
    for (const listener of this.listeners) listener(this.state)
  }

  /** @param {string} key @param {Record<string, string | number>} [params] */
  record(key, params) {
    const log = [ ...this.state.log, { at: this.now(), key, ...(params ? { params } : {}) } ].slice(-LOG_LIMIT)
    this.update({ log })
  }

  /** @param {Tab} tab */
  selectTab(tab) {
    if ((tab === "progress" && !this.state.canViewProgress) || (tab === "downloads" && !this.state.canViewDownloads)) return
    this.update({ tab })
  }

  /** Show stored audio without changing the job being converted or tracked. @param {string} jobId */
  viewDownloads(jobId) {
    this.update({ viewedDownloadId: jobId === this.state.activeJobId ? undefined : jobId, canViewDownloads: true, tab: "downloads" })
  }

  returnToCurrentDownloads() {
    const canViewDownloads = this.state.phase === "finished" || Boolean(this.state.snapshot?.outputs?.length)
    this.update({ viewedDownloadId: undefined, canViewDownloads, tab: canViewDownloads ? "downloads" : "setup" })
  }

  resetConversion() {
    if (this.draining || this.state.phase === "converting") return false
    this.queue = []
    this.paused = false
    this.sessionDownloads.clear()
    this.clearPendingBatch()
    this.update({
      phase: "idle", activeJobId: undefined, activeBookId: undefined, viewedDownloadId: undefined,
      snapshot: undefined, batchPosition: undefined, savedBatch: null, log: [], tab: "setup",
      canViewProgress: false, canViewDownloads: false, eta: undefined, cancelling: false, error: undefined,
    })
    return true
  }

  /** @param {string} jobId */
  publishDownloads(jobId) {
    this.sessionDownloads.add(jobId)
    this.update({ viewedDownloadId: undefined, canViewDownloads: true, tab: "downloads" })
  }

  /**
   * Starts a new batch; the first item runs now, the rest in order (P-16, P-17).
   * @param {BatchItem[]} items
   */
  async submit(items) {
    if (!items.length) return
    this.queue = [ ...items ]
    this.paused = false
    this.processed = 0
    this.savePendingBatch()
    this.update({ savedBatch: null, error: undefined })
    await this.drain()
  }

  /** Adds books to the running batch; they run after the current one. @param {BatchItem[]} items */
  async enqueue(items) {
    if (!items.length) return
    this.queue.push(...items)
    this.update({})
    if (!this.draining && !this.paused) {
      this.processed = 0
      await this.drain()
    }
  }

  async drain() {
    if (this.draining || this.paused) return
    this.draining = true
    try {
      while (this.queue.length > 0 && !this.paused) {
        this.savePendingBatch()
        const item = /** @type {BatchItem} */ (this.queue.shift())
        const index = this.processed + 1
        const total = index + this.queue.length
        this.update({ batchPosition: total > 1 ? { index, total } : undefined })
        const result = await this.run(item)
        if (result === "cancelled") {
          if (this.skipping) {
            this.skipping = false
          } else {
            // A plain cancel pauses the batch and drops the cancelled book.
            this.paused = true
            this.savePendingBatch()
            this.record("batch_cancelled", { remaining: this.queue.length })
            this.update({ tab: "setup" })
            break
          }
        }
        this.processed += 1
      }
    } finally {
      this.draining = false
      if (this.queue.length === 0) {
        this.paused = false
        this.clearPendingBatch()
      }
      this.processed = 0
      this.update({ batchPosition: this.queue.length ? this.state.batchPosition : undefined })
    }
  }

  /**
   * @param {BatchItem} item
   * @returns {Promise<string>} terminal state, or "failed" when the job could not start
   */
  async run(item) {
    let jobId
    try {
      ({ jobId } = await this.client.submit(item))
    } catch (error) {
      const message = String(/** @type {any} */ (error)?.message ?? error)
      this.record("job_rejected", { message })
      this.update({ error: message, phase: this.state.activeJobId ? this.state.phase : "idle" })
      return "failed"
    }
    this.record("job_started", { title: item.document.bookTitle ?? item.fileName ?? "" })
    this.update({
      activeJobId: jobId, activeBookId: item.bookId, snapshot: undefined, viewedDownloadId: undefined, phase: "converting", canViewProgress: true, canViewDownloads: false, tab: "progress", error: undefined,
      eta: undefined, cancelling: false,
    })
    const snapshot = await this.follow(jobId, true)
    if (snapshot.state === "cancelled" && this.removeWhenCancelled.delete(jobId)) await this.removeJob(jobId).catch(() => undefined)
    if (this.state.activeJobId === jobId) {
      if (snapshot.state === "finished") this.publishDownloads(jobId)
      else if (snapshot.state === "cancelled" && !this.skipping) this.update({ tab: "setup" })
    }
    return snapshot.state
  }

  /**
   * Polls one job into the state: flow events, state transitions for the log,
   * phase, and a new ETA reading whenever progress moves (P-27, P-28).
   * @param {string} jobId @param {boolean} logEvents
   */
  follow(jobId, logEvents) {
    const startedAt = this.now()
    let seenEvents = 0
    let lastState = ""
    let lastProgress = -1
    return this.client.poll(jobId, {
      intervalMs: this.pollIntervalMs,
      onSnapshot: (next) => {
        if (this.state.activeJobId !== jobId) return
        if (logEvents) {
          for (const event of (next.events ?? []).slice(seenEvents)) this.record("job_event", { message: event })
          seenEvents = next.events?.length ?? 0
        }
        if (next.state !== lastState) {
          lastState = next.state
          if (logEvents) this.record(`job_${next.state}`, next.error ? { message: next.error } : undefined)
        }
        const progress = next.progressPercent ?? 0
        /** @type {Partial<WorkspaceState>} */
        const values = { snapshot: next, phase: phaseFor(next.state) }
        if (progress !== lastProgress) {
          lastProgress = progress
          const seconds = estimateEtaSeconds(next, startedAt, this.now())
          values.eta = typeof seconds === "number" ? { seconds, at: this.now() } : undefined
        }
        if (values.phase !== "converting") values.cancelling = false
        this.update(values)
      },
    })
  }

  /** Cancels the active job and pauses the batch (P-24). */
  async cancelCurrent() {
    const jobId = this.state.activeJobId
    if (!jobId) return
    this.removeWhenCancelled.add(jobId)
    this.update({ cancelling: true })
    await this.client.cancel(jobId)
  }

  /** Interrupted, failed and cancelled jobs kept in IndexedDB (P-20). */
  resumableJobs() { return this.client.getResumableJobs() }

  /** Deletes a stored job and its audio (P-20). @param {string} jobId */
  async removeJob(jobId) {
    await this.client.removeJob(jobId)
    this.update({ storedRevision: this.state.storedRevision + 1 })
  }

  /** Cancels the active job and continues with the next queued book (P-17). */
  async skipCurrent() {
    const jobId = this.state.activeJobId
    if (!jobId || !this.draining) return
    this.skipping = true
    this.removeWhenCancelled.add(jobId)
    await this.client.cancel(jobId)
  }

  /** Resumes a paused batch. */
  async resumeQueue() {
    if (!this.paused) return
    this.paused = false
    this.update({})
    await this.drain()
  }

  clearQueue() {
    this.queue = []
    this.paused = false
    this.clearPendingBatch()
    this.update({})
  }

  /** @param {number} from @param {number} to */
  reorderQueue(from, to) {
    if (from < 0 || from >= this.queue.length || to < 0 || to >= this.queue.length) return
    const [ item ] = this.queue.splice(from, 1)
    this.queue.splice(to, 0, item)
    this.savePendingBatch()
    this.update({})
  }

  /** Restarts an interrupted, failed or cancelled job and follows it (P-20, P-24). @param {string} jobId */
  async resumeJob(jobId) {
    const { status } = await this.client.resume(jobId)
    if (status !== "queued") return status
    this.record("job_resumed")
    this.update({ activeJobId: jobId, activeBookId: undefined, snapshot: undefined, viewedDownloadId: undefined, phase: "converting", canViewProgress: true, canViewDownloads: false, tab: "progress", eta: undefined, cancelling: false })
    const snapshot = await this.follow(jobId, false)
    if (this.state.activeJobId === jobId && snapshot.state === "finished") this.publishDownloads(jobId)
    return snapshot.state
  }

  /** The saved batch can only be dismissed; its books must be chosen again (ADR Q-07). */
  dismissSavedBatch() {
    this.clearPendingBatch()
    this.update({ savedBatch: null })
  }

  /**
   * The books not yet started (drain saves before taking the next one, so
   * that one is included), without File objects or book text.
   */
  savePendingBatch() {
    const pending = this.queue
    if (!pending.length) return this.clearPendingBatch()
    try {
      this.storage?.setItem(PENDING_BATCH_KEY, JSON.stringify({
        queue: pending.map((item) => ({
          fileName: item.fileName ?? "", bookTitle: item.document?.bookTitle ?? "", chapters: item.chapters ?? "",
          language: item.language ?? "", file: null,
        })),
        savedAt: this.now(),
      }))
    } catch { /* A full or blocked store only loses the reload banner. */ }
  }

  clearPendingBatch() {
    try { this.storage?.removeItem(PENDING_BATCH_KEY) } catch { /* See savePendingBatch. */ }
  }

  /** @returns {{total: number, needsFiles: number} | null} */
  loadSavedBatch() {
    try {
      const parsed = JSON.parse(this.storage?.getItem(PENDING_BATCH_KEY) ?? "null")
      if (!Array.isArray(parsed?.queue) || parsed.queue.length === 0) return null
      return {
        total: parsed.queue.length,
        needsFiles: parsed.queue.filter((/** @type {any} */ item) => !item || typeof item !== "object" || !item.file).length,
      }
    } catch {
      return null
    }
  }
}
