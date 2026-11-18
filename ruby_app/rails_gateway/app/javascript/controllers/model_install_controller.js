import { Controller } from "@hotwired/stimulus"
import { loadTtsCatalog } from "runtime/converter_runtime"
import { installedModel, installModel } from "runtime/model_installation"

export default class extends Controller {
  static targets = [ "button", "status" ]
  static values = { model: String, strings: Object }

  connect() { this.check() }
  disconnect() { this.checking = null }
  modelValueChanged() { if (this.hasButtonTarget) this.check() }

  async check() {
    const checking = this.checking = {}
    const modelId = this.modelValue
    this.show("idle")
    this.buttonTarget.disabled = !modelId || Boolean(this.installing)
    if (!modelId || this.installing) return
    try {
      const catalog = await loadTtsCatalog()
      const model = catalog.models.find(candidate => candidate.id === modelId)
      const installed = model && await installedModel(model)
      if (checking === this.checking && installed) this.show("installed")
    } catch (error) {
      if (checking === this.checking) this.show("error", this.describe(error))
    }
  }

  async install() {
    const modelId = this.modelValue
    if (!modelId || this.installing) return
    this.checking = null
    this.installing = modelId
    this.buttonTarget.disabled = true
    this.show("installing")
    try {
      await installModel(modelId)
      if (this.modelValue === modelId) this.show("installed")
    } catch (error) {
      if (this.modelValue === modelId) this.show("error", this.describe(error))
    } finally {
      this.installing = null
      if (this.element.isConnected) {
        this.buttonTarget.disabled = !this.modelValue
        if (this.modelValue !== modelId) this.check()
      }
    }
  }

  describe(error) {
    if ([ "NotAllowedError", "SecurityError", "NotSupportedError" ].includes(error.name)) return this.stringsValue.storageBlocked
    return String(error.message ?? error)
  }

  show(state, error) {
    this.element.dataset.installState = state
    this.statusTarget.textContent = error ?? this.stringsValue[state] ?? ""
  }
}
