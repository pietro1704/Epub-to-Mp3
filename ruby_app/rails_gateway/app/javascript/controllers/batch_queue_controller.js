import { Controller } from "@hotwired/stimulus"
import { conversionWorkspace } from "runtime/workspace_store"
import { format, plural } from "runtime/conversion_presentation"

/** Books waiting after the active one: reorder, resume a paused batch, clear (P-17). */
export default class extends Controller {
  static targets = [ "label", "paused", "list", "row", "resume" ]
  static values = { strings: Object }

  async connect() {
    this.workspace = await conversionWorkspace()
    if (!this.element.isConnected) return
    this.unsubscribe = this.workspace.subscribe((state) => this.render(state))
  }

  disconnect() { this.unsubscribe?.() }

  up(event) { this.move(event, -1) }
  down(event) { this.move(event, 1) }
  resume() { this.workspace.resumeQueue() }
  clear() { this.workspace.clearQueue() }

  move(event, direction) {
    const index = Number(event.currentTarget.closest("[data-index]").dataset.index)
    this.workspace.reorderQueue(index, index + direction)
  }

  /** @param {import("runtime/conversion_workspace").WorkspaceState} state */
  render(state) {
    const queue = state.queue
    this.element.hidden = queue.length === 0
    this.labelTarget.textContent = format(plural(this.stringsValue.queueLabel, queue.length), { count: queue.length })
    this.pausedTarget.hidden = !state.queuePaused
    this.resumeTarget.hidden = !state.queuePaused
    this.listTarget.replaceChildren(...queue.map((item, index) => {
      const row = this.rowTarget.content.firstElementChild.cloneNode(true)
      row.dataset.index = String(index)
      row.querySelector("[data-field=title]").textContent = item.document?.bookTitle || item.fileName || this.stringsValue.bookFallbackTitle
      row.querySelector("[data-action='batch-queue#up']").disabled = index === 0
      row.querySelector("[data-action='batch-queue#down']").disabled = index === queue.length - 1
      return row
    }))
  }
}
