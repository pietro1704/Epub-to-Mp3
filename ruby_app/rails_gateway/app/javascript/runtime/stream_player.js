// Sequential playback of the exact Rust-produced segment requested by the listener.
// An outstanding manifest, playback promise or timer belongs to one position.
const RATE_KEY = "epub-to-mp3:player-speed"
const RATES = [ 0.75, 1, 1.25, 1.5, 2 ]
const positionKey = jobId => "epub-to-mp3:player-pos:" + jobId

export class StreamPlayer {
  constructor({ client, audio, storage, latency, render, publish, interval = 300 }) {
    Object.assign(this, { client, audio, storage, latency, render, publish, interval })
    this.chapters = []
    this.started = false
    this.generation = 0
    this.rate = 1
    try { this.rate = Number(storage?.getItem(RATE_KEY)) } catch { /* Storage is optional. */ }
    if (!RATES.includes(this.rate)) this.rate = 1
    this.resetSegment()
  }

  update(jobId, snapshot) {
    if (jobId !== this.jobId) {
      this.stop()
      this.jobId = jobId
    }
    this.snapshot = snapshot
    this.chapters = snapshot?.chapterProgress ?? []
    if (this.started && [ "cancelled", "interrupted" ].includes(snapshot?.state)) this.stop()
    this.render()
  }

  start() {
    if (this.started || !this.chapters.length) return
    let chapter = this.chapters[0].index
    let segment = 0
    try {
      const saved = JSON.parse(this.storage?.getItem(positionKey(this.jobId)) ?? "null")
      if (saved && this.chapters.some(entry => entry.index === saved.chapterIndex) &&
          Number.isSafeInteger(saved.segmentIndex) && saved.segmentIndex >= 0) {
        chapter = saved.chapterIndex
        segment = saved.segmentIndex
      }
    } catch { /* An invalid bookmark starts at the first chapter. */ }
    this.started = true
    this.playJourney = this.latency.begin("progressive_playback", "play_requested")
    this.select(chapter, segment, true)
  }

  jump(chapter) {
    if (!this.started || !this.chapters.some(entry => entry.index === chapter)) return
    this.latency.cancel(this.seekJourney)
    this.seekJourney = this.latency.begin("seek", "seek_requested")
    this.select(chapter, 0, true)
  }

  neighbor(delta) {
    const index = this.chapters.findIndex(entry => entry.index === this.chapter)
    return this.chapters[index + delta]
  }

  setRate(rate) {
    if (!RATES.includes(rate)) return
    this.rate = this.audio.playbackRate = rate
    try { this.storage?.setItem(RATE_KEY, String(rate)) } catch { /* Optional. */ }
    this.timeUpdate()
  }

  resetSegment() {
    this.generation++
    clearTimeout(this.timer)
    this.url = null
    this.chunks = []
    this.error = null
    this.message = null
    if (this.audio.hasAttribute("src")) {
      this.audio.pause()
      this.audio.removeAttribute("src")
      this.audio.load()
    }
    this.publish(null)
  }

  stop() {
    this.started = false
    this.latency.cancel(this.playJourney)
    this.latency.cancel(this.seekJourney)
    this.playJourney = this.seekJourney = null
    this.resetSegment()
    this.render()
  }

  async select(chapter, segment, steer, advancing = false) {
    this.resetSegment()
    const generation = this.generation
    this.chapter = chapter
    this.segment = segment
    // A tentative next segment may not exist. Persist only confirmed positions.
    if (!advancing) this.bookmark()
    this.render()
    try {
      if (steer && [ "queued", "running" ].includes(this.snapshot?.state)) {
        await this.client.listenFrom(this.jobId, chapter)
        if (generation !== this.generation) return
      }
      await this.poll(generation, advancing)
    } catch (error) {
      if (generation === this.generation) this.fail(error)
    }
  }

  bookmark() {
    try {
      this.storage?.setItem(positionKey(this.jobId), JSON.stringify({ chapterIndex: this.chapter, segmentIndex: this.segment }))
    } catch { /* Optional. */ }
  }

  async poll(generation, advancing) {
    const jobId = this.jobId
    const chapter = this.chapter
    let manifest = null
    try {
      manifest = await this.client.getChapterManifest(jobId, chapter)
    } catch (error) {
      if (generation !== this.generation) return
      if (this.snapshot?.state === "finished") return this.fail(error)
    }
    if (generation !== this.generation) return
    this.chunks = manifest?.chunks ?? []
    if (manifest?.legacyWholeChapter && this.segment > 0 && !advancing) {
      return this.fail(null, "unmapped")
    }
    const chunk = this.chunks.find(entry => entry.index === this.segment)
    if (chunk?.url) {
      this.url = chunk.url
      this.bookmark()
      this.audio.src = chunk.url
      this.audio.playbackRate = this.rate
      this.latency.record(this.playJourney, "audio_queued")
      this.render()
      try {
        await this.audio.play()
      } catch (error) {
        if (generation === this.generation) this.fail(error)
      }
      return
    }
    const chapterDone = this.chapters.find(entry => entry.index === chapter)?.status === "completed"
    if (this.snapshot?.state === "failed" && !chapterDone) return this.fail(null, "unavailable")
    if (chapterDone || this.snapshot?.state === "finished") {
      if (advancing) return this.advanceChapter()
      return this.fail(null, "unavailable")
    }
    this.timer = setTimeout(() => this.poll(generation, advancing), this.interval)
  }

  advanceChapter() {
    const next = this.neighbor(1)
    if (next) return this.select(next.index, 0, true)
    try { this.storage?.removeItem(positionKey(this.jobId)) } catch { /* Optional. */ }
    this.stop()
  }

  fail(error, message) {
    this.error = error ? String(error.message ?? error) : null
    this.message = message ?? "unavailable"
    this.latency.cancel(this.playJourney)
    this.latency.cancel(this.seekJourney)
    this.render()
  }

  hasCurrentAudio() {
    return this.started && this.url && this.audio.currentSrc === this.url
  }

  canPlay() {
    if (this.hasCurrentAudio()) this.latency.record(this.playJourney, "audio_playable")
  }

  playing() {
    if (!this.hasCurrentAudio()) return
    const chunk = this.chunks.find(entry => entry.index === this.segment)
    this.error = this.message = null
    this.publish({ jobId: this.jobId, chapterIndex: this.chapter, segmentIndex: this.segment, segmentText: chunk?.text ?? "" })
    this.render()
  }

  timeUpdate() {
    if (!this.hasCurrentAudio() || this.audio.currentTime <= 0) return
    if (this.latency.record(this.playJourney, "audio_audible")) {
      this.latency.finish(this.playJourney)
      this.playJourney = null
    }
    if (this.latency.record(this.seekJourney, "seek_target_reached")) {
      this.latency.finish(this.seekJourney)
      this.seekJourney = null
    }
    if (this.chapters.find(entry => entry.index === this.chapter)?.status !== "completed") return
    const remaining = this.chunks.filter(chunk => chunk.index > this.segment).map(chunk => chunk.durationSeconds)
    if (!Number.isFinite(this.audio.duration) || !remaining.every(Number.isFinite)) return
    const seconds = Math.max(0, this.audio.duration - this.audio.currentTime) + remaining.reduce((a, b) => a + b, 0)
    const generation = this.generation
    this.client.playbackFeedback(this.jobId, this.chapter, seconds, this.rate).catch(error => {
      if (generation === this.generation) this.fail(error)
    })
  }

  ended() {
    if (this.hasCurrentAudio()) this.select(this.chapter, this.segment + 1, false, true)
  }
}
