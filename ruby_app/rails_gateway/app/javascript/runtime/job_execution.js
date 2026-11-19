// Runs browser jobs one at a time against the Rust ConversionSession. Port of
// the former React client's BrowserJobExecution.ts (removed in the Rails cutover): owns the serial runtime lease,
// receipt and byte-range bookkeeping, publication ordering (audio is durable
// before a chapter is advertised), cancellation, resume and the listening
// position that steers synthesis (P-24, P-25, P-35).

import { TtsPreparationError } from "runtime/conversion_runtime"

/**
 * @typedef {import("./job_repository.js").ConversionJob} ConversionJob
 * @typedef {import("./job_repository.js").JobRepository} JobRepository
 * @typedef {import("./conversion_runtime.js").ConversionRuntime} ConversionRuntime
 * @typedef {import("./conversion_runtime.js").Synthesis} Synthesis
 * @typedef {import("./audio_identity.js").StoredAudio} StoredAudio
 * @typedef {import("./audio_identity.js").AudioRange} AudioRange
 * @typedef {object} Segment
 * @property {string} [session_id]
 * @property {number} chapter
 * @property {number} index
 * @property {number} total
 * @property {string} text
 * @property {import("./tts_catalog.js").TtsSelection} selection
 * @property {boolean} fallback_used
 */

export const TERMINAL_STATES = Object.freeze([ "finished", "failed", "cancelled", "interrupted" ])
/** @param {string} state */
export const isTerminal = (state) => TERMINAL_STATES.includes(state)
/** @param {ConversionJob} job */
const isCancelled = (job) => job.snapshot.state === "cancelled"

const WAITING_POLL_MS = 100

export class JobExecution {
  /**
   * @param {{runtime: ConversionRuntime, repository: JobRepository, seal: (job: ConversionJob, audio: StoredAudio) => Promise<{cacheIdentity: string, synthesisCacheIdentity: string} | undefined>, clock?: () => number}} dependencies
   */
  constructor({ runtime, repository, seal, clock = () => performance.now() }) {
    this.runtime = runtime
    this.repository = repository
    this.seal = seal
    this.clock = clock
    /** @type {Promise<void>} */
    this.queue = Promise.resolve()
  }

  /** @param {ConversionJob} job */
  enqueue(job) {
    job.done = this.queue.then(() => this.execute(job))
    this.queue = job.done.catch(() => undefined)
  }

  /** @param {ConversionJob} job */
  async execute(job) {
    if (isCancelled(job)) return
    const { preferences, language } = job
    try {
      // Keep every source chapter addressable if a running job becomes listening.
      job.session = job.policyState
        ? await this.runtime.create(job.document.chapters, preferences, language, job.policyState)
        : await this.runtime.create(job.document.chapters, preferences, language)
      if (isCancelled(job)) {
        job.session.cancel()
        return
      }
      if (job.listeningPosition) {
        if (!job.session.set_listening_position_json_v2) throw new Error("The converter lacks version 2 listening control")
        job.session.set_listening_position_json_v2(JSON.stringify(job.listeningPosition))
      }
      job.snapshot.state = "running"
      job.snapshot.startedAt = new Date().toISOString()
      await this.repository.persist(job)
      /** @type {Map<number, object[]>} */
      const receipts = new Map()
      /** @type {Map<number, AudioRange[]>} */
      const ranges = new Map()
      let receiptEpoch = job.listeningEpoch
      for (;;) {
        if (receiptEpoch !== job.listeningEpoch) {
          receipts.clear()
          ranges.clear()
          receiptEpoch = job.listeningEpoch
        }
        /** @type {Segment | {waiting: true} | null} */
        const next = JSON.parse(job.session.next_segment())
        if (!next) {
          const finishingEpoch = job.listeningEpoch
          const completedAt = new Date().toISOString()
          await this.repository.persist(job, { state: "finished", completedAt })
          if (isCancelled(job)) return
          if (finishingEpoch !== job.listeningEpoch) {
            await this.repository.persist(job)
            continue
          }
          job.snapshot.state = "finished"
          job.snapshot.completedAt = completedAt
          return
        }
        if (isCancelled(job)) return
        if ("waiting" in next) {
          await new Promise((resolve) => setTimeout(resolve, WAITING_POLL_MS))
          continue
        }
        const segment = next
        const expectedOffset = job.listeningPosition?.chapter_index === segment.chapter ? job.listeningPosition.text_offset : 0
        if (job.audio.has(segment.chapter) && (job.audio.get(segment.chapter)?.textOffset ?? 0) !== expectedOffset)
          this.retireAudio(job, segment.chapter)
        if (job.audio.has(segment.chapter) && job.session.skip_cached_chapter_v2) {
          job.session.skip_cached_chapter_v2(segment.chapter)
          continue
        }
        const epoch = job.listeningEpoch
        const started = this.clock()
        /** @type {Uint8Array | Synthesis} */
        let synthesis
        try {
          synthesis = await this.runtime.synthesize(segment.text, segment.selection)
        } catch (primaryError) {
          if (isCancelled(job)) return
          if (epoch !== job.listeningEpoch) continue
          // A system secondary is listening-only. Mark only terminal provider errors:
          // a successful secondary must not affect the category of a later storage failure.
          if (!preferences.secondary || preferences.secondary.engine === "system") {
            job.snapshot.errorCategory = "tts_provider"
            throw primaryError
          }
          try {
            job.session.provider_failed()
          } catch (policyError) {
            job.snapshot.errorCategory = "tts_provider"
            throw new Error(`${String(primaryError)}; ${String(policyError)}`, { cause: policyError })
          }
          /** @type {Segment} */
          const fallback = JSON.parse(job.session.next_segment())
          try {
            synthesis = await this.runtime.synthesize(fallback.text, fallback.selection)
          } catch (fallbackError) {
            if (isCancelled(job)) return
            if (epoch !== job.listeningEpoch) continue
            job.snapshot.errorCategory = "tts_provider"
            throw fallbackError
          }
          job.snapshot.events = [ ...(job.snapshot.events ?? []), `Secondary voice: ${fallback.selection.engine}` ]
        }
        if (isCancelled(job)) return
        if (epoch !== job.listeningEpoch) continue
        job.session.observe_generation_v2?.((this.clock() - started) / 1000, Array.from(segment.text).length)
        const mp3 = synthesis instanceof Uint8Array ? synthesis : synthesis.audio
        const receipt = synthesis instanceof Uint8Array ? undefined : {
          version: 2,
          session_id: segment.session_id ?? "",
          source_index: segment.chapter,
          segment_index: segment.index,
          format: synthesis.format,
          identity: synthesis.identity,
        }
        let complete
        if (receipt) {
          if (!job.session.accept_audio_v2) throw new Error("The embedded converter lacks version 2 audio receipts")
          complete = job.session.accept_audio_v2(mp3, JSON.stringify(receipt))
          receipts.set(segment.chapter, [ ...(receipts.get(segment.chapter) ?? []), receipt ])
        } else {
          complete = job.session.accept_audio(mp3)
        }
        job.policyState = job.session.policy_state_json?.()
        const manifest = job.chunks.get(segment.chapter) ?? {
          jobId: job.snapshot.jobId, chapterIndex: segment.chapter, baseUrl: "", legacyWholeChapter: false, chunks: [],
        }
        manifest.chunks.push({
          durationSeconds: job.session.audio_duration_seconds_v2?.(mp3),
          index: manifest.chunks.length,
          file: `${segment.index}.mp3`,
          url: URL.createObjectURL(new Blob([ mp3.slice().buffer ], { type: "audio/mpeg" })),
          text: segment.text,
        })
        job.chunks.set(segment.chapter, manifest)
        const chapterRanges = ranges.get(segment.chapter) ?? []
        const previousRange = chapterRanges.at(-1)
        chapterRanges.push({
          index: manifest.chunks.length - 1,
          text: segment.text,
          durationSeconds: manifest.chunks.at(-1)?.durationSeconds,
          byteOffset: previousRange ? previousRange.byteOffset + previousRange.byteLength : 0,
          byteLength: mp3.length,
        })
        ranges.set(segment.chapter, chapterRanges)
        job.snapshot.completedSegments = segment.index + 1
        job.snapshot.totalSegments = segment.total
        job.snapshot.progressPercent = (100 * (segment.index + 1)) / segment.total
        const chapter = job.snapshot.chapterProgress?.find((/** @type {any} */ entry) => entry.index === segment.chapter)
        if (chapter) chapter.status = complete ? "completed" : "processing"
        if (!complete) continue
        const audio = job.session.chapter_audio()
        const blob = new Blob([ audio.slice().buffer ], { type: "audio/mpeg" })
        const name = `chapter-${segment.chapter + 1}.mp3`
        /** @type {StoredAudio} */
        const artifact = {
          chunks: structuredClone(chapterRanges),
          textOffset: expectedOffsetFor(job, segment.chapter),
          chapterIndex: segment.chapter,
          name,
          blob,
          ...(receipts.has(segment.chapter) ? { ttsReceipts: receipts.get(segment.chapter) } : {}),
        }
        const seals = await this.seal(job, artifact)
        if (isCancelled(job)) return
        if (epoch !== job.listeningEpoch) continue
        job.audio.set(segment.chapter, { ...artifact, ...seals })
        // Commit completed audio and its identity before advertising the chapter.
        await this.repository.persist(job)
        if (isCancelled(job)) return
        if (epoch !== job.listeningEpoch) continue
        const output = URL.createObjectURL(blob)
        if (chapter) chapter.downloadUrl = output
        job.snapshot.outputs?.push({ name, url: output, sizeBytes: audio.length })
        job.snapshot.chaptersCompleted = (job.snapshot.chaptersCompleted ?? 0) + 1
        await this.repository.persist(job)
      }
    } catch (error) {
      if (!isCancelled(job)) {
        if (error instanceof TtsPreparationError) job.snapshot.errorCategory = "tts_provider"
        job.snapshot.state = "failed"
        job.snapshot.error = String(error)
      }
      try {
        await this.repository.persist(job)
      } catch (storageFailure) {
        job.snapshot.errorCategory = undefined
        job.snapshot.error = String(storageFailure)
      }
    } finally {
      job.session?.free?.()
      job.session = undefined
    }
  }

  /** @param {string} jobId */
  async cancel(jobId) {
    await this.repository.ensureRestored()
    const job = this.repository.get(jobId)
    if (isTerminal(job.snapshot.state)) return { status: job.snapshot.state }
    const active = job.snapshot.state === "running"
    job.snapshot.state = "cancelled"
    job.session?.cancel()
    if (active) this.runtime.cancelSynthesis?.()
    await this.repository.persist(job)
    return { status: "cancelled" }
  }

  /**
   * Makes the heard chapter (and text offset) the next one synthesised.
   * @param {string} jobId
   * @param {number} chapter
   * @param {number} [textOffset] in code points
   */
  async listenFrom(jobId, chapter, textOffset = 0) {
    await this.repository.ensureRestored()
    const job = this.repository.get(jobId)
    const source = job.document.chapters.find((/** @type {any} */ candidate) => candidate.index === chapter)
    if (!source || !Number.isSafeInteger(textOffset) || textOffset < 0 || textOffset >= Array.from(source.text).length)
      throw new Error("Invalid listening text position")
    if (job.audio.has(chapter) && (job.audio.get(chapter)?.textOffset ?? 0) === textOffset && !job.listeningPosition) return
    const position = { version: 2, chapter_index: chapter, text_offset: textOffset }
    if (job.session) {
      if (!job.session.set_listening_position_json_v2) throw new Error("The converter lacks version 2 listening control")
      job.session.set_listening_position_json_v2(JSON.stringify(position))
    }
    job.listeningPosition = position
    job.listeningEpoch = (job.listeningEpoch ?? 0) + 1
    for (const [ index, artifact ] of job.audio) {
      if ((artifact.textOffset ?? 0) !== (index === chapter ? textOffset : 0)) this.retireAudio(job, index)
    }
    for (const [ index, manifest ] of job.chunks) {
      if (job.audio.has(index)) continue
      for (const chunk of manifest.chunks) URL.revokeObjectURL(chunk.url)
      job.chunks.delete(index)
    }
    if (job.snapshot.state === "running") this.runtime.cancelSynthesis?.()
    await this.repository.persist(job)
    if (job.snapshot.state === "finished") job.snapshot.state = "interrupted"
    if (isTerminal(job.snapshot.state)) await this.resume(jobId)
  }

  /**
   * @param {ConversionJob} job
   * @param {number} chapter
   */
  retireAudio(job, chapter) {
    job.audio.delete(chapter)
    job.snapshot.outputs = job.snapshot.outputs?.filter((/** @type {any} */ output) => {
      if (output.name !== `chapter-${chapter + 1}.mp3`) return true
      URL.revokeObjectURL(output.url)
      return false
    })
    for (const chunk of job.chunks.get(chapter)?.chunks ?? []) URL.revokeObjectURL(chunk.url)
    job.chunks.delete(chapter)
    const state = job.snapshot.chapterProgress?.find((/** @type {any} */ entry) => entry.index === chapter)
    if (state) {
      state.status = "pending"
      state.downloadUrl = undefined
    }
    job.snapshot.chaptersCompleted = job.audio.size
  }

  /**
   * Feeds the remaining buffered audio of the heard chapter back to Rust.
   * @param {string} jobId
   * @param {number} chapter
   * @param {number} remaining seconds
   * @param {number} rate
   */
  async playbackFeedback(jobId, chapter, remaining, rate) {
    await this.repository.ensureRestored()
    const job = this.repository.get(jobId)
    if (!job.listeningPosition || !job.session?.playback_feedback_json_v2) return
    if (job.listeningPosition.chapter_index !== chapter) return
    const generation = Number(job.session.listening_generation_v2?.() ?? 0)
    job.session.playback_feedback_json_v2(JSON.stringify({
      version: 2, generation, chapter_index: chapter, remaining_audio_seconds: remaining, playback_rate: rate,
    }))
  }

  /** @param {string} jobId */
  async resume(jobId) {
    await this.repository.ensureRestored()
    const job = this.repository.get(jobId)
    if (job.snapshot.state === "finished") return { status: "finished" }
    if (!isTerminal(job.snapshot.state)) return { status: job.snapshot.state }
    await job.done.catch(() => undefined)
    for (const chapter of job.playbackOnlyChapters ?? []) this.retireAudio(job, chapter)
    job.playbackOnlyChapters?.clear()
    for (const [ chapter, manifest ] of job.chunks) {
      if (job.audio.has(chapter)) continue
      for (const chunk of manifest.chunks) URL.revokeObjectURL(chunk.url)
      job.chunks.delete(chapter)
    }
    Object.assign(job.snapshot, {
      state: "queued", error: undefined, errorCategory: undefined, completedAt: undefined,
      completedSegments: 0, totalSegments: undefined,
    })
    job.snapshot.chapterProgress = job.snapshot.chapterProgress?.map((/** @type {any} */ chapter) => ({
      ...chapter, status: job.audio.has(chapter.index) ? "completed" : "pending",
    }))
    await this.repository.persist(job)
    this.enqueue(job)
    return { status: "queued" }
  }
}

/**
 * @param {ConversionJob} job
 * @param {number} chapter
 */
function expectedOffsetFor(job, chapter) {
  return job.listeningPosition?.chapter_index === chapter ? job.listeningPosition.text_offset : 0
}
