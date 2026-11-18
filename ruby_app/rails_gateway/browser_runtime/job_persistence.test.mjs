import test from "node:test"
import assert from "node:assert/strict"
import { IndexedDBJobStore, MemoryJobStore, JOB_DATABASE, JOB_DATABASE_VERSION, JOB_OBJECT_STORE } from "../app/javascript/runtime/job_store.js"
import { audioSeals, storedAudioUse } from "../app/javascript/runtime/audio_identity.js"
import { JobRepository } from "../app/javascript/runtime/job_repository.js"

const faber = { engine: "piper", model_id: "pt_BR-faber-medium", voice: null }
const storedJob = () => ({
  jobId: "book",
  snapshot: { jobId: "book", state: "finished", outputs: [] },
  document: { jobId: "book", chapters: [ { index: 0, name: "Chapter", text: "Texto", charCount: 5 } ] },
  preferences: { primary: { ...faber }, secondary: null, allow_online_fallback: false },
  language: "pt-BR",
  audio: [ { chapterIndex: 0, name: "chapter.mp3", blob: new Blob([ "audio" ], { type: "audio/mpeg" }) } ],
})

// Stands in for tts_request_cache_material_v2: any argument change changes the material.
const cacheMaterial = (...args) => JSON.stringify(args)

function sealedFixture() {
  const source = {
    document: { jobId: "book-job", bookTitle: "Fixture", chapters: [ { index: 0, name: "Chapter", text: "á🙂 original words", charCount: 17 } ] },
    preferences: { primary: { ...faber }, secondary: null, allow_online_fallback: false },
    language: "pt-BR",
  }
  const audio = {
    chapterIndex: 0,
    name: "chapter-1.mp3",
    blob: new Blob([ new Uint8Array([ 1, 2, 3 ]) ]),
    textOffset: 2,
    chunks: [ { index: 0, text: "original words", byteOffset: 0, byteLength: 3 } ],
    ttsReceipts: [ {
      version: 2, session_id: "current", source_index: 0, segment_index: 0, format: { encoding: "mp3" },
      identity: {
        selection: { version: 2, provider: "piper", runtime: "piper-web", model_id: faber.model_id, model_revision: "sha", voice: null, options: {} },
        runtime_revision: "runtime-1", artifacts: { model: "sha" }, reusable: true,
      },
    } ],
  }
  return { source, audio }
}

/**
 * The smallest IndexedDB that drives the store's event contract. `failPut`
 * aborts write transactions with the given DOMException name; `blocked`
 * reports another tab holding an older connection.
 */
function fakeIndexedDB({ failPut, blocked } = {}) {
  const opened = []
  const rows = new Map()
  const created = []
  const database = {
    objectStoreNames: { contains: (name) => created.some((store) => store.name === name) },
    createObjectStore: (name, options) => created.push({ name, options }),
    close() {},
    transaction(_name, mode) {
      const transaction = { error: null }
      const finish = (request, value, apply) => queueMicrotask(() => {
        if (mode === "readwrite" && failPut) {
          transaction.error = new DOMException("full", failPut)
          transaction.onabort?.()
          return
        }
        apply?.()
        request.result = value
        request.onsuccess?.()
        transaction.oncomplete?.()
      })
      transaction.objectStore = () => ({
        getAll() { const request = {}; finish(request, [ ...rows.values() ]); return request },
        put(value) { const request = {}; finish(request, value.jobId, () => rows.set(value.jobId, value)); return request },
        delete(key) { const request = {}; finish(request, undefined, () => rows.delete(key)); return request },
      })
      return transaction
    },
  }
  const factory = {
    open(name, version) {
      opened.push({ name, version })
      const request = { result: database }
      queueMicrotask(() => {
        if (blocked) return request.onblocked?.()
        request.onupgradeneeded?.()
        request.onsuccess?.()
      })
      return request
    },
  }
  return { factory, opened, created, rows }
}

test("memory store copies mutable state and shares immutable audio blobs", async () => {
  const store = new MemoryJobStore()
  const job = storedJob()
  const originalAudio = job.audio[0].blob
  await store.save(job)
  job.preferences.primary.engine = "edge"
  job.snapshot.state = "cancelled"
  job.document.chapters[0].text = "Changed"
  job.audio.length = 0
  const restored = (await store.list())[0]
  assert.equal(restored.preferences.primary.engine, "piper")
  assert.equal(restored.snapshot.state, "finished")
  assert.equal(restored.document.chapters[0].text, "Texto")
  assert.equal(restored.audio[0].blob, originalAudio)
  restored.snapshot.state = "failed"
  assert.equal((await store.list())[0].snapshot.state, "finished")
  await store.remove("book")
  assert.deepEqual(await store.list(), [])
})

test("IndexedDB store keeps the React database identity and commits through transactions", async () => {
  const indexedDB = fakeIndexedDB()
  const store = new IndexedDBJobStore(indexedDB.factory)
  await store.save(storedJob())
  assert.deepEqual(indexedDB.opened, [ { name: JOB_DATABASE, version: JOB_DATABASE_VERSION } ])
  assert.deepEqual([ JOB_DATABASE, JOB_DATABASE_VERSION ], [ "ebook-tts.jobs.v1", 1 ])
  assert.deepEqual(indexedDB.created, [ { name: JOB_OBJECT_STORE, options: { keyPath: "jobId" } } ])
  assert.equal(JOB_OBJECT_STORE, "jobs")
  assert.deepEqual((await store.list()).map((job) => job.jobId), [ "book" ])
  await store.remove("book")
  assert.deepEqual(await store.list(), [])
})

test("missing, quota-exceeded and blocked storage each fail with their own message", async () => {
  const missing = new IndexedDBJobStore(undefined)
  await assert.rejects(missing.save(storedJob()), /Enable IndexedDB storage for this site/)
  await assert.rejects(missing.list(), /Enable IndexedDB storage for this site/)

  const quota = new IndexedDBJobStore(fakeIndexedDB({ failPut: "QuotaExceededError" }).factory)
  await assert.rejects(quota.save(storedJob()), /storage quota exceeded\. Free space and retry/)

  const blocked = new IndexedDBJobStore(fakeIndexedDB({ blocked: true }).factory)
  await assert.rejects(blocked.list(), /blocked by another tab/)
})

test("sealed audio identity covers source, range, settings, receipts and exact bytes", async () => {
  const { source, audio } = sealedFixture()
  Object.assign(audio, await audioSeals(source, audio, cacheMaterial))
  assert.match(audio.cacheIdentity, /^[0-9a-f]{64}:[0-9a-f]{64}$/)
  assert.equal(await storedAudioUse(source, audio, cacheMaterial), true)
  const changedSource = structuredClone(source)
  changedSource.document.chapters[0].text = "replaced words"
  assert.equal(await storedAudioUse(changedSource, audio, cacheMaterial), false)
  const changedSettings = structuredClone(source)
  changedSettings.preferences.primary.voice = "other"
  assert.equal(await storedAudioUse(changedSettings, audio, cacheMaterial), false)
  for (const changed of [
    { ...audio, textOffset: 0 },
    { ...audio, blob: new Blob([ new Uint8Array([ 1, 2, 4 ]) ]) },
    { ...audio, chunks: [ { index: 0, text: "different range", byteOffset: 0, byteLength: 3 } ] },
    { ...audio, ttsReceipts: audio.ttsReceipts.map((receipt) => ({ ...receipt, identity: { ...receipt.identity, runtime_revision: "other" } })) },
  ]) assert.equal(await storedAudioUse(source, changed, cacheMaterial), false)
})

test("IndexedDB v1 authenticates the same job and chapter; only current processing seals may skip synthesis", async () => {
  const { source, audio } = sealedFixture()
  const shipped = (...args) => JSON.stringify([ 2, "text-v1", ...args ])
  const current = (...args) => JSON.stringify([ 2, "text-v1", "digital-silence-v1-600ms-300ms", ...args ])
  const seals = await audioSeals(source, audio, current)
  const original = await audioSeals(source, audio, shipped)
  assert.equal(seals.cacheIdentity, original.cacheIdentity)
  assert.notEqual(seals.synthesisCacheIdentity, original.cacheIdentity)
  const oldRecording = { ...audio, cacheIdentity: original.cacheIdentity }
  assert.equal(await storedAudioUse(source, oldRecording, current), "playback")
  assert.equal(await storedAudioUse(source, { ...audio, ...seals }, current), true)
  // Rails builds prior to this interoperability change wrote the current seal into cacheIdentity.
  assert.equal(await storedAudioUse(source, { ...audio, cacheIdentity: seals.synthesisCacheIdentity }, current), true)
  assert.equal(await storedAudioUse(source, { ...oldRecording, chapterIndex: 1 }, current), false)
  const anotherBook = { ...source, document: { ...source.document, jobId: "different-job" } }
  assert.equal(await storedAudioUse(anotherBook, oldRecording, current), false)
})

test("retired sessions are rejected and missing receipts never downgrade a session job to legacy", async () => {
  const { source, audio } = sealedFixture()
  audio.ttsReceipts.push({ ...audio.ttsReceipts[0], segment_index: 1, session_id: "retired" })
  await assert.rejects(audioSeals(source, audio, cacheMaterial), /retired/)
  source.preferences.primary.session = audio.ttsReceipts[0].identity.selection
  const unsealed = { chapterIndex: 0, name: "chapter-1.mp3", blob: audio.blob }
  assert.equal(await storedAudioUse(source, unsealed, cacheMaterial), false)
  const legacy = structuredClone(source)
  delete legacy.preferences.primary.session
  assert.equal(await storedAudioUse(legacy, unsealed, cacheMaterial), "playback")
})

test("restore interrupts unfinished jobs, drops tampered or untiled audio and persists the change", async () => {
  const { source, audio } = sealedFixture()
  Object.assign(audio, await audioSeals(source, audio, cacheMaterial))
  const tampered = { ...audio, chapterIndex: 0, blob: new Blob([ new Uint8Array([ 9, 9, 9 ]) ]) }
  // Legacy audio passes identity, so only the range check can reject it.
  const gap = { chapterIndex: 0, name: "chapter-1.mp3", blob: audio.blob, chunks: [ { index: 0, byteOffset: 1, byteLength: 2 } ] }
  const store = new MemoryJobStore()
  const base = { document: source.document, preferences: source.preferences, language: source.language }
  const chapterProgress = [ { index: 0, status: "completed" }, { index: 1, status: "running" } ]
  await store.save({ ...base, jobId: "good", snapshot: { jobId: "good", state: "running", chapterProgress }, audio: [ audio ] })
  await store.save({ ...base, jobId: "tampered", snapshot: { jobId: "tampered", state: "finished" }, audio: [ tampered ] })
  await store.save({ ...base, jobId: "gap", snapshot: { jobId: "gap", state: "finished" }, audio: [ gap ] })
  const repository = new JobRepository(store, (saved, artifact) => storedAudioUse(saved, artifact, cacheMaterial))
  await repository.ensureRestored()

  const good = repository.get("good")
  assert.equal(good.snapshot.state, "interrupted")
  assert.equal(good.snapshot.chaptersCompleted, 1)
  assert.deepEqual(good.snapshot.chapterProgress.map((chapter) => chapter.status), [ "completed", "pending" ])
  assert.match(good.snapshot.chapterProgress[0].downloadUrl, /^blob:/)
  assert.equal(good.chunks.get(0).legacyWholeChapter, false)
  assert.equal(await (await fetch(good.chunks.get(0).chunks[0].url)).arrayBuffer().then((bytes) => bytes.byteLength), 3)
  for (const id of [ "tampered", "gap" ]) {
    assert.equal(repository.get(id).snapshot.state, "interrupted")
    assert.equal(repository.get(id).audio.size, 0)
  }
  const persisted = Object.fromEntries((await store.list()).map((job) => [ job.jobId, job ]))
  assert.deepEqual(Object.values(persisted).map((job) => job.snapshot.state), [ "interrupted", "interrupted", "interrupted" ])
  assert.equal(persisted.good.snapshot.chapterProgress[0].downloadUrl, undefined)
  assert.deepEqual(persisted.good.snapshot.outputs.map((output) => output.url), [ "" ])
  assert.throws(() => repository.get("absent"), /Browser job not found/)
})

test("finished jobs with missing promised audio become resumable; an unconverted empty chapter needs no blob", async () => {
  const store = new MemoryJobStore()
  const job = storedJob()
  const kept = { ...job.audio[0], name: "chapter-1.mp3" }
  const chapters = [ ...job.document.chapters, { index: 1, name: "Second", text: "More", charCount: 4 } ]
  const empty = { index: 2, name: "Blank", text: "", charCount: 0 }
  const cases = [
    { id: "output-only", outputs: [ { name: "chapter-2.mp3" } ], audio: [ kept ] },
    { id: "progress-only", chapterProgress: [ { index: 1, status: "completed" } ], audio: [ kept ] },
    { id: "count-only", chaptersCompleted: 2, audio: [ kept ] },
    { id: "all-blobs-lost", outputs: [ { name: "chapter-1.mp3" } ], audio: [] },
    { id: "complete", outputs: [ { name: kept.name } ], chaptersCompleted: 1,
      chapterProgress: [ { index: 0, status: "completed" }, { index: 2, status: "pending" } ], audio: [ kept ] },
  ]
  for (const { id, audio, ...summary } of cases) {
    await store.save({ ...job, jobId: id, snapshot: { jobId: id, state: "finished", ...summary }, audio,
      document: { ...job.document, jobId: id, chapters: id === "complete" ? [ chapters[0], empty ] : chapters } })
  }
  const repository = new JobRepository(store, async () => true)
  await repository.ensureRestored()
  for (const { id, audio } of cases) {
    const snapshot = repository.get(id).snapshot
    assert.equal(snapshot.state, id === "complete" ? "finished" : "interrupted", id)
    assert.equal(snapshot.chaptersCompleted, audio.length)
    assert.deepEqual(snapshot.outputs.map(output => output.name), audio.map(artifact => artifact.name))
    assert.equal((await store.list()).find(job => job.jobId === id).snapshot.state, snapshot.state)
  }
})

test("legacy whole-chapter audio keeps the text from its code-point offset", async () => {
  const store = new MemoryJobStore()
  const job = storedJob()
  job.document.chapters[0].text = "🙂ab"
  job.audio[0].textOffset = 1
  await store.save(job)
  const repository = new JobRepository(store, (saved, artifact) => storedAudioUse(saved, artifact, cacheMaterial))
  await repository.ensureRestored()
  const manifest = repository.get("book").chunks.get(0)
  assert.equal(manifest.legacyWholeChapter, true)
  assert.equal(manifest.chunks[0].text, "ab")
  assert.equal(repository.get("book").snapshot.state, "finished")
})

test("a new job is durable before it is live, and removal deletes it from storage", async () => {
  const store = new MemoryJobStore()
  const repository = new JobRepository(store, async () => true)
  const failing = new JobRepository({ ...store, save: async () => { throw new Error("quota") } }, async () => true)
  const job = { snapshot: { jobId: "new", state: "queued", outputs: [] }, document: { chapters: [] }, preferences: {}, language: "pt-BR", audio: new Map(), chunks: new Map(), done: Promise.resolve() }
  await assert.rejects(failing.commitNew(job), /quota/)
  assert.throws(() => failing.get("new"), /not found/)
  await repository.commitNew(job)
  assert.equal(repository.get("new"), job)
  assert.deepEqual((await store.list()).map((stored) => stored.jobId), [ "new" ])
  await repository.remove(job)
  assert.deepEqual(await store.list(), [])
  assert.deepEqual([ ...repository.all() ], [])
})
