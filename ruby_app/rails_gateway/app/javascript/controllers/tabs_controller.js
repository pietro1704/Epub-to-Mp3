import { Controller } from "@hotwired/stimulus"
import { conversionWorkspace } from "runtime/workspace_store"

const TABS = [ "setup", "progress", "downloads" ]

/**
 * Tab selection and gating from the workspace (P-04). Panels stay mounted and
 * only their hidden state changes, so audio keeps playing across tabs. A
 * `?tab=` link selects a tab once it is reachable.
 */
export default class extends Controller {
  static targets = [ "trigger", "panel", "badge" ]

  async connect() {
    this.workspace = await conversionWorkspace()
    if (!this.element.isConnected) return
    this.requested = new URLSearchParams(window.location.search).get("tab")
    this.unsubscribe = this.workspace.subscribe((state) => this.render(state))
  }

  disconnect() { this.unsubscribe?.() }

  select(event) {
    const tab = event.currentTarget.dataset.tab
    this.requested = null
    this.workspace?.selectTab(tab)
  }

  navigate(event) {
    const enabled = this.triggerTargets.filter(trigger => !trigger.disabled)
    const index = enabled.indexOf(event.target)
    if (index < 0) return
    const positions = {
      ArrowRight: (index + 1) % enabled.length,
      ArrowLeft: (index + enabled.length - 1) % enabled.length,
      Home: 0,
      End: enabled.length - 1,
    }
    const target = enabled[positions[event.key]]
    if (!target) return
    event.preventDefault()
    this.requested = null
    this.workspace.selectTab(target.dataset.tab)
    target.focus()
  }

  /** @param {import("runtime/conversion_workspace").WorkspaceState} state */
  render(state) {
    if (this.requested && TABS.includes(this.requested)) {
      const tab = this.requested
      const reachable = tab === "setup" || (tab === "progress" && state.canViewProgress) || (tab === "downloads" && state.canViewDownloads)
      if (reachable) {
        this.requested = null
        if (state.tab !== tab) {
          this.workspace.selectTab(tab)
          return
        }
      }
    }
    const enabled = { setup: true, progress: state.canViewProgress, downloads: state.canViewDownloads }
    for (const trigger of this.triggerTargets) {
      const tab = trigger.dataset.tab
      const selected = tab === state.tab
      trigger.disabled = !enabled[tab]
      trigger.setAttribute("aria-disabled", String(!enabled[tab]))
      trigger.setAttribute("aria-selected", String(selected))
      trigger.tabIndex = selected ? 0 : -1
      trigger.classList.toggle("tabs__trigger--active", selected)
      trigger.classList.toggle("tabs__trigger--disabled", !enabled[tab])
    }
    for (const panel of this.panelTargets) panel.hidden = panel.dataset.tab !== state.tab
    for (const badge of this.badgeTargets) badge.hidden = state.phase !== "converting"
  }
}
