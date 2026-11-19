import { Controller } from "@hotwired/stimulus"
import { conversionWorkspace } from "runtime/workspace_store"

function element(tag, text) {
  const node = document.createElement(tag)
  if (text !== undefined) node.textContent = text
  return node
}

function audioPlayer(url, label, className) {
  const audio = element("audio")
  audio.controls = true
  audio.preload = "none"
  audio.src = url
  audio.className = className
  audio.setAttribute("aria-label", label)
  return audio
}

export default class extends Controller {
  static targets = [ "list", "total", "tools", "expand", "textToggle", "query", "count", "prev", "next" ]
  static values = { strings: Object }

  async connect() {
    const lifecycle = this.lifecycle = {}
    this.rows = new Map()
    this.onPlay = ({ target }) => {
      for (const audio of this.listTarget.querySelectorAll("audio")) if (audio !== target && !audio.paused) audio.pause()
    }
    this.listTarget.addEventListener("play", this.onPlay, true)
    this.workspace = await conversionWorkspace()
    if (this.lifecycle !== lifecycle) return
    this.unsubscribe = this.workspace.subscribe(state => this.render(state))
  }

  disconnect() {
    this.lifecycle = null
    this.unsubscribe?.()
    this.listTarget.removeEventListener("play", this.onPlay, true)
    this.rows.clear()
    this.jobId = null
  }

  render({ activeJobId, snapshot }) {
    if (activeJobId !== this.jobId) {
      this.jobId = activeJobId
      this.rows.clear()
      this.playingSegment = null
      this.listTarget.replaceChildren()
      this.queryTarget.value = ""
      this.showText = false
      this.allOpen = false
      this.search()
    }
    const entries = snapshot?.chapterProgress ?? []
    this.element.hidden = !entries.length
    this.totalTarget.textContent = entries.filter(entry => entry.status === "completed").length + "/" + entries.length
    for (const entry of entries) {
      const row = this.rows.get(entry.index) ?? this.addRow(entry)
      row.status.textContent = this.stringsValue.statuses[entry.status] ?? entry.status
      row.state = entry.status
      if (row.url !== entry.downloadUrl) {
        row.url = entry.downloadUrl
        row.full.replaceChildren()
        if (row.url) row.full.append(audioPlayer(row.url, this.stringsValue.audio, "chapter-audio"))
      }
      const revision = [ snapshot.completedSegments, entry.status, entry.downloadUrl ].join(":")
      if (row.revision !== revision) {
        row.revision = revision
        if (row.details.open) this.load(row)
      }
    }
    this.controls()
  }

  addRow(entry) {
    const details = element("details")
    details.className = "chapter"
    details.open = this.allOpen
    const summary = element("summary", entry.index + ". " + entry.name + " · ")
    const status = element("span")
    summary.append(status)
    const full = element("div")
    const segments = element("ol")
    details.append(summary, full, segments)
    const li = element("li")
    li.append(details)
    this.listTarget.append(li)
    const row = { entry, details, status, full, segments, chunks: [] }
    this.rows.set(entry.index, row)
    details.addEventListener("toggle", () => {
      if (this.rows.get(entry.index) !== row) return
      if (details.open) this.load(row)
      this.controls()
    })
    return row
  }

  async load(row) {
    const request = row.request = {}
    const manifest = await this.workspace.client.getChapterManifest(this.jobId, row.entry.index)
    if (this.rows.get(row.entry.index) !== row || row.request !== request) return
    const chunks = manifest?.chunks ?? []
    // Keep playing audio nodes across progress polls. A seek may replace earlier chunks.
    let first = 0
    while (first < row.chunks.length && first < chunks.length && row.chunks[first].url === chunks[first].url) first++
    if (first === chunks.length && first === row.chunks.length) return
    while (row.segments.children.length > first) row.segments.lastElementChild.remove()
    row.chunks = chunks
    for (const chunk of chunks.slice(first)) {
      const li = element("li")
      li.className = "segment"
      li.dataset.index = chunk.index
      const title = this.stringsValue.segment + " " + (chunk.index + 1)
      li.append(element("span", title), audioPlayer(chunk.url, title, "segment-audio"))
      if (chunk.text?.trim()) {
        const detail = element("details")
        detail.open = this.showText
        detail.append(element("summary", this.stringsValue.text), element("p", chunk.text))
        li.append(detail)
      }
      row.segments.append(li)
    }
    this.markPlaying()
    this.highlight()
  }

  playing({ detail }) {
    this.playingSegment = detail?.jobId === this.jobId ? detail : null
    this.markPlaying()
  }

  markPlaying() {
    this.listTarget.querySelector(".segment[aria-current]")?.removeAttribute("aria-current")
    if (!this.playingSegment) return
    const { chapterIndex, segmentIndex } = this.playingSegment
    const segments = this.rows.get(chapterIndex)?.segments.children ?? []
    Array.from(segments).find(node => Number(node.dataset.index) === segmentIndex)?.setAttribute("aria-current", "true")
  }

  controls() {
    this.allOpen = this.rows.size > 0 && Array.from(this.rows.values()).every(row => row.details.open)
    this.expandTarget.textContent = this.allOpen ? this.stringsValue.collapse : this.stringsValue.expand
    this.textToggleTarget.textContent = this.showText ? this.stringsValue.hideText : this.stringsValue.showText
    this.toolsTarget.hidden = !this.showText
  }

  toggleChapters() {
    const open = !this.allOpen
    for (const row of this.rows.values()) row.details.open = open
    this.controls()
  }

  toggleText() {
    this.showText = !this.showText
    for (const row of this.rows.values()) {
      if (this.showText) row.details.open = true
      for (const detail of row.segments.querySelectorAll("details")) detail.open = this.showText
    }
    this.controls()
    this.search()
  }

  top() { this.element.scrollIntoView({ block: "start" }) }

  current() {
    const rows = Array.from(this.rows.values())
    const row = rows.find(item => item.state === "processing") ?? rows.find(item => item.state === "pending") ?? rows.at(-1)
    row?.details.scrollIntoView({ block: "center" })
  }

  search() {
    this.activeMatch = 0
    this.highlight()
  }

  highlight() {
    const query = this.showText ? this.queryTarget.value.trim() : ""
    const pattern = query ? new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "giu") : null
    this.matches = []
    for (const paragraph of this.listTarget.querySelectorAll(".segment p")) {
      const text = paragraph.textContent
      paragraph.replaceChildren()
      let start = 0
      if (pattern) {
        for (const match of text.matchAll(pattern)) {
          const mark = element("mark", match[0])
          paragraph.append(text.slice(start, match.index), mark)
          this.matches.push(mark)
          start = match.index + match[0].length
        }
      }
      paragraph.append(text.slice(start))
    }
    const count = this.matches.length
    this.countTarget.textContent = query ? count + " " + (count === 1 ? this.stringsValue.match : this.stringsValue.matches) : ""
    this.prevTarget.disabled = this.nextTarget.disabled = !count
    this.activeMatch = Math.min(this.activeMatch || 0, Math.max(0, count - 1))
    this.matches[this.activeMatch]?.setAttribute("aria-current", "true")
  }

  move(delta) {
    if (!this.matches.length) return
    this.matches[this.activeMatch].removeAttribute("aria-current")
    this.activeMatch = (this.activeMatch + delta + this.matches.length) % this.matches.length
    const match = this.matches[this.activeMatch]
    for (let node = match.parentElement; this.element.contains(node); node = node.parentElement) {
      if (node.tagName === "DETAILS") node.open = true
    }
    match.setAttribute("aria-current", "true")
    match.scrollIntoView({ block: "center" })
  }

  previous() { this.move(-1) }
  next() { this.move(1) }

  async download() {
    const jobId = this.jobId
    const sections = await Promise.all(Array.from(this.rows.values(), async ({ entry }) => {
      const manifest = await this.workspace.client.getChapterManifest(jobId, entry.index)
      const text = (manifest?.chunks ?? []).map(chunk => chunk.text).filter(Boolean).join("\n")
      return entry.index + ". " + entry.name + "\n\n" + (text || this.stringsValue.unavailable)
    }))
    if (!this.lifecycle || this.jobId !== jobId) return
    const url = URL.createObjectURL(new Blob([ sections.join("\n\n") ], { type: "text/plain;charset=utf-8" }))
    const link = element("a")
    link.href = url
    link.download = "book-" + jobId + ".txt"
    this.element.append(link)
    link.click()
    link.remove()
    setTimeout(() => URL.revokeObjectURL(url), 0)
  }
}
