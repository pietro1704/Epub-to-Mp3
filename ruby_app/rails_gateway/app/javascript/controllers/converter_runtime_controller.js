import { Controller } from "@hotwired/stimulus"
import { loadTtsCatalog } from "runtime/converter_runtime"

/**
 * Shows the loading state until the Rust/WASM runtime answers with its TTS
 * catalog, and the failure message when it cannot be loaded.
 */
export default class extends Controller {
  static targets = ["loading", "failure"]
  static values = { state: { type: String, default: "loading" } }

  async connect() {
    try {
      await loadTtsCatalog()
      this.stateValue = "ready"
    } catch (error) {
      console.error(error)
      this.stateValue = "failed"
    }
  }

  /** @param {"loading" | "ready" | "failed"} state */
  stateValueChanged(state) {
    this.element.setAttribute("aria-busy", String(state === "loading"))
    this.loadingTarget.hidden = state !== "loading"
    this.failureTarget.hidden = state !== "failed"
  }
}
