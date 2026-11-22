import { Controller } from "@hotwired/stimulus"
import { loadTtsCatalog } from "runtime/converter_runtime"
import { installedModel, installModel } from "runtime/model_installation"
import { browserDownloadSelections } from "runtime/tts_catalog"

export default class extends Controller {
  static targets = [ "button", "status", "model", "includeLow" ]
  static values = { strings: Object }

  connect() {
    this.lifecycle = {}
    this.includeLowTarget.checked = false
    this.refreshModels()
  }

  disconnect() {
    this.lifecycle = null
    this.checking = null
  }

  async refreshModels() {
    const lifecycle = this.lifecycle
    const refresh = this.refreshing = {}
    const includeLow = this.includeLowTarget.checked
    this.modelTarget.disabled = true
    this.buttonTarget.disabled = true
    try {
      const catalog = await loadTtsCatalog(includeLow)
      if (this.lifecycle !== lifecycle || this.refreshing !== refresh) return
      const selected = this.modelTarget.value
      const choices = browserDownloadSelections(catalog, includeLow)
      this.models = catalog.models
      const options = choices.map(({ model_id }) => new Option(
        model_id === "pt_BR-faber-medium" ? "Faber medium" : model_id, model_id
      ))
      this.modelTarget.replaceChildren(...options)
      if (choices.some(choice => choice.model_id === selected)) this.modelTarget.value = selected
      this.modelTarget.disabled = !options.length
      this.refreshing = null
      this.check()
    } catch (error) {
      if (this.lifecycle === lifecycle && this.refreshing === refresh) this.show("error", this.describe(error))
    }
  }

  onFormReset(event) {
    if (event.target !== this.element.closest("form")) return
    queueMicrotask(() => {
      if (this.lifecycle && !event.defaultPrevented) this.refreshModels()
    })
  }

  async check() {
    const checking = this.checking = {}
    const modelId = this.modelTarget.value
    if (this.installing || this.refreshing) return
    this.show("idle")
    this.buttonTarget.disabled = !modelId
    if (!modelId) return
    try {
      const model = this.models.find(candidate => candidate.id === modelId)
      const installed = model && await installedModel(model)
      if (checking === this.checking && !this.refreshing && installed) this.show("installed")
    } catch (error) {
      if (checking === this.checking && !this.refreshing) this.show("error", this.describe(error))
    }
  }

  async install() {
    const modelId = this.modelTarget.value
    if (!modelId || this.installing || this.refreshing) return
    this.checking = null
    this.installing = modelId
    this.buttonTarget.disabled = true
    this.show("installing")
    try {
      await installModel(modelId)
      if (this.lifecycle) this.dispatch("installed")
      if (this.lifecycle && this.modelTarget.value === modelId) this.show("installed")
    } catch (error) {
      if (this.lifecycle && this.modelTarget.value === modelId) this.show("error", this.describe(error))
    } finally {
      this.installing = null
      if (this.lifecycle && !this.refreshing) {
        this.buttonTarget.disabled = !this.modelTarget.value
        if (this.modelTarget.value !== modelId) this.check()
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
