import { Controller } from "@hotwired/stimulus"
import { readerSession } from "runtime/workspace_store"
import { readerPreferences } from "runtime/reader_preferences"

// Turbo can replace the nonce meta tag while the initial HTTP document's CSP
// remains in force. This module shares that document's JS realm and lifetime.
const documentStyleNonce = document.querySelector('meta[name="csp-nonce"]')?.content ?? ""

/** Presentation only: book markup and all text mappings come from Rust. */
export default class extends Controller {
  static targets = [
    "inline", "dialog", "content", "title", "author", "chapters", "chapterRow", "chapterName",
    "loading", "error", "errorDetail", "empty", "article", "host", "previous", "next", "pageLabel",
    "search", "matches", "previousMatch", "nextMatch", "preference", "popup", "exitPopup", "follow",
  ]
  static values = { page: String, matches: String, following: String, manual: String, stylesheet: String }

  connect() { this.unsubscribe = readerSession.subscribe((state) => this.render(state)) }
  disconnect() { this.unsubscribe?.(); if (this.dialogTarget.open) this.dialogTarget.close() }

  selectChapter(event) { readerSession.selectChapter(event.currentTarget.dataset.chapterIndex) }
  previous() { readerSession.setPage(readerSession.state.pageIndex - 1) }
  next() { readerSession.setPage(readerSession.state.pageIndex + 1) }
  search() { readerSession.search(this.searchTarget.value) }
  previousMatch() { readerSession.moveMatch(-1) }
  nextMatch() { readerSession.moveMatch(1) }
  retry() { readerSession.retry() }
  close() { readerSession.close() }
  popup() { readerSession.setModal(true) }
  exitPopup() { readerSession.setModal(false) }
  cancelPopup(event) { event.preventDefault(); this.exitPopup() }

  preference(event) {
    const input = event.target
    const value = input.type === "checkbox" ? input.checked : input.type === "range" ? Number(input.value) : input.value
    readerSession.setPreferences(readerPreferences({ ...readerSession.state.preferences, [input.dataset.preference]: value }))
  }

  keyDown(event) {
    if (event.target.closest("input, textarea, select") || event.target.isContentEditable || readerSession.state.phase !== "ready") return
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault()
      event.key === "ArrowLeft" ? this.previous() : this.next()
    }
  }

  followLink(event) {
    const anchor = event.composedPath().find((node) => node instanceof Element && node.matches("a[data-reader-chapter]"))
    if (!anchor) return
    event.preventDefault()
    readerSession.selectChapter(anchor.dataset.readerChapter, anchor.dataset.readerFragment ?? "")
  }

  format(template, values) {
    return template.replace(/\{(\w+)\}/g, (match, key) => values[key] ?? match)
  }

  render(state) {
    this.element.hidden = !state.bookId
    if (!state.bookId) {
      this.syncPopup(false)
      this.hostTarget.shadowRoot?.replaceChildren()
      this.renderedHtml = undefined
      this.openedBookId = null
      return
    }
    this.titleTarget.textContent = state.title
    this.authorTarget.textContent = state.author
    this.loadingTarget.hidden = state.phase !== "loading"
    this.errorTarget.hidden = state.phase !== "error"
    this.errorDetailTarget.textContent = state.error
    this.emptyTarget.hidden = state.phase !== "empty"
    this.articleTarget.hidden = state.phase !== "ready"
    this.element.setAttribute("aria-busy", String(state.phase === "loading"))
    this.syncChapters(state)
    const chapter = state.chapters.find((chapter) => chapter.index === state.chapterIndex)
    this.chapterNameTarget.textContent = chapter?.name ?? ""
    const total = state.result?.pages.length ?? 0
    this.pageLabelTarget.textContent = this.format(this.pageValue, { current: total ? state.pageIndex + 1 : 0, total })
    this.previousTarget.disabled = state.phase !== "ready" || state.pageIndex <= 0
    this.nextTarget.disabled = state.phase !== "ready" || state.pageIndex >= total - 1
    const matches = state.result?.searchMatches.length ?? 0
    this.matchesTarget.textContent = this.format(this.matchesValue, { current: state.matchIndex < 0 ? 0 : state.matchIndex + 1, total: matches })
    this.previousMatchTarget.disabled = this.nextMatchTarget.disabled = !matches || state.phase !== "ready"
    if (this.searchTarget.value !== state.query) this.searchTarget.value = state.query
    for (const input of this.preferenceTargets) {
      const value = state.preferences[input.dataset.preference]
      if (input.type === "checkbox") input.checked = value
      else input.value = value
    }
    this.followTarget.textContent = state.preferences.followAudio && !state.followPaused ? this.followingValue : this.manualValue
    this.contentTarget.dataset.theme = state.preferences.theme
    this.hostTarget.style.setProperty("--reader-font-scale", state.preferences.fontScale)
    this.hostTarget.style.setProperty("--reader-line-height", state.preferences.lineHeight)
    this.hostTarget.style.setProperty("--reader-font-family", state.preferences.fontFamily === "sans" ? 'Arial, sans-serif' : 'Georgia, serif')
    this.articleTarget.style.setProperty("--reader-width", `${state.preferences.widthRem}rem`)
    if (state.phase === "ready") this.renderPage(state)
    this.syncPopup(state.modal)
    if (state.phase === "ready" && this.openedBookId !== state.bookId) {
      this.openedBookId = state.bookId
      if (!state.modal) {
        this.element.scrollIntoView({ block: "start" })
        this.articleTarget.focus({ preventScroll: true })
      }
    }
  }

  syncChapters(state) {
    // Preserve focus when only the selected chapter or loading state changes.
    const identity = JSON.stringify(state.chapters.map(({ index, name }) => [index, name]))
    if (identity !== this.chapterIdentity) {
      this.chapterIdentity = identity
      this.chaptersTarget.replaceChildren(...state.chapters.map((chapter) => {
        const button = this.chapterRowTarget.content.firstElementChild.cloneNode(true)
        button.dataset.chapterIndex = chapter.index
        button.textContent = chapter.name
        return button
      }))
    }
    for (const button of this.chaptersTarget.children) {
      button.setAttribute("aria-current", String(button.dataset.chapterIndex === String(state.chapterIndex)))
    }
  }

  renderPage(state) {
    const html = state.result.pages[state.pageIndex]?.html ?? ""
    const css = state.result.css
    const shadow = this.hostTarget.shadowRoot ?? this.hostTarget.attachShadow({ mode: "open" })
    if (html !== this.renderedHtml || css !== this.renderedCss) {
      const stylesheet = document.createElement("link")
      stylesheet.rel = "stylesheet"
      stylesheet.href = this.stylesheetValue
      const style = document.createElement("style")
      style.nonce = documentStyleNonce
      style.textContent = css
      const article = document.createElement("div")
      article.className = "reader-root"
      article.innerHTML = html // Only reader_chapter_json_v1's sanitised output reaches this sink.
      shadow.replaceChildren(stylesheet, style, article)
      this.renderedHtml = html
      this.renderedCss = css
    }
    for (const mark of shadow.querySelectorAll("[data-reader-search]")) {
      mark.classList.toggle("is-current-search", mark.getAttribute("data-reader-search") === String(state.matchIndex))
    }
  }

  syncPopup(open) {
    this.popupTarget.hidden = open
    this.exitPopupTarget.hidden = !open
    if (open && !this.dialogTarget.open) {
      this.dialogTarget.append(this.contentTarget)
      this.dialogTarget.showModal()
    } else if (!open && this.dialogTarget.open) {
      this.inlineTarget.append(this.contentTarget)
      this.dialogTarget.close()
      if (!this.element.hidden) this.popupTarget.focus()
    }
  }
}
