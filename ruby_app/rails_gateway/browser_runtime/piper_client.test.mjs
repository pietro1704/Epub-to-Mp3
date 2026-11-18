import test from "node:test"
import assert from "node:assert/strict"
import { PiperClient, DEFAULT_PIPER_MODEL } from "../app/javascript/runtime/piper_client.js"

/** Records messages and terminations; replies are driven by the test. */
function workers() {
  const instances = []
  const create = () => {
    const worker = { posted: [], terminated: 0, onmessage: undefined, onerror: undefined }
    worker.postMessage = (message) => worker.posted.push(message)
    worker.terminate = () => { worker.terminated += 1 }
    instances.push(worker)
    return worker
  }
  const reply = (index, bytes, { format = "mp3", receipt } = {}) => {
    const worker = instances[index]
    const request = worker.posted.at(-1)
    worker.onmessage?.({ data: { version: 2, requestId: request.requestId, modelId: request.modelId, format, audio: new Uint8Array(bytes).buffer, receipt } })
  }
  return { instances, create, reply }
}

test("a runtime that never answers is terminated at the deadline and the next segment uses a fresh worker", async () => {
  const pool = workers()
  const client = new PiperClient(pool.create, { deadlineMs: 5 })
  await assert.rejects(client.synthesize("A bounded request."), /deadline exceeded/)
  assert.equal(pool.instances[0].terminated, 1)
  const next = client.synthesize("Recovered.")
  pool.reply(1, [ 1, 2 ])
  assert.deepEqual((await next).audio, new Uint8Array([ 1, 2 ]))
})

test("late callbacks from a cancelled worker are ignored and undeclared audio is rejected", async () => {
  const pool = workers()
  const client = new PiperClient(pool.create)
  const first = client.synthesize("First", "model-a")
  client.cancel()
  await assert.rejects(first, /cancelled/)
  const second = client.synthesize("Second", "model-b")
  assert.deepEqual(pool.instances[1].posted.at(-1), { version: 2, requestId: 2, text: "Second", modelId: "model-b", modelRevision: undefined, voice: undefined })
  pool.reply(0, [ 9 ])
  // Even a retired worker that echoes the current request ID cannot answer it.
  pool.instances[0].onmessage?.({ data: { version: 2, requestId: 2, modelId: "model-b", format: "mp3", audio: new Uint8Array([ 7 ]).buffer } })
  pool.instances[0].onerror?.({ message: "Retired worker error" })
  pool.reply(1, [ 1 ], { format: "wav" })
  await assert.rejects(second, /no audio with the requested identity/)
  assert.equal(pool.instances[1].terminated, 1)
})

test("a pinned model revision must come back in the receipt", async () => {
  const pool = workers()
  const client = new PiperClient(pool.create)
  const mismatched = client.synthesize("Texto", DEFAULT_PIPER_MODEL, "rev-a")
  pool.reply(0, [ 1 ], { receipt: { modelRevision: "rev-b", voice: "0" } })
  await assert.rejects(mismatched, /requested identity/)
  const matched = client.synthesize("Texto", DEFAULT_PIPER_MODEL, "rev-a")
  pool.reply(1, [ 4 ], { receipt: { modelRevision: "rev-a", voice: "speaker" } })
  assert.deepEqual(await matched, { audio: new Uint8Array([ 4 ]), modelRevision: "rev-a", voice: "speaker" })
})

test("overlapping synthesis is refused instead of running two heavy segments", async () => {
  const pool = workers()
  const client = new PiperClient(pool.create)
  const active = client.synthesize("Um segmento.")
  await assert.rejects(client.synthesize("Outro segmento."), /already active/)
  pool.reply(0, [ 3 ])
  await active
  assert.equal(pool.instances.length, 1)
  assert.equal(pool.instances[0].posted[0].modelId, "pt_BR-faber-medium")
})

test("a worker error rejects the active segment and the worker is not reused", async () => {
  const pool = workers()
  const client = new PiperClient(pool.create)
  const active = client.synthesize("Texto")
  pool.instances[0].onerror({ message: "onnxruntime failed to load" })
  await assert.rejects(active, /onnxruntime failed to load/)
  client.synthesize("Again").catch(() => {})
  assert.equal(pool.instances.length, 2)
  client.cancel()
})
