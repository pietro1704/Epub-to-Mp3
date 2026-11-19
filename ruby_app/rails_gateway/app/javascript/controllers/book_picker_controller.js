import { Controller } from "@hotwired/stimulus"
import { bookQueue, conversionWorkspace, readerSession } from "runtime/workspace_store"

export default class extends Controller {
  static targets = ["files", "folder", "list", "row", "empty", "count", "error", "submit", "chapters", "language"]
  static outlets = [ "narration-policy" ]
  static values = {
    uploading: String, ready: String, failed: String, idle: String, busy: String, missing: String,
    oversized: String, unsupported: String, sampleFailed: String,
  }

  connect() {
    this.unsubscribe = bookQueue.subscribe((books) => this.render(books))
    conversionWorkspace().then((workspace) => {
      if (!this.element.isConnected) return
      this.workspace = workspace
      this.unsubscribeWorkspace = workspace.subscribe((state) => this.showWorkspaceError(state.error))
    })
  }
  disconnect() {
    this.unsubscribe?.()
    this.unsubscribeWorkspace?.()
  }

  reset() {
    this.element.reset()
    for (const book of bookQueue.snapshot()) bookQueue.remove(book.id)
    this.showError("")
  }

  choose(event) {
    this.add(event.target.files)
    event.target.value = ""
  }

  folder() { this.folderTarget.click() }

  add(files) {
    const messages = { oversized: this.oversizedValue, unsupported: this.unsupportedValue }
    this.showError(bookQueue.add(files).map(({ code, fileName }) => `${fileName}: ${messages[code]}`).join("\n"))
  }

  dragOver(event) { event.preventDefault() }

  drop(event) {
    event.preventDefault()
    if (event.dataTransfer.files.length) {
      this.add(event.dataTransfer.files)
      return
    }
    const id = event.dataTransfer.getData("application/x-epub-queue-id")
    const row = event.target.closest("[data-book-id]")
    const books = bookQueue.snapshot()
    const index = books.findIndex((book) => book.id === row?.dataset.bookId)
    const after = row && event.clientY > row.getBoundingClientRect().top + row.getBoundingClientRect().height / 2
    bookQueue.moveTo(id, index < 0 ? books.length : index + Number(after))
  }

  dragStart(event) {
    const row = event.target.closest("[data-book-id]")
    event.dataTransfer.setData("application/x-epub-queue-id", row.dataset.bookId)
    event.dataTransfer.effectAllowed = "move"
  }

  remove(event) { bookQueue.remove(this.bookId(event)) }
  read(event) {
    const book = bookQueue.snapshot().find((book) => book.id === this.bookId(event))
    if (book?.status === "ready") readerSession.open(book)
  }
  up(event) { bookQueue.move(this.bookId(event), -1) }
  down(event) { bookQueue.move(this.bookId(event), 1) }
  bookId(event) { return event.target.closest("[data-book-id]").dataset.bookId }

  async sample(event) {
    const button = event.currentTarget
    button.disabled = true
    try {
      const response = await fetch("/sample.epub")
      if (!response.ok) throw new Error(`Sample request failed: HTTP ${response.status}`)
      this.add([new File([await response.blob()], "sample.epub", { type: "application/epub+zip" })])
    } catch {
      this.showError(this.sampleFailedValue)
    } finally { button.disabled = false }
  }

  async submit(event) {
    event.preventDefault()
    this.submitTarget.disabled = true
    this.submitTarget.textContent = this.busyValue
    this.showError("")
    try {
      const books = await bookQueue.readyBooks()
      if (!this.element.isConnected) return
      this.showError(books.length ? "" : this.missingValue)
      if (books.length) this.start(books, await conversionWorkspace())
    } finally {
      this.submitTarget.disabled = false
      this.submitTarget.textContent = this.idleValue
    }
  }

  /**
   * Starts a batch, or queues the books after the running one (P-16, P-17).
   * The workspace reports a rejected start as state.error.
   */
  start(books, workspace) {
    const language = this.languageTarget.value
    const preferences = this.hasNarrationPolicyOutlet ? this.narrationPolicyOutlet.capture() : undefined
    const items = books.map((book) => ({
      preferences, document: book.document, fileName: book.file.name, bookId: book.id,
      chapters: this.chaptersTarget.value.trim() || undefined, language: language === "auto" ? undefined : language,
    }))
    let started
    if (workspace.state.phase === "converting") started = workspace.enqueue(items)
    // A paused batch keeps its books; the new ones join it and it resumes.
    else if (workspace.state.queuePaused) started = workspace.enqueue(items).then(() => workspace.resumeQueue())
    else started = workspace.submit(items)
    started.catch((error) => console.error(error))
  }

  /** @param {string | undefined} message */
  showWorkspaceError(message) {
    if (message) this.showError(message)
  }

  showError(message) {
    this.errorTarget.textContent = message
    this.errorTarget.hidden = !message
  }

  render(books) {
    const focused = document.activeElement
    const focusedId = focused?.closest("[data-book-id]")?.dataset.bookId
    const focusedAction = focused?.getAttribute("data-action")
    this.countTarget.textContent = String(books.length)
    this.emptyTarget.hidden = books.length > 0
    this.listTarget.replaceChildren(...books.map((book, index) => {
      const row = this.rowTarget.content.firstElementChild.cloneNode(true)
      row.dataset.bookId = book.id
      row.dataset.status = book.status
      const text = (field, value) => { row.querySelector(`[data-field=${field}]`).textContent = value }
      text("name", `${index + 1}. ${book.file.name}`)
      text("title", book.document?.bookTitle ?? "")
      text("author", book.document?.bookAuthor ?? "")
      text("size", `${(book.file.size / 1024 / 1024).toFixed(2)} MB`)
      text("status", book.status === "ready" ? this.readyValue : book.status === "error" ? this.failedValue : this.uploadingValue)
      text("error", book.error ?? "")
      row.querySelector("[data-field=error]").hidden = !book.error
      row.querySelector("[data-action='book-picker#up']").disabled = index === 0
      row.querySelector("[data-action='book-picker#down']").disabled = index === books.length - 1
      row.querySelector("[data-action='book-picker#read']").disabled = book.status !== "ready"
      return row
    }))
    if (focusedId && focusedAction) {
      const row = Array.from(this.listTarget.children).find((row) => row.dataset.bookId === focusedId)
      const button = row?.querySelector(`[data-action='${focusedAction}']`)
      if (button && !button.disabled) button.focus()
    }
  }
}
