import { Controller } from "@hotwired/stimulus"

const DARK_SCHEME = "(prefers-color-scheme: dark)"
const THEME_CLASSES = ["theme-light", "theme-dark"]

/**
 * Keeps the theme class on <html>. The server renders an explicit choice on
 * the first byte; in "auto" this controller follows the operating system.
 */
export default class extends Controller {
  static values = { mode: String }

  connect() {
    this.scheme = window.matchMedia(DARK_SCHEME)
    this.followScheme = () => this.apply()
    this.scheme.addEventListener("change", this.followScheme)
    this.apply()
  }

  disconnect() {
    this.scheme.removeEventListener("change", this.followScheme)
  }

  apply() {
    const theme = this.modeValue === "auto" ? (this.scheme.matches ? "dark" : "light") : this.modeValue
    const root = document.documentElement
    root.classList.remove(...THEME_CLASSES)
    root.classList.add(`theme-${theme}`)
  }
}
