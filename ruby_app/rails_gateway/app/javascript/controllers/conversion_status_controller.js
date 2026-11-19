import { Controller } from "@hotwired/stimulus"
import { conversionWorkspace } from "runtime/workspace_store"
import { batchText, etaText, failureText, format, logLine, phaseKey, progressPercent } from "runtime/conversion_presentation"

/**
 * Status of the active job, used by the setup banner (P-18) and the progress
 * panel (P-27, P-28): phase, job id, ETA with a one-second countdown,
 * chapters, progress, error with category hint, cancel with confirmation,
 * skip and the event log. Optional targets are absent in the banner.
 */
export default class extends Controller {
  static targets = [ "placeholder", "phase", "batch", "job", "book", "eta", "chapters", "percent", "bar", "fill", "failure",
    "error", "hint", "cancel", "skip", "logToggle", "logPanel", "log" ]
  static values = { strings: Object }

  async connect() {
    this.workspace = await conversionWorkspace()
    if (!this.element.isConnected) return
    this.unsubscribe = this.workspace.subscribe((state) => { this.state = state; this.render() })
    this.timer = setInterval(() => this.renderEta(), 1000)
  }

  disconnect() {
    this.unsubscribe?.()
    clearInterval(this.timer)
  }

  viewProgress() { this.workspace?.selectTab("progress") }

  cancel() {
    if (!this.state?.activeJobId || !window.confirm(this.stringsValue.cancelConfirm)) return
    this.workspace.cancelCurrent()
  }

  skip() {
    if (!this.state?.activeJobId || !window.confirm(this.stringsValue.skipConfirm)) return
    this.workspace.skipCurrent()
  }

  toggleLog() {
    const open = this.logPanelTarget.hidden
    this.logPanelTarget.hidden = !open
    this.logToggleTarget.setAttribute("aria-expanded", String(open))
    this.logToggleTarget.textContent = open ? this.stringsValue.toggleHide : this.stringsValue.toggleShow
  }

  render() {
    const state = this.state
    const strings = this.stringsValue
    const snapshot = state.snapshot ?? {}
    const running = state.phase === "converting"
    // The banner exists only while converting; the panel always.
    if (!this.hasPlaceholderTarget) this.element.hidden = !running
    else this.placeholderTarget.hidden = Boolean(state.activeJobId)
    this.phaseTarget.textContent = state.activeJobId ? strings.phases[phaseKey(state)] : strings.phases.idle
    if (this.hasBatchTarget) this.batchTarget.textContent = batchText(strings, state)
    if (this.hasJobTarget) this.jobTarget.textContent = state.activeJobId ? format(strings.jobLabel, { jobId: state.activeJobId }) : ""
    this.bookTarget.textContent = state.activeJobId ? (snapshot.bookTitle?.trim() || strings.bookFallbackTitle) : ""
    if (this.hasChaptersTarget)
      this.chaptersTarget.textContent = snapshot.chaptersTotal
        ? format(strings.chaptersProgress, { completed: snapshot.chaptersCompleted ?? 0, total: snapshot.chaptersTotal }) : "—"
    if (this.hasBarTarget) {
      const percent = Math.round(progressPercent(state))
      this.percentTarget.textContent = `${percent}%`
      this.barTarget.setAttribute("aria-valuenow", String(percent))
      this.fillTarget.style.width = `${percent}%`
    }
    if (this.hasFailureTarget) {
      const failure = failureText(strings, state)
      this.failureTarget.hidden = !failure
      this.errorTarget.textContent = failure?.error ?? ""
      this.hintTarget.textContent = failure?.hint ?? ""
      this.hintTarget.hidden = !failure?.hint
    }
    this.cancelTarget.hidden = !running
    this.cancelTarget.disabled = state.cancelling
    this.skipTarget.hidden = !running || state.queue.length === 0
    this.skipTarget.disabled = state.cancelling
    if (this.hasLogTarget) this.renderLog(state.log)
    this.renderEta()
  }

  renderEta() {
    if (this.state) this.etaTarget.textContent = etaText(this.stringsValue, this.state, Date.now())
  }

  /** Appends only new entries; the bounded log drops its oldest ones. @param {any[]} log */
  renderLog(log) {
    const locale = document.documentElement.lang || undefined
    const last = this.lastEntry ? log.lastIndexOf(this.lastEntry) : -1
    if (last < 0) this.logTarget.replaceChildren()
    for (const entry of log.slice(last + 1)) {
      const item = document.createElement("li")
      item.textContent = logLine(this.stringsValue, entry, locale)
      this.logTarget.append(item)
    }
    while (this.logTarget.children.length > log.length) this.logTarget.firstElementChild.remove()
    this.lastEntry = log.at(-1)
  }
}
