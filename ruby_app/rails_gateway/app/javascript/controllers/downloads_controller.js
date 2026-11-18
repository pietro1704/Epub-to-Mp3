import { Controller } from "@hotwired/stimulus"
import { conversionWorkspace } from "runtime/workspace_store"

const HIDDEN_RECENT = "ebook-tts-hidden-recent"

function node(tag, text) {
  const result = document.createElement(tag)
  if (text !== undefined) result.textContent = text
  return result
}

function jobButton(action, label, jobId) {
  const button = node("button", label)
  button.type = "button"
  button.dataset.action = "downloads#" + action
  button.dataset.jobId = jobId
  return button
}

function chapterLink(output, label) {
  const link = node("a", label)
  link.download = output.name
  link.href = output.url
  return link
}

function hiddenJobs() {
  try {
    const ids = JSON.parse(localStorage.getItem(HIDDEN_RECENT) ?? "[]")
    return new Set(Array.isArray(ids) ? ids : [])
  } catch { return new Set() }
}

/** Both panels read the same IndexedDB catalog; viewing history never changes the active conversion. */
export default class extends Controller {
  static targets = [ "recent", "recentList", "ready", "readyList", "context", "contextTitle", "placeholder", "title",
    "chapters", "reset", "share", "feedback", "error" ]
  static values = { strings: Object }

  async connect() {
    const connection = this.connection = {}
    this.jobs = []
    this.hiddenIds = hiddenJobs()
    this.catalogKey = null
    this.presentationKey = null
    this.onPlay = event => {
      for (const player of this.chaptersTarget.querySelectorAll("audio")) {
        if (player !== event.target && !player.paused) player.pause()
      }
    }
    this.chaptersTarget.addEventListener("play", this.onPlay, true)
    this.workspace = await conversionWorkspace()
    if (connection !== this.connection) return
    this.unsubscribe = this.workspace.subscribe(state => this.update(state))
  }

  disconnect() {
    this.connection = null
    this.unsubscribe?.()
    this.chaptersTarget.removeEventListener("play", this.onPlay, true)
    clearTimeout(this.feedbackTimeout)
  }

  update(state) {
    const catalogKey = JSON.stringify([ state.activeJobId, state.phase, state.storedRevision, this.workspace.sessionDownloads.size ])
    if (catalogKey !== this.catalogKey) {
      this.catalogKey = catalogKey
      this.refresh(this.connection, catalogKey)
    }
    this.renderPanel(state)
    const viewed = state.viewedDownloadId ?? state.activeJobId
    for (const button of this.readyListTarget.querySelectorAll("button[aria-pressed]")) {
      button.setAttribute("aria-pressed", String(button.dataset.jobId === viewed))
    }
  }

  async refresh(connection, key) {
    try {
      const recent = await this.workspace.client.getRecentJobs()
      if (connection !== this.connection || key !== this.catalogKey) return
      this.jobs = recent.filter(job => job.state === "finished" && job.outputs?.length && !this.hiddenIds.has(job.jobId))
        .sort((a, b) => (b.savedAt ?? "").localeCompare(a.savedAt ?? ""))
      this.renderLibrary()
      this.renderPanel(this.workspace.state)
    } catch {
      if (connection === this.connection && key === this.catalogKey) this.showError(this.stringsValue.readError)
    }
  }

  renderLibrary() {
    const labels = this.stringsValue
    const state = this.workspace.state
    this.recentTarget.hidden = this.readyTarget.hidden = !this.jobs.length
    const ready = [], recent = []
    for (const job of this.jobs) {
      const title = job.bookTitle || labels.noTitle
      const isSessionJob = this.workspace.sessionDownloads.has(job.jobId)
      const n = job.outputs.length
      const row = node("li")
      row.dataset.jobId = job.jobId
      const open = jobButton("select", labels.open, job.jobId)
      open.setAttribute("aria-pressed", String(job.jobId === (state.viewedDownloadId ?? state.activeJobId)))
      row.append(node("strong", title), " · ", isSessionJob ? labels.current : labels.history,
        " · ", n === 1 ? labels.chapter : labels.chapters.replace("{count}", String(n)), " ", open)
      if (!isSessionJob) row.append(" ", jobButton("remove", labels.remove, job.jobId))
      ready.push(row)
      const item = node("li")
      item.dataset.jobId = job.jobId
      item.append(node("strong", title), " ", jobButton("select", labels.listen, job.jobId))
      if (job.jobId !== state.activeJobId) item.append(" ", jobButton("remove", labels.remove, job.jobId))
      recent.push(item)
    }
    this.readyListTarget.replaceChildren(...ready)
    this.recentListTarget.replaceChildren(...recent)
  }

  renderPanel(state) {
    const previous = this.jobs.find(job => job.jobId === state.viewedDownloadId)
    const outputs = previous?.outputs ?? (state.snapshot?.state === "finished" ? state.snapshot.outputs : []) ?? []
    const title = previous?.bookTitle || state.snapshot?.bookTitle || this.stringsValue.noTitle
    const id = previous?.jobId ?? state.activeJobId
    this.resetTarget.disabled = state.phase === "converting"
    this.placeholderTarget.hidden = Boolean(outputs.length)
    this.placeholderTarget.textContent = state.phase === "finished" ? this.stringsValue.missing : this.stringsValue.placeholder
    this.resetTarget.textContent = outputs.length ? this.stringsValue.reset : this.stringsValue.clear
    this.contextTarget.hidden = !previous
    this.contextTitleTarget.textContent = previous ? this.stringsValue.viewing.replace("{title}", () => title) : ""

    // Preserving the nodes keeps playback alive through tab switches and unrelated progress updates.
    const key = JSON.stringify([ id, title, outputs.map(file => file.url) ])
    if (this.presentationKey === key) return
    this.presentationKey = key
    clearTimeout(this.feedbackTimeout)
    this.feedbackTarget.textContent = ""
    this.shareUrl = outputs[0]?.url
    this.shareTitle = title
    this.titleTarget.hidden = this.shareTarget.hidden = !outputs.length
    this.titleTarget.textContent = title
    this.chaptersTarget.replaceChildren(...outputs.map(output => {
      const row = node("li")
      const audio = node("audio")
      audio.controls = true
      audio.preload = "metadata"
      audio.src = output.url
      audio.setAttribute("aria-label", output.name)
      row.append(node("span", output.name), " ", audio, " ", chapterLink(output, this.stringsValue.chapterDownload))
      return row
    }))
  }

  select(event) { this.workspace.viewDownloads(event.currentTarget.dataset.jobId) }
  back() { this.workspace.returnToCurrentDownloads() }

  reset() {
    if (this.workspace.resetConversion()) this.dispatch("reset", { target: window })
  }

  async remove(event) {
    const button = event.currentTarget
    const id = button.dataset.jobId
    if (id === this.workspace.state.activeJobId) return
    button.disabled = true
    try {
      await this.workspace.removeJob(id)
      this.hiddenIds.add(id)
      try {
        const all = new Set([ ...hiddenJobs(), id ])
        localStorage.setItem(HIDDEN_RECENT, JSON.stringify([ ...all ]))
      } catch { /* The deletion is already durable in IndexedDB. */ }
      if (this.workspace.state.viewedDownloadId === id) this.workspace.returnToCurrentDownloads()
    } catch {
      this.showError(this.stringsValue.removeError)
      button.disabled = false
    }
  }

  downloadAll() {
    for (const job of this.jobs) {
      for (const output of job.outputs) {
        const link = chapterLink(output, "")
        document.body.append(link)
        link.click()
        link.remove()
      }
    }
  }

  showError(text) {
    this.errorTarget.textContent = text
    this.errorTarget.hidden = false
  }

  message() {
    return this.stringsValue.shareMessage.replace("{title}", () => this.shareTitle)
  }

  feedback(key, message) {
    if (!this.connection || key !== this.presentationKey) return
    this.feedbackTarget.textContent = message
    clearTimeout(this.feedbackTimeout)
    this.feedbackTimeout = setTimeout(() => { this.feedbackTarget.textContent = "" }, 3500)
  }

  async nativeShare() {
    const key = this.presentationKey
    try {
      await navigator.share({ title: this.shareTitle, text: this.message(), url: this.shareUrl })
      this.feedback(key, "")
    } catch (error) {
      if (error?.name !== "AbortError") this.feedback(key, this.stringsValue.nativeUnavailable)
    }
  }

  whatsApp() {
    window.open("https://wa.me/?text=" + encodeURIComponent(this.message() + " " + this.shareUrl), "_blank", "noopener,noreferrer")
  }

  async copyLink() {
    const key = this.presentationKey
    try {
      if (navigator.clipboard?.writeText) await navigator.clipboard.writeText(this.shareUrl)
      else {
        const field = node("textarea")
        field.value = this.shareUrl
        document.body.append(field)
        try {
          field.select()
          if (!document.execCommand("copy")) throw new Error("Copy was refused")
        } finally { field.remove() }
      }
      this.feedback(key, this.stringsValue.copied)
    } catch {
      this.feedback(key, this.stringsValue.copyError)
    }
  }
}
