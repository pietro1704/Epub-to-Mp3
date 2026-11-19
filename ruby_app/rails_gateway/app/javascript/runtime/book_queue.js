export const MAX_BOOK_BYTES = 100 * 1024 * 1024

/**
 * Browser-owned pending books. A removed entry can never be resurrected by an
 * inspection completion. Files and documents remain in this JS realm only.
 * @typedef {{bookTitle?: string, bookAuthor?: string, chapters: object[]}} BookDocument
 * @typedef {{id: string, file: File, status: string, document?: BookDocument, error?: string}} QueuedBook
 * @typedef {{code: "oversized" | "unsupported", fileName: string}} BookValidationError
 */
export class BookQueue {
  /** @param {(file: File) => Promise<BookDocument>} inspect */
  constructor(inspect) {
    this.inspect = inspect
    /** @type {QueuedBook[]} */
    this.books = []
    this.listeners = new Set()
    this.pending = new Map()
  }

  snapshot() { return this.books.map((book) => ({ ...book })) }

  subscribe(listener) {
    this.listeners.add(listener)
    listener(this.snapshot())
    return () => this.listeners.delete(listener)
  }

  notify() { for (const listener of this.listeners) listener(this.snapshot()) }

  /** @param {Iterable<File>} files @returns {BookValidationError[]} validation errors */
  add(files) {
    const errors = []
    for (const file of files) {
      if (file.size > MAX_BOOK_BYTES) {
        errors.push({ code: "oversized", fileName: file.name })
        continue
      }
      if (!/\.epub$/i.test(file.name)) {
        errors.push({ code: "unsupported", fileName: file.name })
        continue
      }
      const book = { id: crypto.randomUUID(), file, status: "uploading" }
      this.books.push(book)
      const inspection = Promise.resolve().then(() => this.inspect(file)).then(
        (document) => this.update(book.id, { status: "ready", document }),
        (error) => this.update(book.id, { status: "error", error: String(error?.message ?? error) }),
      ).finally(() => this.pending.delete(book.id))
      this.pending.set(book.id, inspection)
    }
    this.notify()
    return errors
  }

  update(id, values) {
    this.books = this.books.map((book) => book.id === id ? { ...book, ...values } : book)
    this.notify()
  }

  remove(id) {
    this.books = this.books.filter((book) => book.id !== id)
    this.notify()
  }

  /** Move to an insertion boundary in the current order (0 through length). */
  moveTo(id, boundary) {
    const from = this.books.findIndex((book) => book.id === id)
    if (from < 0 || boundary < 0 || boundary > this.books.length) return
    const [book] = this.books.splice(from, 1)
    this.books.splice(boundary > from ? boundary - 1 : boundary, 0, book)
    this.notify()
  }

  move(id, direction) {
    const index = this.books.findIndex((book) => book.id === id)
    if (index >= 0) this.moveTo(id, direction < 0 ? index - 1 : index + 2)
  }

  /** Wait for all currently queued inspections, including additions while waiting. */
  async readyBooks() {
    while (true) {
      const pending = this.books.map((book) => this.pending.get(book.id)).filter(Boolean)
      if (!pending.length) return this.snapshot().filter((book) => book.status === "ready")
      await Promise.all(pending)
    }
  }
}
