import { Controller } from "@hotwired/stimulus"
import { conversionWorkspace } from "runtime/workspace_store"
import { batchText, etaText, phaseKey, progressPercent } from "runtime/conversion_presentation"

/** The hero of the active job: book, phase, voice, progress, ETA and batch position (P-05). */
export default class extends Controller {
  static targets = [ "title", "author", "phase", "batch", "voice", "percent", "bar", "fill", "eta" ]
  static values = { strings: Object }

  async connect() {
    const workspace = await conversionWorkspace()
    if (!this.element.isConnected) return
    this.unsubscribe = workspace.subscribe((state) => { this.state = state; this.render() })
    this.timer = setInterval(() => this.renderEta(), 1000)
  }

  disconnect() {
    this.unsubscribe?.()
    clearInterval(this.timer)
  }

  render() {
    const state = this.state
    const strings = this.stringsValue
    this.element.hidden = !state.activeJobId
    if (!state.activeJobId) return
    const snapshot = state.snapshot ?? {}
    this.titleTarget.textContent = snapshot.bookTitle?.trim() || strings.bookFallbackTitle
    this.authorTarget.textContent = snapshot.bookAuthor?.trim() || strings.bookFallbackAuthor
    this.phaseTarget.textContent = strings.phases[phaseKey(state)]
    this.batchTarget.textContent = batchText(strings, state)
    this.voiceTarget.textContent = [ snapshot.engine, snapshot.voice ].filter(Boolean).join(" · ")
    const percent = Math.round(progressPercent(state))
    this.percentTarget.textContent = `${percent}%`
    this.barTarget.setAttribute("aria-valuenow", String(percent))
    this.fillTarget.style.width = `${percent}%`
    this.renderEta()
  }

  renderEta() {
    if (this.state?.activeJobId) this.etaTarget.textContent = etaText(this.stringsValue, this.state, Date.now())
  }
}
