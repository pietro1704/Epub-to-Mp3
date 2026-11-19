import { Controller } from "@hotwired/stimulus"

/** Opens and closes the help drawer; the overlay and Escape close it. */
export default class extends Controller {
  static targets = ["toggle", "overlay", "drawer"]

  open() {
    this.setOpen(true)
  }

  close() {
    this.setOpen(false)
  }

  /** @param {boolean} open */
  setOpen(open) {
    this.toggleTarget.setAttribute("aria-expanded", String(open))
    this.drawerTarget.classList.toggle("help-drawer--open", open)
    this.drawerTarget.setAttribute("aria-hidden", String(!open))
    this.drawerTarget.inert = !open
    this.overlayTarget.hidden = !open
  }
}
