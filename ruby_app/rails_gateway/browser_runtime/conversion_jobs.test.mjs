import test from "node:test"
import assert from "node:assert/strict"
import { MemoryJobStore } from "../app/javascript/runtime/job_store.js"
import { JobRepository } from "../app/javascript/runtime/job_repository.js"
import { JobExecution } from "../app/javascript/runtime/job_execution.js"
import { CHAPTER_RANGE_ERROR, CHAPTER_RANGE_FORMAT_ERROR, ConversionClient, EDGE_UNAVAILABLE_ERROR } from "../app/javascript/runtime/conversion_client.js"
import { ConversionWorkspace, PENDING_BATCH_KEY } from "../app/javascript/runtime/conversion_workspace.js"
import { TtsPreparationError } from "../app/javascript/runtime/conversion_runtime.js"
import { edge, faber, system } from "../app/javascript/runtime/tts_preferences.js"

// Object URLs are counted, not created, so tests see exactly what is published.
const urls = { created: 0, revoked: [] }
URL.createObjectURL = () => `blob:fixture-${++urls.created}`
URL.revokeObjectURL = (url) => { urls.revoked.push(url) }
globalThis.fetch = () => { throw new Error("No network allowed") }

const book = (count = 2) => ({
  bookTitle: "Fixture", bookAuthor: "Author",
  chapters: Array.from({ length: count }, (_, index) => ({ name: `Chapter ${index}`, text: "Texto" })),
})
const strict = () => ({ primary: { ...faber }, secondary: null, allow_online_fallback: false })

/**
 * A ConversionSession double: one segment per chapter, in order, starting at
 * the listening position when one is set.
 */
function sessionFor(chapters, calls) {
  let cursor = 0
  return {
    next_segment: () => {
      calls.next++
      const chapter = chapters[cursor]
      return chapter ? JSON.stringify({ chapter: chapter.index, index: 0, total: 1, text: chapter.text, selection: faber, fallback_used: false }) : "null"
    },
    provider_failed: () => { calls.providerFailed++ },
    accept_audio: () => { calls.accepted++; cursor++; return true },
    chapter_audio: () => new Uint8Array([ 1, 2 ]),
    set_listening_position_json_v2: (json) => {
      const { chapter_index } = JSON.parse(json)
      calls.positions.push(chapter_index)
      cursor = chapters.findIndex((chapter) => chapter.index === chapter_index)
    },
    skip_cached_chapter_v2: () => { cursor++ },
    cancel: () => { calls.cancelled++ },
    free: () => { calls.freed++ },
  }
}

function fixture({ store = new MemoryJobStore(), synthesize, create, audioUse = async () => true } = {}) {
  const calls = { next: 0, accepted: 0, providerFailed: 0, cancelled: 0, freed: 0, created: [], synthesized: [], positions: [] }
  const runtime = {
    validateSelection: async () => {},
    capturePreferences: async (preferences) => structuredClone(preferences),
    create: create ?? (async (chapters, preferences, language, policyState) => {
      calls.created.push({ chapters: chapters.map((chapter) => chapter.index), preferences, language, policyState })
      return sessionFor(chapters, calls)
    }),
    synthesize: synthesize ?? (async (text) => { calls.synthesized.push(text); return new Uint8Array([ 1, 2 ]) }),
    cancelSynthesis: () => { calls.cancelSynthesis = (calls.cancelSynthesis ?? 0) + 1 },
  }
  const repository = new JobRepository(store, audioUse)
  const execution = new JobExecution({ runtime, repository, seal: async () => undefined })
  let saved = strict()
  let ids = 0
  const client = new ConversionClient({ runtime, repository, execution, loadPreferences: () => saved, randomId: () => `job-${++ids}` })
  return { client, runtime, calls, store, setSaved: (value) => { saved = value } }
}
const poll = (client, jobId) => client.poll(jobId, { intervalMs: 1 })

test("a range converts exactly the selected chapters with the immutable captured policy", async () => {
  const { client, calls } = fixture()
  const preferences = strict()
  const { jobId } = await client.submit({ document: book(3), chapters: "2-3", preferences })
  preferences.primary.engine = "edge"
  const result = await poll(client, jobId)
  assert.equal(result.state, "finished")
  assert.deepEqual(calls.created[0].chapters, [ 1, 2 ])
  assert.equal(calls.created[0].preferences.primary.engine, "piper")
  assert.equal(calls.created[0].language, "pt-BR")
  assert.deepEqual(result.outputs.map((output) => output.name), [ "chapter-2.mp3", "chapter-3.mp3" ])
  assert.equal((await client.getChapterManifest(jobId, 1)).chunks.length, 1)
})

test("invalid ranges, empty text and missing books are rejected before a job exists", async () => {
  const { client, calls } = fixture()
  for (const range of [ "0", "3-1", "9", "0-1" ]) await assert.rejects(client.submit({ document: book(2), chapters: range }), new RegExp(CHAPTER_RANGE_ERROR.replace(".", "\\.")))
  for (const range of [ "one", "1-", "1,2" ]) await assert.rejects(client.submit({ document: book(2), chapters: range }), (error) => error.message === CHAPTER_RANGE_FORMAT_ERROR)
  await assert.rejects(client.submit({ document: { chapters: [ { name: "Blank", text: "  " } ] } }), /no readable text/)
  await assert.rejects(client.submit({}), /Select an EPUB/)
  assert.equal(calls.created.length, 0)
  assert.deepEqual(await client.getRecentJobs(), [])
})

test("language: explicit choice, then the EPUB language, then pt-BR", async () => {
  const { client, calls } = fixture()
  await poll(client, (await client.submit({ document: book(1), language: "en-US" })).jobId)
  await poll(client, (await client.submit({ document: { ...book(1), language: "es" }, language: "" })).jobId)
  await poll(client, (await client.submit({ document: book(1) })).jobId)
  assert.deepEqual(calls.created.map((call) => call.language), [ "en-US", "es", "pt-BR" ])
})

test("Edge and system primaries are rejected with the explicit message and no network request", async () => {
  const { client, calls } = fixture()
  for (const preferences of [ { ...strict(), primary: { ...edge } }, { ...strict(), primary: { ...system } }, { ...strict(), secondary: { ...edge } } ])
    await assert.rejects(client.submit({ document: book(), preferences }), (error) => error.message === EDGE_UNAVAILABLE_ERROR)
  assert.equal(calls.created.length, 0)
})

test("an unavailable selection is rejected before queuing; the saved default is used when none is given", async () => {
  const { client, runtime, calls, setSaved } = fixture()
  runtime.validateSelection = async (selection) => { if (selection.model_id === "unavailable") throw new Error("Runtime unavailable") }
  await assert.rejects(client.submit({ document: book(), preferences: { ...strict(), primary: { ...faber, model_id: "unavailable" } } }), /Runtime unavailable/)
  setSaved({ ...strict(), primary: { ...faber, model_id: "pt_BR-edresson-low" } })
  const { jobId } = await client.submit({ document: book() })
  assert.equal((await client.fetch(jobId)).voice, "pt_BR-edresson-low")
  await poll(client, jobId)
  assert.equal(calls.created.length, 1)
})

test("a failing primary with a model secondary continues and logs the secondary voice", async () => {
  let attempts = 0
  const { client, calls } = fixture({ synthesize: async () => { if (attempts++ === 0) throw new Error("Faber failed"); return new Uint8Array([ 5 ]) } })
  const preferences = { policy_version: 2, primary: { ...faber }, secondary: { engine: "piper", model_id: "pt_BR-edresson-low", voice: null }, allow_online_fallback: false }
  const result = await poll(client, (await client.submit({ document: book(1), preferences })).jobId)
  assert.equal(result.state, "finished")
  assert.equal(calls.providerFailed, 1)
  assert.deepEqual(result.events, [ "Secondary voice: piper" ])
})

test("a recovered provider failure does not label a later audio commit failure as speech fallback", async () => {
  const store = new MemoryJobStore()
  const save = store.save.bind(store)
  store.save = async job => {
    if (job.audio.length && job.snapshot.state === "running") throw new Error("Local audio storage is full")
    await save(job)
  }
  let attempts = 0
  const { client, calls } = fixture({ store, synthesize: async () => {
    if (++attempts === 1) throw new Error("Primary failed")
    return new Uint8Array([ 5 ])
  } })
  const preferences = { ...strict(), policy_version: 2, secondary: { ...faber, model_id: "pt_BR-edresson-low" } }
  const { jobId } = await client.submit({ document: book(1), preferences })
  const result = await poll(client, jobId)
  assert.equal(calls.providerFailed, 1)
  assert.equal(calls.accepted, 1)
  assert.equal(result.state, "failed")
  assert.match(result.error, /Local audio storage is full/)
  assert.equal(result.errorCategory, undefined)
  assert.equal(await client.getNativePlaybackPolicy(jobId), null)
})

test("with a system secondary a provider failure fails the job as tts_provider and offers browser speech only", async () => {
  const { client, calls } = fixture({ synthesize: async () => { throw new Error("Faber model missing") } })
  const preferences = { policy_version: 2, primary: { ...faber }, secondary: { ...system }, allow_online_fallback: false }
  const { jobId } = await client.submit({ document: book(), preferences })
  const failed = await poll(client, jobId)
  assert.equal(failed.state, "failed")
  assert.equal(failed.errorCategory, "tts_provider")
  assert.deepEqual(failed.outputs, [])
  assert.equal(calls.accepted, 0)
  assert.equal(calls.providerFailed, 0)
  assert.deepEqual(await client.getNativePlaybackPolicy(jobId), { language: "pt-BR", voice: null })
  assert.equal(await client.getChapterManifest(jobId, 0), null)
})

test("a strict job never offers browser speech, and a corrupt saved policy is not a provider failure", async () => {
  const strictFailure = fixture({ synthesize: async () => { throw new Error("Faber model missing") } })
  const { jobId } = await strictFailure.client.submit({ document: book() })
  await poll(strictFailure.client, jobId)
  assert.equal(await strictFailure.client.getNativePlaybackPolicy(jobId), null)
  const corrupt = fixture({ create: async () => { throw new Error("Corrupt saved policy") } })
  const second = await corrupt.client.submit({ document: book(), preferences: { ...strict(), policy_version: 2 } })
  assert.equal((await poll(corrupt.client, second.jobId)).state, "failed")
  assert.equal(await corrupt.client.getNativePlaybackPolicy(second.jobId), null)
})

for (const recovery of [ true, false ]) {
  test(`a Rust preparation rejection fails without MP3 and recovery=${recovery} decides browser speech`, async () => {
    const { client, calls } = fixture({ create: async () => { throw new TtsPreparationError("Language is unavailable in this runtime") } })
    const preferences = recovery ? { ...strict(), policy_version: 2 } : strict()
    const { jobId } = await client.submit({ document: book(), preferences, language: "en-US" })
    const failed = await poll(client, jobId)
    assert.equal(failed.state, "failed")
    assert.equal(failed.errorCategory, "tts_provider")
    assert.deepEqual(failed.outputs, [])
    assert.deepEqual(await client.getNativePlaybackPolicy(jobId), recovery ? { language: "en-US", voice: null } : null)
    assert.equal(calls.synthesized.length, 0)
  })
}

test("cancel before the session is created publishes nothing; a late cancel leaves a finished job intact", async () => {
  const early = fixture()
  const { jobId } = await early.client.submit({ document: book() })
  await early.client.cancel(jobId)
  assert.equal((await poll(early.client, jobId)).state, "cancelled")
  assert.equal(early.calls.accepted, 0)
  const late = fixture()
  const done = await late.client.submit({ document: book() })
  const finished = await poll(late.client, done.jobId)
  assert.deepEqual(await late.client.cancel(done.jobId), { status: "finished" })
  assert.deepEqual(await late.client.fetch(done.jobId), finished)
})

test("cancel during synthesis stops within one segment and remove deletes the job from storage", async () => {
  let release
  const started = new Promise((resolve) => { release = resolve })
  let unblock
  const blocked = new Promise((resolve) => { unblock = resolve })
  const { client, calls, store } = fixture({ synthesize: async () => { release(); await blocked; return new Uint8Array([ 1 ]) } })
  const { jobId } = await client.submit({ document: book(3) })
  await started
  await client.cancel(jobId)
  assert.equal(calls.cancelSynthesis, 1)
  unblock()
  assert.equal((await poll(client, jobId)).state, "cancelled")
  assert.equal(calls.accepted, 0)
  assert.deepEqual(await client.removeJob(jobId), { status: "removed" })
  assert.deepEqual(await store.list(), [])
})

for (const [ description, use, expectedSynthesis ] of [
  [ "skips only current authenticated audio", true, 1 ],
  [ "regenerates audio kept only for playback", "playback", 2 ],
]) {
  test("a reload restores an interrupted job and resume " + description, async () => {
    const store = new MemoryJobStore()
    const jobId = "interrupted-book"
    const chapters = book().chapters.map((chapter, index) => ({ ...chapter, index, charCount: 5 }))
    await store.save({
      jobId,
      document: { bookTitle: "Fixture", chapters, jobId },
      language: "pt-BR",
      preferences: strict(),
      snapshot: {
        jobId, state: "running", chaptersTotal: 2, chaptersCompleted: 1,
        outputs: [ { name: "chapter-1.mp3", url: "blob:expired" } ],
        chapterProgress: [ { index: 0, name: "Chapter 0", chars: 5, status: "completed" }, { index: 1, name: "Chapter 1", chars: 5, status: "processing" } ],
      },
      audio: [ { chapterIndex: 0, name: "chapter-1.mp3", blob: new Blob([ new Uint8Array([ 3, 4 ]) ], { type: "audio/mpeg" }) } ],
    })
    const { client, calls, setSaved } = fixture({ store, audioUse: async () => use })
    setSaved({ primary: { ...edge }, secondary: null, allow_online_fallback: false })
    const [ resumable ] = await client.getResumableJobs()
    assert.equal(resumable.state, "interrupted")
    assert.equal(resumable.voice, "pt_BR-faber-medium")
    assert.equal(resumable.chaptersCompleted, 1)
    assert.match((await client.fetch(jobId)).outputs[0].url, /^blob:fixture-/)
    await client.resume(jobId)
    const finished = await poll(client, jobId)
    assert.deepEqual(calls.created[0].chapters, [ 0, 1 ])
    assert.equal(calls.created[0].preferences.primary.engine, "piper")
    assert.deepEqual(finished.outputs.map((output) => output.name), [ "chapter-1.mp3", "chapter-2.mp3" ])
    assert.equal(calls.synthesized.length, expectedSynthesis)
    const reopened = fixture({ store }).client
    assert.equal((await reopened.fetch(jobId)).state, "finished")
    assert.deepEqual(await reopened.getResumableJobs(), [])
  })
}

test("a chapter is advertised only after its audio commits, and a failed commit refuses the job", async () => {
  const saves = []
  const store = new MemoryJobStore()
  const observed = { save: async (job) => { saves.push({ audio: job.audio.length, outputs: job.snapshot.outputs.length }); return store.save(job) }, list: () => store.list(), remove: (id) => store.remove(id) }
  const { client } = fixture({ store: observed })
  const result = await poll(client, (await client.submit({ document: book(1) })).jobId)
  assert.equal(result.outputs.length, 1)
  const committed = saves.findIndex((save) => save.audio === 1)
  assert.ok(committed > 0)
  assert.equal(saves[committed].outputs, 0)
  assert.equal(saves.at(-1).outputs, 1)
  const full = { save: async () => { throw new Error("Local audio storage is full") }, list: async () => [], remove: async () => {} }
  const refused = fixture({ store: full })
  await assert.rejects(refused.client.submit({ document: book() }), /Local audio storage is full/)
  assert.equal(refused.calls.created.length, 0)
  assert.deepEqual(await refused.client.getRecentJobs(), [])
})

test("listening from an unconverted chapter makes it the next one synthesised", async () => {
  let release
  const gate = new Promise((resolve) => { release = resolve })
  let first = true
  const { client, calls } = fixture({ synthesize: async (text) => { calls.synthesized.push(text); if (first) { first = false; await gate } return new Uint8Array([ 1 ]) } })
  const document = { chapters: [ { name: "A", text: "Alpha" }, { name: "B", text: "Bravo" }, { name: "C", text: "Charlie" } ] }
  const { jobId } = await client.submit({ document })
  while (calls.synthesized.length === 0) await new Promise((resolve) => setImmediate(resolve))
  await client.listenFrom(jobId, 2)
  release()
  const result = await poll(client, jobId)
  assert.equal(result.state, "finished")
  assert.deepEqual(calls.positions, [ 2 ])
  assert.equal(calls.synthesized[1], "Charlie")
  await assert.rejects(client.listenFrom(jobId, 9), /Invalid listening text position/)
  await assert.rejects(client.listenFrom(jobId, 0, 5), /Invalid listening text position/)
})

function memoryStorage() {
  const values = new Map()
  return { getItem: (key) => values.get(key) ?? null, setItem: (key, value) => values.set(key, String(value)), removeItem: (key) => values.delete(key), values }
}

test("a batch converts in order, moves to progress then downloads, and clears the pending batch", async () => {
  const { client, calls } = fixture()
  const storage = memoryStorage()
  const workspace = new ConversionWorkspace({ client, storage, pollIntervalMs: 1 })
  const tabs = []
  workspace.subscribe((state) => { if (tabs.at(-1) !== state.tab) tabs.push(state.tab) })
  assert.equal(workspace.state.canViewProgress, false)
  workspace.selectTab("progress")
  assert.equal(workspace.state.tab, "setup")
  await workspace.submit([ { document: { ...book(1), bookTitle: "First" }, fileName: "first.epub" }, { document: { ...book(1), bookTitle: "Second" }, fileName: "second.epub" } ])
  assert.equal(calls.created.length, 2)
  assert.deepEqual(tabs, [ "setup", "progress", "downloads", "progress", "downloads" ])
  assert.equal(workspace.state.phase, "finished")
  assert.equal(workspace.state.canViewDownloads, true)
  assert.equal(storage.values.has(PENDING_BATCH_KEY), false)
  assert.deepEqual(workspace.state.log.filter((entry) => entry.key === "job_started").map((entry) => entry.params.title), [ "First", "Second" ])
})

test("skip moves to the next book; cancel pauses the batch and returns to setup; clear empties it", async () => {
  let release
  let started
  const { client, calls } = fixture({ synthesize: async (text) => { calls.synthesized.push(text); started?.(); await new Promise((resolve) => { release = resolve }); return new Uint8Array([ 1 ]) } })
  const storage = memoryStorage()
  const workspace = new ConversionWorkspace({ client, storage, pollIntervalMs: 1 })
  const waitForSynthesis = () => new Promise((resolve) => { started = resolve })
  let synthesis = waitForSynthesis()
  const batch = workspace.submit([ "One", "Two", "Three" ].map((title) => ({ document: { ...book(1), bookTitle: title } })))
  await synthesis
  assert.deepEqual(workspace.state.batchPosition, { index: 1, total: 3 })
  assert.equal(JSON.parse(storage.values.get(PENDING_BATCH_KEY)).queue.length, 3)
  synthesis = waitForSynthesis()
  await workspace.skipCurrent()
  release()
  await synthesis
  assert.equal(calls.created.length, 2)
  assert.deepEqual(workspace.state.batchPosition, { index: 2, total: 3 })
  await workspace.cancelCurrent()
  release()
  await batch
  assert.equal(workspace.state.queuePaused, true)
  assert.equal(workspace.state.tab, "setup")
  assert.deepEqual(workspace.state.queue.map((item) => item.document.bookTitle), [ "Three" ])
  assert.equal(JSON.parse(storage.values.get(PENDING_BATCH_KEY)).queue[0].bookTitle, "Three")
  assert.equal(JSON.parse(storage.values.get(PENDING_BATCH_KEY)).queue[0].file, null)
  assert.ok(workspace.state.log.some((entry) => entry.key === "batch_cancelled" && entry.params.remaining === 1))
  // Cancel and skip remove the job and its audio, as "removes generated files" promises (P-24).
  assert.deepEqual(await client.getResumableJobs(), [])
  assert.equal(workspace.state.storedRevision, 2)
  workspace.clearQueue()
  assert.deepEqual(workspace.state.queue, [])
  assert.equal(storage.values.has(PENDING_BATCH_KEY), false)
})

test("a book added during a conversion runs after it; reorder changes the order", async () => {
  let release
  let started
  const { client, calls } = fixture({ synthesize: async () => { started?.(); await new Promise((resolve) => { release = resolve }); return new Uint8Array([ 1 ]) } })
  const workspace = new ConversionWorkspace({ client, storage: memoryStorage(), pollIntervalMs: 1 })
  let synthesis = new Promise((resolve) => { started = resolve })
  const batch = workspace.submit([ { document: { ...book(1), bookTitle: "One" } } ])
  await synthesis
  await workspace.enqueue([ "Two", "Three" ].map((title) => ({ document: { ...book(1), bookTitle: title } })))
  workspace.reorderQueue(1, 0)
  assert.deepEqual(workspace.state.queue.map((item) => item.document.bookTitle), [ "Three", "Two" ])
  for (let book = 0; book < 3; book++) {
    synthesis = new Promise((resolve) => { started = resolve })
    release()
    if (book < 2) await synthesis
  }
  await batch
  const titles = workspace.state.log.filter((entry) => entry.key === "job_started").map((entry) => entry.params.title)
  assert.deepEqual(titles, [ "One", "Three", "Two" ])
  assert.equal(calls.created.length, 3)
})

test("a batch left by a previous page shows its count and can only be dismissed", () => {
  const storage = memoryStorage()
  storage.setItem(PENDING_BATCH_KEY, JSON.stringify({ queue: [ { fileName: "a.epub", file: null }, { fileName: "b.epub", file: null } ], savedAt: 1 }))
  const workspace = new ConversionWorkspace({ client: fixture().client, storage })
  assert.deepEqual(workspace.state.savedBatch, { total: 2, needsFiles: 2 })
  workspace.dismissSavedBatch()
  assert.equal(workspace.state.savedBatch, null)
  assert.equal(storage.values.has(PENDING_BATCH_KEY), false)
  storage.setItem(PENDING_BATCH_KEY, "{broken")
  assert.equal(new ConversionWorkspace({ client: fixture().client, storage }).state.savedBatch, null)
})

test("a rejected submit shows an alert and does not open the progress tab", async () => {
  const workspace = new ConversionWorkspace({ client: fixture().client, storage: memoryStorage(), pollIntervalMs: 1 })
  await workspace.submit([ { document: book(), chapters: "5" } ])
  assert.equal(workspace.state.error, CHAPTER_RANGE_ERROR)
  assert.equal(workspace.state.tab, "setup")
  assert.equal(workspace.state.canViewProgress, false)
})
