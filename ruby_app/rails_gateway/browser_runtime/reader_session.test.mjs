import test from "node:test"
import assert from "node:assert/strict"
import { LatencyObservationStore } from "../app/javascript/runtime/latency_observation.js"
import { ReaderSession } from "../app/javascript/runtime/reader_session.js"
import { DEFAULT_READER_PREFS, READER_PREFS_KEY, readerPreferences, loadReaderPreferences, saveReaderPreferences } from "../app/javascript/runtime/reader_preferences.js"

const document = { bookTitle: "Book", chapters: [
  { index: "1", name: "First", text: "First" }, { index: "2.1", name: "Second", text: "Second" },
] }
const layout = {
  version: 1, offsetUnit: "utf16", text: "First\nSecond", css: "",
  pages: [{ html: "<p>First</p>", start: 0, end: 5 }, { html: "<p>Second</p>", start: 5, end: 12 }],
  searchMatches: [{ start: 6, end: 9, pageIndex: 1 }], audioMatch: { start: 6, end: 12, pageIndex: 1 },
  anchors: [{ id: "last", pageIndex: 1 }],
}
const book = (id = "book") => ({ id, file: new File(["source"], "book.epub") })
const make = (options = {}) => new ReaderSession({ inspect: async () => document, render: async () => layout,
  preferences: { ...DEFAULT_READER_PREFS }, savePreferences: () => {}, ...options })
const deferred = () => {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}

test("opening another book and closing invalidate stale asynchronous reads", async () => {
  const first = deferred(), second = deferred()
  const queue = [first, second]
  const session = make({ inspect: () => queue.shift().promise })
  const a = session.open(book("a")), b = session.open(book("b"))
  second.resolve(document)
  await b
  first.resolve({ ...document, bookTitle: "Obsolete" })
  await a
  assert.equal(session.state.bookId, "b")
  assert.equal(session.state.title, "Book")
  const pending = deferred()
  session.render = () => pending.promise
  const search = session.search("pending")
  session.close()
  pending.resolve(layout)
  await search
  assert.equal(session.state.phase, "idle")
  assert.equal(session.state.result, null)
})

test("latest search result wins and returned match/page mappings drive navigation", async () => {
  const session = make()
  await session.open(book())
  const first = deferred(), second = deferred()
  const queue = [first, second]
  session.render = () => queue.shift().promise
  const a = session.search("a"), b = session.search("b")
  second.resolve(layout)
  await b
  first.resolve({ ...layout, searchMatches: [] })
  await a
  assert.equal(session.state.query, "b")
  assert.equal(session.state.pageIndex, 1)
  session.setPage(0)
  session.moveMatch(1)
  assert.equal(session.state.pageIndex, 1)
  assert.equal(session.state.matchIndex, 0)
})

test("literal chapter identity and returned anchor mappings control internal links", async () => {
  const session = make()
  await session.open(book())
  await session.selectChapter("2.1", "last")
  assert.equal(session.state.chapterIndex, "2.1")
  assert.equal(session.state.pageIndex, 1)
  await session.selectChapter("../../untrusted")
  assert.equal(session.state.chapterIndex, "2.1")
})

test("previous match starts at the last result after changing chapters", async () => {
  const result = { ...layout, searchMatches: [layout.searchMatches[0], { start: 0, end: 2, pageIndex: 0 }] }
  const session = make({ render: async () => result })
  await session.open(book())
  await session.search("retained query")
  await session.selectChapter("2.1")
  session.moveMatch(-1)
  assert.equal(session.state.matchIndex, 1)
  assert.equal(session.state.pageIndex, 0)
})

test("manual navigation pauses following until narration changes chapter, without persisting the pause", async () => {
  const saved = []
  const session = make({ savePreferences: (prefs) => saved.push(prefs) })
  await session.open(book())
  await session.followAudio({ bookId: "other", chapterIndex: "2.1", segmentText: "other" })
  assert.equal(session.state.chapterIndex, "1")
  await session.followAudio({ bookId: "book", chapterIndex: "1", segmentText: "first" })
  assert.equal(session.state.pageIndex, 1)
  await session.selectChapter("2.1")
  session.setPage(0)
  await session.setPreferences({ ...session.state.preferences, theme: "ink" })
  await session.followAudio({ bookId: "book", chapterIndex: "1", segmentText: "next" })
  assert.equal(session.state.chapterIndex, "2.1")
  assert.equal(session.state.pageIndex, 0)
  assert.equal(session.state.followPaused, true)
  assert.equal(saved[0].followAudio, true)
  await session.followAudio({ bookId: "book", chapterIndex: "2.1", segmentText: "changed" })
  assert.equal(session.state.followPaused, false)
  assert.equal(session.state.pageIndex, 1)
})

test("loading errors can retry and empty documents remain distinguishable", async () => {
  const session = make({ inspect: async () => { throw new Error("Reader unavailable") } })
  await session.open(book())
  assert.equal(session.state.phase, "error")
  assert.equal(session.state.error, "Reader unavailable")
  session.inspect = async () => ({ chapters: [] })
  await session.retry()
  assert.equal(session.state.phase, "empty")
  assert.equal(session.state.result, null)
})

test("preferences preserve the React storage contract and tolerate invalid or blocked storage", () => {
  const data = new Map()
  const storage = { getItem: (key) => data.get(key), setItem: (key, value) => data.set(key, value) }
  const prefs = readerPreferences({ theme: "ink", fontFamily: "sans", fontScale: 1.2, followAudio: false })
  saveReaderPreferences(storage, prefs)
  assert.ok(data.has(READER_PREFS_KEY))
  assert.deepEqual(loadReaderPreferences(storage), prefs)
  data.set(READER_PREFS_KEY, "not json")
  assert.deepEqual(loadReaderPreferences(storage), DEFAULT_READER_PREFS)
  assert.deepEqual(loadReaderPreferences(undefined), DEFAULT_READER_PREFS)
  assert.doesNotThrow(() => saveReaderPreferences(undefined, prefs))
  const invalid = readerPreferences({ theme: "<script>", fontScale: Infinity, widthRem: 1000, lineHeight: -1 })
  assert.equal(invalid.theme, "paper")
  assert.equal(invalid.fontScale, 1.05)
  assert.equal(invalid.widthRem, 68)
  assert.equal(invalid.lineHeight, 1.45)
})

const transitions = (latency) => latency.snapshot().map(({ records }) => records.map(({ transition }) => transition))
const requested = [ "open_requested" ]
const cancelled = [ ...requested, "cancelled" ]
const ready = [ ...requested, "readable_content", "controls_usable" ]

test("reader-open readiness waits for the rendered page and controls", async () => {
  let now = 0
  const latency = new LatencyObservationStore(() => now)
  const pending = deferred()
  const rendering = deferred()
  const session = make({
    latency,
    inspect: async () => { now = 25; return document },
    render: () => { rendering.resolve(); return pending.promise },
  })
  const opening = session.open(book())
  await rendering.promise
  assert.equal(session.state.phase, "loading")
  assert.deepEqual(transitions(latency), [ requested ])
  assert.equal(latency.snapshot()[0].terminal, false)
  let readyWasPublished = false
  session.subscribe((state) => {
    if (state.phase === "ready") {
      now = 85
      readyWasPublished = true
    }
  })
  now = 80
  pending.resolve(layout)
  await opening
  assert.equal(readyWasPublished, true)
  assert.deepEqual(transitions(latency), [ ready ])
  assert.deepEqual(latency.snapshot()[0].records.map(({ elapsedMs }) => elapsedMs), [0, 85, 85])
  assert.equal(latency.snapshot()[0].terminal, true)
  await session.search("Second")
  assert.deepEqual(transitions(latency), [ ready ])
})

test("reader-open cancels failed rendering and measures a successful retry separately", async () => {
  let now = 0
  const latency = new LatencyObservationStore(() => now)
  const pending = deferred()
  const session = make({ latency, render: () => pending.promise })
  const opening = session.open(book())
  now = 30
  pending.reject(new Error("Rendering unavailable"))
  await opening
  assert.equal(session.state.phase, "error")
  assert.equal(session.state.error, "Rendering unavailable")
  assert.deepEqual(transitions(latency), [ cancelled ])
  assert.equal(latency.snapshot()[0].terminal, true)

  session.inspect = () => assert.fail("Retried rendering should reuse the inspected document")
  session.render = async () => { now = 60; return layout }
  await session.retry()
  assert.equal(session.state.phase, "ready")
  assert.deepEqual(transitions(latency), [ cancelled, ready ])
  assert.deepEqual(latency.snapshot()[1].records.map(({ elapsedMs }) => elapsedMs), [0, 30, 30])

  session.render = async () => { throw new Error("Search unavailable") }
  await session.search("Second")
  assert.equal(session.state.phase, "error")
  session.render = async () => layout
  await session.retry()
  assert.equal(session.state.phase, "ready")
  assert.deepEqual(transitions(latency), [ cancelled, ready ])
})

test("reader-open cancels empty documents and empty render results", async () => {
  const latency = new LatencyObservationStore(() => 0)
  const session = make({
    latency,
    inspect: async () => ({ ...document, chapters: [] }),
    render: () => assert.fail("An empty document should not render a chapter"),
  })
  await session.open(book())
  assert.equal(session.state.phase, "empty")
  session.inspect = async () => document
  session.render = async () => ({ ...layout, pages: [] })
  await session.open(book())
  assert.equal(session.state.phase, "empty")
  assert.deepEqual(transitions(latency), [ cancelled, cancelled ])
  assert.ok(latency.snapshot().every(({ terminal }) => terminal))
})

test("reader-open cancels on close and gives only the replacement book credit for stale rendering", async () => {
  const latency = new LatencyObservationStore(() => 0)
  const pending = [ deferred(), deferred(), deferred() ]
  const session = make({ latency, render: () => pending.shift().promise })

  const closedRender = pending[0]
  const closed = session.open(book("closed"))
  await Promise.resolve()
  session.close()
  assert.deepEqual(transitions(latency), [ cancelled ])
  closedRender.resolve(layout)
  await closed
  assert.equal(session.state.phase, "idle")

  const [ oldRender, replacementRender ] = pending
  const old = session.open(book("old"))
  await Promise.resolve()
  const replacement = session.open(book("replacement"))
  await Promise.resolve()
  assert.deepEqual(transitions(latency), [ cancelled, cancelled, requested ])
  oldRender.reject(new Error("Obsolete error"))
  await old
  assert.equal(session.state.phase, "loading")
  replacementRender.resolve(layout)
  await replacement
  assert.equal(session.state.bookId, "replacement")
  assert.deepEqual(transitions(latency), [ cancelled, cancelled, ready ])
})

test("reader-open follows the latest rendering of the same book", async () => {
  const latency = new LatencyObservationStore(() => 0)
  const initial = deferred(), updated = deferred()
  const renders = [ initial, updated ]
  const session = make({ latency, render: () => renders.shift().promise })
  const opening = session.open(book())
  await Promise.resolve()
  const searching = session.search("Second")
  initial.resolve(layout)
  await opening
  assert.deepEqual(transitions(latency), [ requested ])
  updated.resolve(layout)
  await searching
  assert.equal(session.state.phase, "ready")
  assert.equal(session.state.pageIndex, 1)
  assert.deepEqual(transitions(latency), [ ready ])
})
