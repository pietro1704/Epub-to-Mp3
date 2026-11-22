import { Controller } from "@hotwired/stimulus"
import { loadTtsCatalog } from "runtime/converter_runtime"
import { installedModel } from "runtime/model_installation"
import { browserSelections, installedManualBrowserSelections } from "runtime/tts_catalog"
import { availableTtsPreferences, effectiveTtsPreferences, faber, loadTtsPreferences, saveTtsPreferences, system } from "runtime/tts_preferences"

const key = selection => selection?.model_id ?? selection?.engine ?? "none"

export default class extends Controller {
  static targets = [ "primary", "secondary", "inherit", "override", "manual", "reserve", "error" ]
  static values = { strings: Object }

  async connect() {
    const lifecycle = this.lifecycle = {}
    try { this.storage = window.localStorage } catch { /* Storage is optional for a per-job choice. */ }
    this.preferences = loadTtsPreferences(this.storage)
    this.installedManual = null
    this.initialized = false
    try {
      const catalog = await loadTtsCatalog()
      if (this.lifecycle !== lifecycle) return
      this.models = browserSelections(catalog)
      await this.refreshInstalledManual()
      if (this.lifecycle !== lifecycle) return
      this.initialized = true
      this.restoreDefaults()
    } catch (error) {
      if (this.lifecycle === lifecycle) this.showError(error)
    }
  }

  disconnect() { this.lifecycle = null }

  async refreshInstalledManual() {
    const refresh = this.manualRefresh = {}
    let installed = []
    try {
      const catalog = await loadTtsCatalog(true)
      installed = await installedManualBrowserSelections(catalog, installedModel)
    } catch { /* Installed manual voices are optional. */ }
    if (!this.lifecycle || this.manualRefresh !== refresh) return
    this.installedManual = installed
    if (this.initialized) this.render()
  }

  get primaryChoices() { return [ ...this.models, ...(this.installedManual ?? []) ] }

  onFormReset(event) {
    if (event.target !== this.element.form) return
    queueMicrotask(() => {
      if (this.lifecycle && this.initialized && !event.defaultPrevented) this.restoreDefaults()
    })
  }

  restoreDefaults() {
    this.preferences = loadTtsPreferences(this.storage)
    this.inheritTarget.checked = true
    this.reserveTarget.checked = false
    this.errorTarget.hidden = true
    this.manual = this.primaryChoices.find(choice => key(choice) === key(availableTtsPreferences(this.preferences, this.installedManual).primary)) ?? this.models[0]
    this.render()
  }

  // Capture the choice once for all books in the submitted batch.
  capture() {
    const saved = this.storage ? loadTtsPreferences(this.storage) : this.preferences
    return effectiveTtsPreferences(availableTtsPreferences(saved, this.installedManual), this.inheritTarget.checked ? null : this.manual, this.reserveTarget.checked)
  }

  change(event) {
    if (!this.initialized) return
    const control = event.target
    const next = { ...this.preferences, policy_version: 2 }
    if (control === this.primaryTarget) {
      next.primary = this.primaryChoices.find(choice => key(choice) === control.value)
      if (!next.primary) return
      next.secondary = null
    } else if (control === this.secondaryTarget) {
      next.primary = availableTtsPreferences(this.preferences, this.installedManual).primary
      next.secondary = control.value === "system" ? system : this.models.find(choice => key(choice) === control.value) ?? null
    } else {
      if (![ this.manualTarget, this.inheritTarget, this.reserveTarget ].includes(control)) return
      if (control === this.manualTarget) this.manual = this.primaryChoices.find(choice => key(choice) === control.value)
      this.render()
      return
    }
    try {
      saveTtsPreferences(this.storage, next)
      this.preferences = next
      this.errorTarget.hidden = true
    } catch (error) { this.showError(error) }
    this.render()
  }

  showError(error) {
    this.errorTarget.textContent = String(error.message ?? error)
    this.errorTarget.hidden = false
  }

  choices(select, choices, selected) {
    const options = new Map()
    for (const selection of choices) {
      const id = key(selection)
      if (options.has(id)) continue
      const label = id === "none" ? this.stringsValue.none : id === "system" ? this.stringsValue.system :
        id === "edge" ? id + " — " + this.stringsValue.unavailable : id === faber.model_id ? "Faber medium" : id
      const option = new Option(label, id)
      option.disabled = id === "edge"
      options.set(id, option)
    }
    select.replaceChildren(...options.values())
    select.value = key(selected)
    select.disabled = false
  }

  render() {
    const { primary, secondary } = availableTtsPreferences(this.preferences, this.installedManual)
    this.choices(this.primaryTarget, [ primary, ...this.primaryChoices ], primary)
    this.choices(this.secondaryTarget, [ null, system, secondary, ...this.models ].filter(choice => key(choice) !== key(primary)), secondary)
    this.choices(this.manualTarget, this.primaryChoices, this.manual)
    const inherited = this.inheritTarget.checked
    this.overrideTarget.hidden = inherited
    this.reserveTarget.disabled = !secondary || key(secondary) === key(this.manual)
    if (this.reserveTarget.disabled) this.reserveTarget.checked = false
  }
}
