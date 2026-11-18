import test from "node:test"
import assert from "node:assert/strict"
import { BookQueue, MAX_BOOK_BYTES } from "../app/javascript/runtime/book_queue.js"

const book = (name = "book.epub") => new File(["epub bytes"], name)
const document = { bookTitle: "Book", bookAuthor: "Author", chapters: [] }
const deferred = () => {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}

test("file validation never inspects or queues unsupported and oversized books", async () => {
  const seen = []
  const queue = new BookQueue(async (file) => { seen.push(file.name); return document })
  const oversized = { name: "large.epub", size: MAX_BOOK_BYTES + 1 }
  const errors = queue.add([book("notes.pdf"), oversized, book("valid.EPUB")])
  assert.deepEqual(errors, [
    { code: "unsupported", fileName: "notes.pdf" },
    { code: "oversized", fileName: "large.epub" },
  ])
  assert.equal(queue.snapshot().length, 1)
  assert.equal(queue.snapshot()[0].status, "uploading")
  assert.deepEqual((await queue.readyBooks()).map((entry) => entry.file.name), ["valid.EPUB"])
  assert.deepEqual(seen, ["valid.EPUB"])
})

test("duplicate additions keep independent identities and removal wins over inspection", async () => {
  const inspection = deferred()
  const queue = new BookQueue(() => inspection.promise)
  const file = book()
  queue.add([file, file])
  const [first, second] = queue.snapshot()
  assert.notEqual(first.id, second.id)
  queue.remove(first.id)
  inspection.resolve(document)
  assert.deepEqual((await queue.readyBooks()).map((entry) => entry.id), [second.id])
  assert.equal(queue.snapshot().length, 1)
})

test("validation waits for additions, respects reordered entries, excludes failed inspections", async () => {
  const one = deferred(), two = deferred(), three = deferred()
  const pending = [one, two, three]
  const queue = new BookQueue(() => pending.shift().promise)
  queue.add([book("one.epub"), book("two.epub")])
  let settled = false
  const ready = queue.readyBooks().then((entries) => { settled = true; return entries })
  queue.add([book("three.epub")])
  queue.moveTo(queue.snapshot()[2].id, 0)
  await Promise.resolve()
  one.resolve(document)
  two.reject(new Error("Broken EPUB"))
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(settled, false)
  three.resolve(document)
  assert.deepEqual((await ready).map((entry) => entry.file.name), ["three.epub", "one.epub"])
  assert.equal(queue.snapshot()[2].status, "error")
  assert.equal(queue.snapshot()[2].error, "Broken EPUB")
})

test("buttons and insertion boundaries preserve submission order and ignore stale IDs", async () => {
  const queue = new BookQueue(async () => document)
  queue.add([book("a.epub"), book("b.epub"), book("c.epub")])
  const [a, b, c] = queue.snapshot()
  queue.move(a.id, -1)
  queue.move(c.id, 1)
  assert.deepEqual(queue.snapshot().map((entry) => entry.id), [a.id, b.id, c.id])
  queue.move(b.id, -1)
  queue.move(c.id, -1)
  queue.moveTo(b.id, 3)
  queue.moveTo("removed", 0)
  assert.deepEqual((await queue.readyBooks()).map((entry) => entry.id), [c.id, a.id, b.id])
})

test("disconnecting and remounting observers preserves File ownership and emits current state", async () => {
  const queue = new BookQueue(async () => document)
  const snapshots = []
  const disconnect = queue.subscribe((state) => snapshots.push(state))
  const file = book()
  queue.add([file])
  disconnect()
  const calls = snapshots.length
  await queue.readyBooks()
  assert.equal(snapshots.length, calls)
  queue.subscribe((state) => {
    assert.equal(state[0].file, file)
    assert.equal(state[0].document.bookTitle, "Book")
    state.pop()
  })
  assert.equal(queue.snapshot().length, 1)
})
