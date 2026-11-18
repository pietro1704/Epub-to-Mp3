import { Controller } from "@hotwired/stimulus"
import { conversionWorkspace } from "runtime/workspace_store"

// One notification per transition. Turbo can reconnect this view to an
// existing workspace; mounting a new view must not replay an old failure.
export default class extends Controller {
  static values = { strings: Object, space: Boolean }

  async connect() {
    this.timers = new Set()
    const connection = this.connection = {}
    const workspace = await conversionWorkspace()
    if (connection !== this.connection) return
    const api = window.Notification
    if (api?.permission === "default") api.requestPermission()?.catch(() => {})
    let previous = workspace.state
    this.unsubscribe = workspace.subscribe(state => {
      const was = previous
      previous = state
      const changed = state.phase !== was.phase || state.activeJobId !== was.activeJobId
      if ((state.error && state.error !== was.error) || (changed && state.phase === "failed")) {
        this.notify(this.stringsValue.notificationErrorTitle, state.error || state.snapshot?.error || this.stringsValue.notificationErrorBody)
      } else if (changed && state.phase === "cancelled") {
        this.notify(this.stringsValue.notificationCancelTitle, this.stringsValue.notificationCancelBody)
      }
    })
  }

  disconnect() {
    this.connection = null
    this.unsubscribe?.()
    for (const timer of this.timers) clearTimeout(timer)
    this.element.replaceChildren()
  }

  notify(title, body) {
    if (window.Notification?.permission === "granted") {
      try {
        new window.Notification(title, { body })
        return
      } catch { /* Some mobile browsers expose Notification but reject its constructor. */ }
    }
    if (!this.spaceValue) return
    const toast = document.createElement("div")
    toast.setAttribute("role", "status")
    const heading = document.createElement("strong")
    heading.textContent = title
    toast.append(heading, document.createTextNode(" " + body))
    this.element.append(toast)
    const timer = setTimeout(() => {
      toast.remove()
      this.timers.delete(timer)
    }, 5000)
    this.timers.add(timer)
  }
}
