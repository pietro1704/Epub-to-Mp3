// Reconciles durable jobs with the live jobs of this page. Port of
// the former React client's BrowserJobRepository.ts (removed in the Rails cutover): restore marks unfinished jobs
// interrupted, rejects audio whose identity or byte ranges no longer hold,
// and rebuilds the object URLs the player and downloads use.

/**
 * @typedef {import("./job_store.js").JobStore} JobStore
 * @typedef {import("./job_store.js").StoredJob} StoredJob
 * @typedef {import("./audio_identity.js").StoredAudio} StoredAudio
 * @typedef {import("./audio_identity.js").AudioRange} AudioRange
 */
/**
 * @typedef {object} StreamChunk
 * @property {number} index
 * @property {string} file
 * @property {string} url
 * @property {string} [text]
 * @property {number} [durationSeconds]
 */
/**
 * @typedef {object} ChapterStreamManifest
 * @property {string} jobId
 * @property {number} chapterIndex
 * @property {string} baseUrl
 * @property {boolean} legacyWholeChapter
 * @property {StreamChunk[]} chunks
 */
/**
 * @typedef {object} ConversionJob
 * @property {any} snapshot
 * @property {any} document
 * @property {any} preferences
 * @property {string} language
 * @property {string} [policyState]
 * @property {import("./job_store.js").ListeningPosition} [listeningPosition]
 * @property {number} [listeningEpoch]
 * @property {Set<number>} [playbackOnlyChapters] verified recordings produced under another processing profile
 * @property {Map<number, StoredAudio>} audio
 * @property {any} [session]
 * @property {Map<number, ChapterStreamManifest>} chunks
 * @property {Promise<void>} done
 */

const UNFINISHED_STATES = [ "running", "queued", "cancelling" ]

/**
 * Ranges must tile the blob exactly, in order, without gaps or empty parts.
 * @param {AudioRange[] | undefined} ranges
 * @param {number} size
 */
function rangesTile(ranges, size) {
  if (!ranges?.length) return true
  const contiguous = ranges.every((range, index) =>
    range.index === index &&
    range.byteLength > 0 &&
    range.byteOffset === (index === 0 ? 0 : ranges[index - 1].byteOffset + ranges[index - 1].byteLength))
  const last = ranges[ranges.length - 1]
  return contiguous && last.byteOffset + last.byteLength === size
}

/** A blank chapter may finish without an MP3. Only require outputs the writer actually recorded.
 * @param {any} snapshot
 * @param {Map<number, StoredAudio>} audio
 */
function missingPromisedAudio(snapshot, audio) {
  if (snapshot.chaptersCompleted > audio.size) return true
  if (snapshot.chapterProgress?.some((/** @type {any} */ chapter) => chapter.status === "completed" && !audio.has(chapter.index))) return true
  const names = new Set(Array.from(audio.values(), artifact => artifact.name))
  return snapshot.outputs?.some((/** @type {any} */ output) => !names.has(output.name)) ?? false
}

export class JobRepository {
  /**
   * @param {JobStore} store
   * @param {(saved: StoredJob, audio: StoredAudio) => Promise<boolean | "playback">} audioUse
   */
  constructor(store, audioUse) {
    this.store = store
    this.audioUse = audioUse
    /** @type {Map<string, ConversionJob>} */
    this.jobs = new Map()
    /** @type {Promise<void> | undefined} */
    this.restored = undefined
  }

  ensureRestored() {
    this.restored ??= this.restore()
    return this.restored
  }

  async restore() {
    for (const saved of await this.store.list()) {
      const snapshot = structuredClone(saved.snapshot)
      if (UNFINISHED_STATES.includes(snapshot.state)) snapshot.state = "interrupted"
      snapshot.outputs = []
      /** @type {ConversionJob} */
      const job = {
        snapshot,
        document: saved.document,
        preferences: saved.preferences,
        language: saved.language,
        policyState: saved.policyState,
        listeningPosition: saved.listeningPosition,
        audio: new Map(),
        chunks: new Map(),
        done: Promise.resolve(),
      }
      for (const artifact of saved.audio) {
        const use = await this.audioUse(saved, artifact)
        if (!use || !rangesTile(artifact.chunks, artifact.blob.size)) {
          snapshot.state = "interrupted"
          continue
        }
        if (use === "playback") (job.playbackOnlyChapters ??= new Set()).add(artifact.chapterIndex)
        this.restoreAudio(saved, job, artifact)
      }
      if (snapshot.state === "finished" && missingPromisedAudio(saved.snapshot, job.audio)) snapshot.state = "interrupted"
      snapshot.chaptersCompleted = job.audio.size
      snapshot.chapterProgress = snapshot.chapterProgress?.map((/** @type {any} */ chapter) => ({
        ...chapter,
        status: job.audio.has(chapter.index) ? "completed" : "pending",
        downloadUrl: snapshot.outputs.find((/** @type {any} */ output) => output.name === `chapter-${chapter.index + 1}.mp3`)?.url,
      }))
      this.jobs.set(saved.jobId, job)
      if (snapshot.state !== saved.snapshot.state) await this.persist(job)
    }
  }

  /**
   * @param {StoredJob} saved
   * @param {ConversionJob} job
   * @param {StoredAudio} artifact
   */
  restoreAudio(saved, job, artifact) {
    const ranges = artifact.chunks
    job.audio.set(artifact.chapterIndex, artifact)
    const url = URL.createObjectURL(artifact.blob)
    job.snapshot.outputs.push({ name: artifact.name, url, sizeBytes: artifact.blob.size })
    const chapterText = saved.document.chapters.find((/** @type {any} */ chapter) => chapter.index === artifact.chapterIndex)?.text ?? ""
    job.chunks.set(artifact.chapterIndex, {
      jobId: saved.jobId,
      chapterIndex: artifact.chapterIndex,
      baseUrl: "",
      legacyWholeChapter: !ranges?.length,
      chunks: ranges?.length
        ? ranges.map((range) => ({
          index: range.index,
          file: `${range.index}.mp3`,
          text: range.text,
          durationSeconds: range.durationSeconds,
          url: URL.createObjectURL(artifact.blob.slice(range.byteOffset, range.byteOffset + range.byteLength, "audio/mpeg")),
        }))
        // Offsets count code points, as React's Array.from(text) does.
        : [ { index: 0, file: artifact.name, url, text: Array.from(chapterText).slice(artifact.textOffset ?? 0).join("") } ],
    })
  }

  /**
   * Writes the job without page-local object URLs.
   * @param {ConversionJob} job
   * @param {object} [committedState] snapshot fields to store in place of the live ones
   */
  persist(job, committedState = {}) {
    const snapshot = { ...structuredClone(job.snapshot), ...committedState }
    snapshot.outputs = snapshot.outputs?.map((/** @type {any} */ output) => ({ ...output, url: "" }))
    snapshot.chapterProgress = snapshot.chapterProgress?.map((/** @type {any} */ chapter) => ({ ...chapter, downloadUrl: undefined }))
    return this.store.save({
      jobId: snapshot.jobId,
      snapshot,
      document: structuredClone(job.document),
      preferences: structuredClone(job.preferences),
      language: job.language,
      ...(job.listeningPosition ? { listeningPosition: structuredClone(job.listeningPosition) } : {}),
      ...(job.policyState ? { policyState: job.policyState } : {}),
      audio: [ ...job.audio.values() ],
    })
  }

  /** @param {string} id */
  get(id) {
    const job = this.jobs.get(id)
    if (!job) throw new Error("Browser job not found.")
    return job
  }

  all() { return this.jobs.values() }

  /** Stored first, so a job is never live without being durable. @param {ConversionJob} job */
  async commitNew(job) {
    await this.persist(job)
    this.jobs.set(job.snapshot.jobId, job)
  }

  /** @param {ConversionJob} job */
  async remove(job) {
    await this.store.remove(job.snapshot.jobId)
    for (const output of job.snapshot.outputs ?? []) URL.revokeObjectURL(output.url)
    for (const manifest of job.chunks.values())
      for (const chunk of manifest.chunks) URL.revokeObjectURL(chunk.url)
    this.jobs.delete(job.snapshot.jobId)
  }
}
