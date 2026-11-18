import { Controller } from "@hotwired/stimulus"
import { StreamPlayer } from "runtime/stream_player"
import { latencyObservations } from "runtime/latency_observation"
import { bookQueue, conversionWorkspace, readerSession } from "runtime/workspace_store"

export default class extends Controller {
  static targets = [ "start", "controls", "prev", "next", "chapter", "restart", "rate", "audio", "status", "text", "chips" ]
  static values = { strings: Object }

  async connect() {
    const lifecycle = this.lifecycle = {}
    const workspace = await conversionWorkspace()
    if (this.lifecycle !== lifecycle) return
    let storage
    try { storage = window.localStorage } catch { /* The player works without bookmarks. */ }
    this.player = new StreamPlayer({
      client: workspace.client, audio: this.audioTarget, storage, latency: latencyObservations,
      publish: detail => this.publish(detail), render: () => this.render(),
    })
    this.unsubscribe = workspace.subscribe(({ activeBookId, activeJobId, snapshot }) => {
      this.bookId = activeBookId
      this.player.update(activeJobId, snapshot)
    })
  }

  disconnect() {
    this.lifecycle = null
    this.unsubscribe?.()
    this.player?.stop()
    this.player = null
    this.clearMetadata()
  }

  publish(detail) {
    document.dispatchEvent(new CustomEvent("player:segment", { detail }))
    if (!detail) {
      readerSession.clearAudio(this.readerPlayback)
      this.readerPlayback = null
      return
    }
    // Conversion uses the zero-based source position even for a chapter range.
    // The reader addresses that source chapter by its canonical EPUB index.
    const source = bookQueue.snapshot().find(book => book.id === this.bookId)
    const chapter = source?.document?.chapters[detail.chapterIndex]
    if (chapter) {
      this.readerPlayback = { ...detail, bookId: source.id, chapterIndex: chapter.index }
      readerSession.followAudio(this.readerPlayback)
    }
  }

  start() { this.player?.start() }
  stop() { this.player?.stop() }
  previous() { this.player?.jump(this.player.neighbor(-1)?.index) }
  next() { this.player?.jump(this.player.neighbor(1)?.index) }
  jump() { this.player?.jump(Number(this.chapterTarget.value)) }
  speed() { this.player?.setRate(Number(this.rateTarget.value)) }
  canPlay() { this.player?.canPlay() }
  playing() { this.player?.playing() }
  timeUpdate() { this.player?.timeUpdate() }
  ended() { this.player?.ended() }
  mediaError() {
    if (this.player?.hasCurrentAudio() && this.audioTarget.error) this.player.fail(this.audioTarget.error)
  }

  clearMetadata() {
    if (this.metadata && navigator.mediaSession?.metadata === this.metadata) navigator.mediaSession.metadata = null
    this.metadataKey = this.metadata = null
  }

  render() {
    const player = this.player
    if (!player || !this.lifecycle) return
    this.element.hidden = !player.chapters.length || [ "cancelled", "interrupted" ].includes(player.snapshot?.state) ||
      (player.snapshot?.state === "failed" && !player.snapshot?.outputs?.length)
    this.controlsTarget.hidden = !player.started
    this.startTarget.hidden = player.started
    if (!player.started) {
      this.clearMetadata()
      return
    }
    const entries = player.chapters
    const options = this.chapterTarget.options
    if (options.length !== entries.length || entries.some((entry, i) => options[i].value !== String(entry.index) || options[i].text !== entry.name)) {
      this.chapterTarget.replaceChildren(...entries.map(entry => new Option(entry.name, String(entry.index))))
    }
    this.chapterTarget.value = String(player.chapter)
    this.prevTarget.disabled = !player.neighbor(-1)
    this.nextTarget.disabled = !player.neighbor(1)
    this.rateTarget.value = String(player.rate)
    this.restartTarget.hidden = !player.message
    const chunk = player.chunks.find(entry => entry.index === player.segment)
    this.textTarget.textContent = chunk?.text ?? ""
    this.statusTarget.textContent = player.error ?? (player.message ? this.stringsValue[player.message] :
      chunk ? this.stringsValue.segment + " " + (player.segment + 1) + " / " + player.chunks.length : this.stringsValue.waiting)
    const chips = this.chipsTarget.children
    if (chips.length !== player.chunks.length || player.chunks.some((entry, i) => chips[i].value !== entry.index + 1)) {
      this.chipsTarget.replaceChildren(...player.chunks.map(entry => {
        const li = document.createElement("li")
        li.value = entry.index + 1
        li.textContent = "#" + li.value
        return li
      }))
    }
    for (const li of chips) {
      if (li.value === player.segment + 1) li.setAttribute("aria-current", "true")
      else li.removeAttribute("aria-current")
    }
    if (navigator.mediaSession && typeof MediaMetadata === "function") {
      const key = JSON.stringify([ player.jobId, player.chapter ])
      if (key !== this.metadataKey) {
        this.metadataKey = key
        this.metadata = new MediaMetadata({ title: player.snapshot?.bookTitle || "Audiobook", artist: player.snapshot?.bookAuthor || "Converter",
          album: entries.find(entry => entry.index === player.chapter)?.name ?? "" })
        navigator.mediaSession.metadata = this.metadata
      }
    }
  }
}
