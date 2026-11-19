// Page-side client of the Piper module worker. Port of
// the former React client's BrowserPiper.ts (removed in the Rails cutover): one segment at a time, a deadline per
// segment, and cancellation by terminating the worker so no late callback
// from a retired worker can resolve a newer request. The worker speaks the
// version 2 message contract shared with the React worker.

export const DEFAULT_PIPER_MODEL = "pt_BR-faber-medium"
export const PIPER_DEADLINE_MS = 120_000

/**
 * @typedef {object} PiperSynthesis
 * @property {Uint8Array} audio MP3 bytes
 * @property {string} modelRevision
 * @property {string} voice
 */
/**
 * @typedef {object} PiperReply
 * @property {number} [version]
 * @property {number} [requestId]
 * @property {string} [modelId]
 * @property {string} [format]
 * @property {ArrayBuffer} [audio]
 * @property {string} [error]
 * @property {{modelRevision: string, voice: string}} [receipt]
 */

export class PiperClient {
  /**
   * @param {() => Worker} createWorker
   * @param {{deadlineMs?: number}} [options]
   */
  constructor(createWorker, { deadlineMs = PIPER_DEADLINE_MS } = {}) {
    this.createWorker = createWorker
    this.deadlineMs = deadlineMs
    /** @type {Worker | undefined} */
    this.worker = undefined
    this.sequence = 0
    /** @type {{requestId: number, modelId: string, modelRevision?: string, timer: ReturnType<typeof setTimeout>, resolve: (value: PiperSynthesis) => void, reject: (error: Error) => void} | undefined} */
    this.pending = undefined
  }

  /**
   * @param {string} text
   * @param {string} [modelId]
   * @param {string} [modelRevision] when set, the reply must carry the same revision
   * @param {string} [voice]
   * @returns {Promise<PiperSynthesis>}
   */
  synthesize(text, modelId = DEFAULT_PIPER_MODEL, modelRevision, voice) {
    if (this.pending) return Promise.reject(new Error("A Piper segment is already active."))
    const worker = this.worker ??= this.startWorker()
    return new Promise((resolve, reject) => {
      const requestId = ++this.sequence
      const timer = setTimeout(() => {
        if (this.pending?.requestId === requestId) this.cancel(new Error("Piper synthesis deadline exceeded."))
      }, this.deadlineMs)
      this.pending = { requestId, modelId, modelRevision, timer, resolve, reject }
      try {
        worker.postMessage({ version: 2, requestId, text, modelId, modelRevision, voice })
      } catch (error) {
        this.cancel(error instanceof Error ? error : new Error(String(error)))
      }
    })
  }

  /** Terminates the worker and rejects the active segment, if any. */
  cancel(error = new Error("Piper synthesis cancelled.")) {
    this.worker?.terminate()
    this.worker = undefined
    const request = this.pending
    this.pending = undefined
    if (request) {
      clearTimeout(request.timer)
      request.reject(error)
    }
  }

  /** @returns {Worker} */
  startWorker() {
    const worker = this.createWorker()
    worker.onmessage = ({ data }) => this.receive(worker, data)
    worker.onerror = ({ message }) => {
      if (this.worker === worker) this.cancel(new Error(message))
    }
    return worker
  }

  /**
   * @param {Worker} worker
   * @param {PiperReply} data
   */
  receive(worker, data) {
    const request = this.pending
    if (this.worker !== worker || !request || data.requestId !== request.requestId) return
    clearTimeout(request.timer)
    this.pending = undefined
    const declared = data.version === 2 && data.format === "mp3" && data.audio && data.modelId === request.modelId &&
      (!request.modelRevision || data.receipt?.modelRevision === request.modelRevision)
    if (declared && data.audio) {
      request.resolve({ audio: new Uint8Array(data.audio), modelRevision: data.receipt?.modelRevision ?? "", voice: data.receipt?.voice ?? "0" })
      return
    }
    // A worker that answered outside the contract is not trusted again.
    this.worker?.terminate()
    this.worker = undefined
    request.reject(new Error(data.error ?? "Piper returned no audio with the requested identity."))
  }
}
