import { Controller } from "@hotwired/stimulus"

const FOCUSABLE = "a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), " +
  "textarea:not([disabled]), [tabindex]:not([tabindex='-1']):not([disabled])"

/**
 * Opens and closes the help drawer; the overlay and Escape close it. While it
 * is open, keyboard focus stays inside the drawer, and closing it returns
 * focus to the toggle.
 */
export default class extends Controller {
  static targets = ["toggle", "overlay", "drawer"]

  initialize() {
    this.trapFocus = this.trapFocus.bind(this)
    this.closeBeforeCache = () => this.setOpen(false)
  }

  connect() {
    // A snapshot taken while open would come back open without its focus trap.
    document.addEventListener("turbo:before-cache", this.closeBeforeCache)
    if (this.isOpen) document.addEventListener("keydown", this.trapFocus)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.closeBeforeCache)
    document.removeEventListener("keydown", this.trapFocus)
  }

  open() {
    if (this.isOpen) return
    this.setOpen(true)
    // The drawer is fixed, so focusing it during the slide does not scroll the page.
    this.focusableElements[0]?.focus({ preventScroll: true })
  }

  close() {
    if (!this.isOpen) return
    this.setOpen(false)
    this.toggleTarget.focus()
  }

  get isOpen() {
    return this.drawerTarget.classList.contains("help-drawer--open")
  }

  get focusableElements() {
    return [ ...this.drawerTarget.querySelectorAll(FOCUSABLE) ].filter((element) => !element.closest("[hidden]"))
  }

  /** @param {boolean} open */
  setOpen(open) {
    if (open) document.addEventListener("keydown", this.trapFocus)
    else document.removeEventListener("keydown", this.trapFocus)
    this.toggleTarget.setAttribute("aria-expanded", String(open))
    this.drawerTarget.classList.toggle("help-drawer--open", open)
    this.drawerTarget.setAttribute("aria-hidden", String(!open))
    this.drawerTarget.inert = !open
    this.overlayTarget.hidden = !open
  }

  /** Wraps Tab and Shift+Tab between the drawer's first and last controls. */
  trapFocus(event) {
    if (event.key !== "Tab") return
    const focusable = this.focusableElements
    if (focusable.length === 0) return
    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    const inside = this.drawerTarget.contains(document.activeElement)
    if (event.shiftKey && (!inside || document.activeElement === first)) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && (!inside || document.activeElement === last)) {
      event.preventDefault()
      first.focus()
    }
  }
}
