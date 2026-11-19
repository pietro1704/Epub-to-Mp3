// Durable browser job storage. Port of web/src/services/BrowserJobStore.ts.
// The database name, version, store name and key path are shared with the
// React client (ADR 3.4) and must not change while React can be deployed.

export const JOB_DATABASE = "ebook-tts.jobs.v1"
export const JOB_DATABASE_VERSION = 1
export const JOB_OBJECT_STORE = "jobs"

/**
 * @typedef {import("./audio_identity.js").StoredAudio} StoredAudio
 * @typedef {{version: 2, chapter_index: number, text_offset: number}} ListeningPosition
 */
/**
 * @typedef {object} StoredJob
 * @property {string} jobId
 * @property {any} snapshot
 * @property {any} document
 * @property {any} preferences
 * @property {string} language
 * @property {string} [policyState]
 * @property {ListeningPosition} [listeningPosition]
 * @property {StoredAudio[]} audio
 */
/**
 * @typedef {object} JobStore
 * @property {() => Promise<StoredJob[]>} list
 * @property {(job: StoredJob) => Promise<void>} save
 * @property {(jobId: string) => Promise<void>} remove
 */

/**
 * Blobs are immutable and shared; every other field is copied so neither the
 * caller nor a later reader can mutate what was stored.
 * @param {StoredJob} job
 * @returns {StoredJob}
 */
function copyJob(job) {
  return {
    jobId: job.jobId,
    snapshot: structuredClone(job.snapshot),
    document: structuredClone(job.document),
    preferences: structuredClone(job.preferences),
    language: job.language,
    ...(job.listeningPosition ? { listeningPosition: structuredClone(job.listeningPosition) } : {}),
    ...(job.policyState ? { policyState: job.policyState } : {}),
    audio: job.audio.map((audio) => ({
      ...audio,
      blob: audio.blob,
      ...(audio.chunks ? { chunks: structuredClone(audio.chunks) } : {}),
      ...(audio.ttsReceipts ? { ttsReceipts: structuredClone(audio.ttsReceipts) } : {}),
    })),
  }
}

/** @param {unknown} error */
function storageError(error) {
  if (error instanceof Error && error.name === "QuotaExceededError")
    return new Error(
      "Browser audiobook storage quota exceeded. Free space and retry; conversion progress could not be saved.",
      { cause: error })
  return new Error(
    "Browser audiobook storage is unavailable. Enable IndexedDB storage for this site and retry.",
    { cause: error })
}

/**
 * IndexedDB-backed store. A resolved save means the transaction committed.
 * @implements {JobStore}
 */
export class IndexedDBJobStore {
  /** @param {IDBFactory | undefined} [factory] */
  constructor(factory = globalThis.indexedDB) {
    this.factory = factory
    /** @type {Promise<IDBDatabase> | undefined} */
    this.connection = undefined
  }

  /** @returns {Promise<IDBDatabase>} */
  open() {
    this.connection ??= new Promise((resolve, reject) => {
      if (!this.factory) {
        reject(storageError(new Error("IndexedDB is not available")))
        return
      }
      let rejected = false
      /** @type {IDBOpenDBRequest} */
      let request
      try {
        request = this.factory.open(JOB_DATABASE, JOB_DATABASE_VERSION)
      } catch (error) {
        reject(storageError(error))
        return
      }
      request.onupgradeneeded = () => {
        if (!request.result.objectStoreNames.contains(JOB_OBJECT_STORE))
          request.result.createObjectStore(JOB_OBJECT_STORE, { keyPath: "jobId" })
      }
      request.onerror = () => {
        rejected = true
        reject(storageError(request.error))
      }
      request.onblocked = () => {
        rejected = true
        reject(new Error("Browser audiobook storage is blocked by another tab. Close the other tab and retry."))
      }
      request.onsuccess = () => {
        if (rejected) {
          request.result.close()
          return
        }
        const database = request.result
        database.onversionchange = () => {
          database.close()
          this.connection = undefined
        }
        resolve(database)
      }
    }).catch((error) => {
      this.connection = undefined
      throw error
    })
    return /** @type {Promise<IDBDatabase>} */ (this.connection)
  }

  /**
   * @template T
   * @param {IDBTransactionMode} mode
   * @param {(store: IDBObjectStore) => IDBRequest<T>} operation
   * @returns {Promise<T>}
   */
  async transaction(mode, operation) {
    const database = await this.open()
    return new Promise((resolve, reject) => {
      /** @type {IDBTransaction} */
      let transaction
      try {
        transaction = database.transaction(JOB_OBJECT_STORE, mode)
      } catch (error) {
        reject(storageError(error))
        return
      }
      /** @type {T} */
      let result
      transaction.oncomplete = () => resolve(result)
      transaction.onabort = () => reject(storageError(transaction.error))
      transaction.onerror = () => reject(storageError(transaction.error))
      try {
        const request = operation(transaction.objectStore(JOB_OBJECT_STORE))
        request.onsuccess = () => { result = request.result }
        request.onerror = () => reject(storageError(request.error))
      } catch (error) {
        try {
          transaction.abort()
        } catch {
          // The transaction may already be inactive.
        }
        reject(storageError(error))
      }
    })
  }

  async list() {
    const jobs = await this.transaction("readonly", (store) => store.getAll())
    return jobs.map(copyJob)
  }

  /** @param {StoredJob} job */
  async save(job) {
    const immutable = copyJob(job)
    await this.transaction("readwrite", (store) => store.put(immutable))
  }

  /** @param {string} jobId */
  async remove(jobId) {
    await this.transaction("readwrite", (store) => store.delete(jobId))
  }
}

/**
 * Explicit in-memory adapter for tests and the fixture worker; production
 * never falls back to it silently.
 * @implements {JobStore}
 */
export class MemoryJobStore {
  constructor() {
    /** @type {Map<string, StoredJob>} */
    this.jobs = new Map()
  }

  async list() { return [ ...this.jobs.values() ].map(copyJob) }

  /** @param {StoredJob} job */
  async save(job) { this.jobs.set(job.jobId, copyJob(job)) }

  /** @param {string} jobId */
  async remove(jobId) { this.jobs.delete(jobId) }
}
