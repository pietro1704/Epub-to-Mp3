import test from "node:test"
import assert from "node:assert/strict"
import { LatencyObservationStore, serializeLatencyEvidence } from "../app/javascript/runtime/latency_observation.js"
import { ReaderSession } from "../app/javascript/runtime/reader_session.js"

// Ports of web/src/services/LatencyObservation.test.ts.
test("keeps queued, playable and audible boundaries separate without content", () => {
  let now = 10
  const store = new LatencyObservationStore(() => now)
  const id = store.begin("progressive_playback", "play_requested")
  now = 30; store.record(id, "audio_queued")
  now = 40; store.record(id, "audio_playable")
  now = 55; store.record(id, "audio_audible")
  store.finish(id)
  assert.deepEqual(store.snapshot()[0].records, [
    { transition: "play_requested", elapsedMs: 0 }, { transition: "audio_queued", elapsedMs: 20 },
    { transition: "audio_playable", elapsedMs: 30 }, { transition: "audio_audible", elapsedMs: 45 },
  ])
})

test("records cancellation and rejects later ready boundaries", () => {
  let now = 10
  const store = new LatencyObservationStore(() => now)
  const id = store.begin("seek", "seek_requested")
  now = 18
  store.cancel(id)
  assert.equal(store.record(id, "seek_target_reached"), false)
  assert.deepEqual(store.snapshot()[0].records, [ { transition: "seek_requested", elapsedMs: 0 }, { transition: "cancelled", elapsedMs: 8 } ])
})

test("rejects out-of-order readiness events and invalid starts", () => {
  let now = 10
  const store = new LatencyObservationStore(() => now)
  assert.equal(store.begin("seek", "play_requested"), "")
  const id = store.begin("progressive_playback", "play_requested")
  now = 20
  assert.equal(store.record(id, "audio_playable"), false)
  assert.equal(store.record(id, "audio_audible"), false)
  assert.equal(store.record(id, "audio_queued"), true)
  now = 30
  assert.equal(store.record(id, "audio_audible"), false)
  assert.equal(store.record(id, "audio_playable"), true)
  assert.equal(store.record(id, "audio_audible"), true)
  assert.deepEqual(store.snapshot()[0].records.map((record) => record.elapsedMs), [ 0, 10, 20, 20 ])
})

test("capacity keeps only the newest journeys", () => {
  const store = new LatencyObservationStore(() => 0, 2)
  const ids = [ 1, 2, 3 ].map(() => store.begin("seek", "seek_requested"))
  assert.deepEqual(store.snapshot().map((observation) => observation.id), ids.slice(1))
})

test("exports evidence with schema version 1, the shared vocabulary and no caller metadata", () => {
  let now = 100
  const store = new LatencyObservationStore(() => now)
  const id = store.begin("reader_open", "open_requested", { cacheState: "warm", resourcePolicy: "foreground_priority" })
  now = 180
  store.record(id, "readable_content")
  store.record(id, "controls_usable")
  store.finish(id)
  const evidence = JSON.parse(serializeLatencyEvidence(store.snapshot()))
  assert.equal(evidence.schemaVersion, 1)
  assert.equal(evidence.observations[0].kind, "reader_open")
  assert.equal(evidence.observations[0].cacheState, "warm")
  assert.deepEqual(evidence.observations[0].records.map((record) => record.transition), [ "open_requested", "readable_content", "controls_usable" ])
  assert.doesNotMatch(JSON.stringify(evidence), /book|title/)
})

test("the reader records one reader-open journey per open and cancels a superseded or failed one", async () => {
  let now = 0
  const latency = new LatencyObservationStore(() => now)
  let failNext = false
  const reader = new ReaderSession({
    inspect: async () => { now += 25; if (failNext) throw new Error("broken"); return { bookTitle: "T", chapters: [{ index: "1" }] } },
    render: async () => ({ pages: [{ start: 0, end: 1 }], searchMatches: [] }), preferences: {}, savePreferences: () => {}, latency,
  })
  const book = { id: "b", file: { name: "b.epub" } }
  await reader.open(book)
  const superseded = reader.open(book)
  reader.close()
  await superseded
  // Closing ends the pending journey at once, not only when another book opens.
  assert.deepEqual(latency.snapshot()[1].records.map((record) => record.transition), [ "open_requested", "cancelled" ])
  failNext = true
  await reader.open(book)
  const kinds = latency.snapshot().map((observation) => observation.records.map((record) => record.transition))
  assert.deepEqual(kinds, [
    [ "open_requested", "readable_content", "controls_usable" ],
    [ "open_requested", "cancelled" ],
    [ "open_requested", "cancelled" ],
  ])
  assert.equal(latency.snapshot()[0].records[1].elapsedMs, 25)
})
