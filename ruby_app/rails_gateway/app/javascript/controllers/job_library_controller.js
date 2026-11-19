import { Controller } from "@hotwired/stimulus"
import { conversionWorkspace } from "runtime/workspace_store"
import { format } from "runtime/conversion_presentation"

/**
 * Interrupted, failed and cancelled jobs stored in IndexedDB: resume keeps
 * completed chapters, remove deletes the job and its audio (P-20). The list
 * is read again whenever the active job changes phase.
 */
export default class extends Controller {
  static targets = [ "loading", "list", "row" ]
  static values = { strings: Object }

  async connect() {
    this.workspace = await conversionWorkspace()
    if (!this.element.isConnected) return
    this.unsubscribe = this.workspace.subscribe((state) => {
      const key = `${state.activeJobId}:${state.phase}:${state.storedRevision}`
      if (key !== this.lastKey) {
        this.lastKey = key
        this.refresh()
      }
    })
  }

  disconnect() { this.unsubscribe?.() }

  async refresh() {
    const generation = (this.generation = (this.generation ?? 0) + 1)
    let jobs = []
    try {
      jobs = await this.workspace.resumableJobs()
    } catch (error) {
      console.error(error)
    }
    if (generation !== this.generation || !this.element.isConnected) return
    this.render(jobs)
  }

  async resume(event) {
    const button = event.currentTarget
    button.disabled = true
    await this.workspace.resumeJob(this.jobId(event))
  }

  async remove(event) {
    event.currentTarget.disabled = true
    await this.workspace.removeJob(this.jobId(event))
  }

  jobId(event) { return event.currentTarget.closest("[data-job-id]").dataset.jobId }

  /** @param {Awaited<ReturnType<import("runtime/conversion_client").ConversionClient["getResumableJobs"]>>} jobs */
  render(jobs) {
    const strings = this.stringsValue
    const active = this.workspace.state.phase === "converting" ? this.workspace.state.activeJobId : undefined
    const visible = jobs.filter((job) => job.jobId !== active)
    this.loadingTarget.hidden = true
    this.element.hidden = visible.length === 0
    this.listTarget.replaceChildren(...visible.map((job) => {
      const row = this.rowTarget.content.firstElementChild.cloneNode(true)
      row.dataset.jobId = job.jobId
      const text = (field, value) => { row.querySelector(`[data-field=${field}]`).textContent = value }
      text("title", job.bookTitle || strings.bookFallbackTitle)
      text("state", strings.jobStates[job.state] ?? job.state)
      text("progress", format(strings.resumableProgress, { completed: job.chaptersCompleted, total: job.chaptersTotal }))
      text("engine", format(strings.resumableEngine, { value: job.engine }))
      text("voice", job.voice ? format(strings.resumableVoice, { value: job.voice }) : "")
      text("language", format(strings.resumableLanguage, { value: job.language }))
      return row
    }))
  }
}
