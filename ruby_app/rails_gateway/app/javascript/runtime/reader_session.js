/**
 * Reader selection and presentation state. The injected runtime owns all
 * sanitisation, text offsets, pagination, search and highlight generation.
 * Module singleton ownership keeps this state alive across Turbo navigation.
 */
export class ReaderSession {
  constructor({ inspect, render, preferences, savePreferences, latency }) {
    this.inspect = inspect
    /** Optional LatencyObservationStore; reader-open journeys are recorded as in React (P-44). */
    this.latency = latency
    this.journey = ""
    this.retryOpening = false
    this.render = render
    this.savePreferences = savePreferences
    this.listeners = new Set()
    this.revision = 0
    this.book = null
    this.document = null
    this.playback = null
    this.pauseAudioChapter = null
    this.state = {
      bookId: null, title: "", author: "", chapters: [], chapterIndex: null,
      phase: "idle", error: "", result: null, pageIndex: 0,
      query: "", matchIndex: -1, preferences, modal: false, followPaused: false,
    }
  }

  snapshot() { return { ...this.state, preferences: { ...this.state.preferences } } }
  subscribe(listener) {
    this.listeners.add(listener)
    listener(this.snapshot())
    return () => this.listeners.delete(listener)
  }
  notify() { for (const listener of this.listeners) listener(this.snapshot()) }

  async open(book) {
    const revision = ++this.revision
    this.startJourney()
    this.book = book
    this.document = null
    this.playback = null
    this.pauseAudioChapter = null
    Object.assign(this.state, {
      bookId: book.id, title: book.document?.bookTitle ?? book.file.name,
      author: book.document?.bookAuthor ?? "", chapters: [], chapterIndex: null,
      phase: "loading", error: "", result: null, pageIndex: 0, query: "",
      matchIndex: -1, followPaused: false,
    })
    this.notify()
    try {
      const document = await this.inspect(book.file)
      if (revision !== this.revision) return
      this.document = document
      Object.assign(this.state, {
        title: document.bookTitle || this.state.title,
        author: document.bookAuthor || this.state.author,
        chapters: document.chapters,
        chapterIndex: document.chapters[0]?.index ?? null,
      })
      await this.refresh()
    } catch (error) {
      if (revision !== this.revision) return
      this.fail(error)
    }
  }

  startJourney() {
    this.cancelJourney()
    this.retryOpening = false
    this.journey = this.latency?.begin("reader_open", "open_requested") ?? ""
  }

  cancelJourney() {
    if (this.journey) this.latency?.cancel(this.journey)
    this.journey = ""
  }

  close() {
    ++this.revision
    this.cancelJourney()
    this.book = null
    this.document = null
    this.playback = null
    this.pauseAudioChapter = null
    Object.assign(this.state, { bookId: null, chapters: [], chapterIndex: null, result: null, phase: "idle", modal: false })
    this.notify()
  }

  retry() {
    if (!this.document) return this.book && this.open(this.book)
    if (this.state.phase === "error" && this.retryOpening) this.startJourney()
    return this.refresh()
  }
  setModal(modal) { this.state.modal = modal; this.notify() }

  async selectChapter(index, fragment = "") {
    const chapter = this.document?.chapters.find((chapter) => String(chapter.index) === String(index))
    if (!chapter) return
    this.pauseAudioChapter = this.playback?.chapterIndex ?? null
    Object.assign(this.state, { chapterIndex: chapter.index, pageIndex: 0, matchIndex: -1, followPaused: true, result: null })
    await this.refresh({ fragment })
  }

  setPage(index) {
    const count = this.state.result?.pages.length ?? 0
    this.state.pageIndex = Math.max(0, Math.min(Math.max(0, count - 1), index))
    this.notify()
  }

  async search(query) {
    this.state.query = query
    this.state.matchIndex = -1
    await this.refresh({ search: true })
  }

  moveMatch(direction) {
    const matches = this.state.result?.searchMatches ?? []
    if (!matches.length) return
    const index = this.state.matchIndex < 0
      ? (direction < 0 ? matches.length - 1 : 0)
      : (this.state.matchIndex + direction + matches.length) % matches.length
    this.state.matchIndex = index
    this.state.pageIndex = matches[index].pageIndex
    this.notify()
  }

  async setPreferences(preferences) {
    const enabledFollow = !this.state.preferences.followAudio && preferences.followAudio
    this.state.preferences = preferences
    this.savePreferences(preferences)
    if (enabledFollow) {
      this.state.followPaused = false
      this.pauseAudioChapter = null
      if (this.playback) return this.followAudio(this.playback)
    }
    await this.refresh()
  }

  clearAudio(playback) {
    if (!playback || this.playback !== playback) return
    this.playback = null
    return this.refresh()
  }

  /** Playback follows the selected book and its canonical EPUB chapter index. */
  async followAudio(playback) {
    if (playback.bookId !== this.state.bookId) return
    this.playback = playback
    const state = this.state
    if (state.preferences.followAudio) {
      if (state.followPaused && this.pauseAudioChapter === playback.chapterIndex) return this.refresh()
      if (state.followPaused) { state.followPaused = false; this.pauseAudioChapter = null }
      if (state.chapters.some((chapter) => chapter.index === playback.chapterIndex)) state.chapterIndex = playback.chapterIndex
    }
    await this.refresh({ audio: state.preferences.followAudio && !state.followPaused })
  }

  async refresh({ search = false, audio = false, fragment = "" } = {}) {
    const chapter = this.document?.chapters.find((chapter) => chapter.index === this.state.chapterIndex)
    if (!chapter) {
      this.state.phase = this.document ? "empty" : this.book ? "loading" : "idle"
      this.state.result = null
      if (this.state.phase === "empty") this.cancelJourney()
      this.notify()
      return
    }
    const revision = ++this.revision
    const oldStart = this.state.result?.pages[this.state.pageIndex]?.start ?? 0
    this.state.phase = "loading"
    this.state.error = ""
    this.notify()
    try {
      const result = await this.render({
        version: 1, html: chapter.html, css: chapter.css, text: chapter.text,
        preferences: this.state.preferences, searchText: this.state.query,
        audioText: this.playback?.chapterIndex === chapter.index ? this.playback.segmentText ?? "" : "",
      })
      if (revision !== this.revision) return
      this.state.result = result
      this.state.matchIndex = Math.min(this.state.matchIndex, result.searchMatches.length - 1)
      this.state.phase = result.pages.length ? "ready" : "empty"
      const anchor = result.pages.findIndex((page) => page.start <= oldStart && page.end > oldStart)
      this.state.pageIndex = anchor >= 0 ? anchor : Math.min(this.state.pageIndex, Math.max(0, result.pages.length - 1))
      if (search) {
        this.state.matchIndex = result.searchMatches.length ? 0 : -1
        if (result.searchMatches.length) this.state.pageIndex = result.searchMatches[0].pageIndex
      }
      if (audio && result.audioMatch) this.state.pageIndex = result.audioMatch.pageIndex
      const target = result.anchors?.find((anchor) => anchor.id === fragment)
      if (target) this.state.pageIndex = target.pageIndex
      if (this.state.phase === "empty") this.cancelJourney()
      this.notify()
      // The subscriber applies the page and control state synchronously.
      if (revision === this.revision && this.journey) {
        this.latency.record(this.journey, "readable_content")
        this.latency.record(this.journey, "controls_usable")
        this.latency.finish(this.journey)
        this.journey = ""
      }
    } catch (error) {
      if (revision === this.revision) this.fail(error)
    }
  }

  fail(error) {
    this.retryOpening = Boolean(this.journey)
    this.cancelJourney()
    this.state.phase = "error"
    this.state.error = String(error?.message ?? error)
    this.state.result = null
    this.notify()
  }
}
