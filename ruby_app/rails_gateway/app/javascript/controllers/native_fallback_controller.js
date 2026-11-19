import { Controller } from "@hotwired/stimulus"
import { browserNativeSpeech } from "runtime/native_speech"
import { conversionWorkspace } from "runtime/workspace_store"

export default class extends Controller {
  static targets = [ "chapter", "chapterLabel", "status", "listen", "pause", "stop", "retry" ]
  static values = { strings: Object }

  async connect() {
    const connection = this.connection = Symbol()
    this.speech = browserNativeSpeech()
    this.unsubscribeSpeech = this.speech.subscribe(() => this.render())
    this.onPrimaryPlay = () => this.stop()
    document.addEventListener("play", this.onPrimaryPlay, true)
    this.workspace = await conversionWorkspace()
    if (connection !== this.connection) return
    this.unsubscribe = this.workspace.subscribe(state => this.selectJob(state))
  }

  disconnect() {
    this.connection = null
    this.unsubscribe?.()
    this.unsubscribeSpeech()
    document.removeEventListener("play", this.onPrimaryPlay, true)
    this.clearJob()
  }

  clearJob() {
    this.speech.stop(this.owner)
    this.owner = null
    this.job = null
    this.policy = null
    this.chapters = []
    this.retrying = false
    this.retryFailed = false
    this.element.hidden = true
  }

  async selectJob({ activeJobId, snapshot }) {
    const id = snapshot?.state === "failed" && snapshot.errorCategory === "tts_provider" ? activeJobId : null
    if (this.job?.id === id || (!id && !this.job)) return
    this.clearJob()
    if (!id) return

    const job = this.job = { id }
    try {
      const policy = await this.workspace.client.getNativePlaybackPolicy(id)
      if (this.job !== job || !policy) return
      const book = await this.workspace.client.getJobFullText(id)
      if (this.job !== job) return
      this.chapters = book.chapters.filter(chapter => chapter.text?.trim())
      if (!this.chapters.length) return
      this.policy = policy
      this.chapterTarget.replaceChildren(...this.chapters.map(chapter => new Option(chapter.name, String(chapter.index))))
      const current = snapshot.chapterProgress?.find(entry => entry.status === "processing") ??
        snapshot.chapterProgress?.find(entry => entry.status !== "completed")
      if (this.chapters.some(chapter => chapter.index === current?.index)) this.chapterTarget.value = String(current.index)
      this.chapterLabelTarget.hidden = this.chapters.length === 1
      this.changeChapter()
      this.element.hidden = false
    } catch {
      if (this.job === job) this.clearJob()
    }
  }

  changeChapter() {
    this.speech.stop(this.owner)
    this.owner = Symbol()
    this.retryFailed = false
    this.render()
  }

  listen() {
    const chapter = this.chapters.find(entry => String(entry.index) === this.chapterTarget.value)
    if (!this.policy || !chapter || this.retrying) return
    this.retryFailed = false
    this.speech.start(this.owner, chapter.text, this.policy)
  }

  stop() {
    this.speech.stop(this.owner)
  }

  togglePause() {
    this.speech.togglePause(this.owner)
  }

  async retry() {
    const job = this.job
    if (!job || this.retrying) return
    this.stop()
    this.retrying = true
    this.retryFailed = false
    this.render()
    try {
      await this.workspace.resumeJob(job.id)
    } catch {
      if (this.job === job) this.retryFailed = true
    } finally {
      if (this.job === job) {
        this.retrying = false
        this.render()
      }
    }
  }

  render() {
    const strings = this.stringsValue
    const state = this.speech.state?.owner === this.owner ? this.speech.state : null
    const phase = state?.phase
    const active = [ "starting", "playing", "paused" ].includes(phase)
    this.listenTarget.disabled = this.retrying || active
    this.pauseTarget.disabled = phase !== "playing" && phase !== "paused"
    this.pauseTarget.textContent = phase === "paused" ? strings.resume : strings.pause
    this.stopTarget.disabled = !active
    this.retryTarget.disabled = this.chapterTarget.disabled = Boolean(this.retrying)
    const message = phase === "playing" ? state.voice : phase ? strings[phase] : ""
    this.statusTarget.textContent = this.retryFailed ? strings.retryFailure : message
  }
}
