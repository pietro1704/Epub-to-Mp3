import { Controller } from "@hotwired/stimulus"
import { conversionWorkspace } from "runtime/workspace_store"
import { format, plural } from "runtime/conversion_presentation"

/** The batch an earlier page left unfinished; dismiss only (P-19, ADR Q-07). */
export default class extends Controller {
  static targets = [ "title", "reupload" ]
  static values = { strings: Object }

  async connect() {
    this.workspace = await conversionWorkspace()
    if (!this.element.isConnected) return
    this.unsubscribe = this.workspace.subscribe((state) => this.render(state))
  }

  disconnect() { this.unsubscribe?.() }

  dismiss() { this.workspace.dismissSavedBatch() }

  /** @param {import("runtime/conversion_workspace").WorkspaceState} state */
  render({ savedBatch }) {
    this.element.hidden = !savedBatch
    if (!savedBatch) return
    const strings = this.stringsValue
    this.titleTarget.textContent = format(plural(strings.savedBatchTitle, savedBatch.total), { count: savedBatch.total })
    this.reuploadTarget.hidden = savedBatch.needsFiles === 0
    this.reuploadTarget.textContent = format(plural(strings.savedBatchNeedsReupload, savedBatch.needsFiles), { count: savedBatch.needsFiles })
  }
}
