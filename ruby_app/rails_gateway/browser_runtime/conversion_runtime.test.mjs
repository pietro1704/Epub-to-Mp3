import test from "node:test"
import assert from "node:assert/strict"
import { browserArtifacts, browserDownloadSelections, browserSelections, installedManualBrowserSelections } from "../app/javascript/runtime/tts_catalog.js"
import { TTS_PREFERENCES_KEY, availableTtsPreferences, edge, effectiveTtsPreferences, faber, loadTtsPreferences, saveTtsPreferences, system } from "../app/javascript/runtime/tts_preferences.js"
import { installModel, pendingModelInstallation } from "../app/javascript/runtime/model_installation.js"
import { FABER_ARTIFACTS, ModelIntegrity } from "../app/javascript/runtime/model_integrity.js"
import { TtsPreparationError, createConversionRuntime, createPiperPreparation, createSynthesis } from "../app/javascript/runtime/conversion_runtime.js"

const provider = (overrides = {}) => ({
  provider: "piper", runtime: "piper-web", revision: "runtime-1", targets: [ "web" ],
  capabilities: { audio_bytes: true, online: false }, ...overrides,
})
const model = (id, overrides = {}) => ({
  id, engine: "piper", revision: `sha-${id}`, runtime_available: true,
  artifacts: [ { name: "model.onnx", url: `https://example.com/${id}`, sha256: `sha-${id}`, bytes: 10 } ], ...overrides,
})
const catalog = (models = [ model("pt_BR-faber-medium") ], providers = [ provider() ]) => ({ version: 2, models, providers })

function memoryStorage(entries = {}) {
  const values = new Map(Object.entries(entries))
  return { getItem: (key) => values.get(key) ?? null, setItem: (key, value) => values.set(key, String(value)), values }
}

test("descriptor-driven selection admits compatible models and keeps runtime and artifact identity", () => {
  const value = catalog([ model("a"), model("b") ])
  const selections = browserSelections(value)
  assert.deepEqual(selections.map((selection) => selection.model_id), [ "a", "b" ])
  assert.equal(selections[1].session.runtime, "piper-web")
  assert.equal(selections[1].session.model_revision, "sha-b")
  assert.deepEqual(browserArtifacts(value.models[1])[0], { name: "b.onnx", url: "https://example.com/b", sha256: "sha-b", bytes: 10 })
  assert.deepEqual(browserSelections(catalog([ model("a") ], [ provider({ capabilities: { audio_bytes: false, online: false } }) ])), [])
  assert.deepEqual(browserSelections(catalog([ model("a") ], [ provider({ capabilities: { audio_bytes: true, online: true } }) ])), [])
  assert.deepEqual(browserSelections(catalog([ model("a", { runtime_available: false }) ])), [])
  assert.deepEqual(browserSelections(catalog([ model("a", { artifacts: [] }) ])), [])
  assert.deepEqual(browserSelections(catalog([ model("a") ], [ provider({ targets: [ "apple" ] }) ])), [])
})

test("manual Piper selection requires a captured revision and checks its installed artifacts", async () => {
  const low = model("pt_BR-edresson-low", { manual_only: true })
  const all = catalog([ ...catalog().models, low ])
  const installed = []
  const { prepare } = createPiperPreparation({
    loadCatalog: async (manual) => manual ? all : catalog(),
    verifyModel: async (entry) => { installed.push(entry.id) },
  })
  const choice = browserSelections(all).find((entry) => entry.model_id === low.id)
  await assert.rejects(prepare({ engine: "piper", model_id: low.id }), /compatible browser/)
  await assert.rejects(prepare({ ...choice, session: { ...choice.session, model_revision: "obsolete" } }), /revision/)
  assert.deepEqual(installed, [])
  await prepare(choice)
  assert.deepEqual(installed, [ low.id ])
})

test("download filter is opt-in and expanding it never selects an uninstalled or corrupt Low voice", async () => {
  const edresson = model("pt_BR-edresson-low", { manual_only: true })
  const lessac = model("en_US-lessac-low", { manual_only: true })
  const all = catalog([ catalog().models[0], edresson, lessac ])
  assert.deepEqual(browserDownloadSelections(all).map(choice => choice.model_id), [ faber.model_id ])
  assert.deepEqual(browserDownloadSelections(all, true).map(choice => choice.model_id), [ faber.model_id, edresson.id, lessac.id ])
  assert.deepEqual(await installedManualBrowserSelections(all, async () => false), [])
  const checked = []
  const installed = await installedManualBrowserSelections(all, async candidate => {
    checked.push(candidate.id)
    if (candidate.id === lessac.id) throw new Error("storage error")
    return candidate.id === edresson.id
  })
  assert.deepEqual(checked, [ edresson.id, lessac.id ])
  assert.deepEqual(installed.map(choice => choice.model_id), [ edresson.id ])
  assert.equal(installed[0].session.model_revision, edresson.revision)
  assert.deepEqual(browserDownloadSelections(all).map(choice => choice.model_id), [ faber.model_id ])
})

test("explicit Low primaries survive a saved policy while Low reserves are discarded", () => {
  const low = browserSelections(catalog([ model("pt_BR-edresson-low", { manual_only: true }) ]))[0]
  const saved = { primary: low, secondary: system, allow_online_fallback: false }
  const fallback = { primary: faber, secondary: low, allow_online_fallback: false }
  const storage = memoryStorage()
  saveTtsPreferences(storage, saved)
  assert.deepEqual(loadTtsPreferences(storage), saved)
  assert.deepEqual(effectiveTtsPreferences(loadTtsPreferences(storage), null), saved)
  assert.deepEqual(availableTtsPreferences(saved, null), saved)
  assert.deepEqual(availableTtsPreferences(saved, [ low ]), saved)
  assert.deepEqual(availableTtsPreferences(saved, []).primary, faber)
  const stale = { ...low, session: { ...low.session, model_revision: "obsolete" } }
  assert.deepEqual(availableTtsPreferences(saved, [ stale ]).primary, faber)
  saveTtsPreferences(storage, fallback)
  assert.equal(loadTtsPreferences(storage).secondary, null)
  assert.equal(effectiveTtsPreferences(fallback, null).secondary, null)
  assert.equal(effectiveTtsPreferences(fallback, faber, true).secondary, null)
})

test("preferences default offline, keep explicit old choices and survive a broken store", () => {
  const storage = memoryStorage()
  assert.deepEqual(loadTtsPreferences(storage), { policy_version: 2, primary: faber, secondary: system, allow_online_fallback: false })
  saveTtsPreferences(storage, { primary: faber, secondary: null, allow_online_fallback: false })
  assert.equal(loadTtsPreferences(storage).secondary, null)
  assert.equal(loadTtsPreferences(storage).policy_version, undefined)
  saveTtsPreferences(storage, { primary: edge, secondary: faber, allow_online_fallback: false })
  assert.deepEqual(loadTtsPreferences(storage).primary, edge)
  assert.equal(JSON.parse(storage.values.get(TTS_PREFERENCES_KEY)).primary.engine, "edge")
  assert.equal(loadTtsPreferences(memoryStorage({ [TTS_PREFERENCES_KEY]: "{not json" })).primary.engine, "piper")
  assert.equal(loadTtsPreferences(memoryStorage({ [TTS_PREFERENCES_KEY]: '{"primary":{"engine":"kokoro"}}' })).primary.engine, "piper")
  assert.equal(loadTtsPreferences({ getItem: () => { throw new Error("denied") } }).primary.engine, "piper")
  assert.equal(loadTtsPreferences(undefined).primary.engine, "piper")
})

test("per-job overrides are strict unless the secondary is requested, and never mutate the saved policy", () => {
  const adopted = { policy_version: 2, primary: faber, secondary: system, allow_online_fallback: false }
  assert.deepEqual(effectiveTtsPreferences(adopted, faber, true), adopted)
  assert.deepEqual(effectiveTtsPreferences(adopted, faber), { primary: faber, secondary: null, allow_online_fallback: false })
  assert.equal(effectiveTtsPreferences({ primary: faber, secondary: system, allow_online_fallback: false }, faber, true).policy_version, undefined)
  const saved = { primary: faber, secondary: edge, allow_online_fallback: true }
  // An Edge primary override carries the saved online consent, never more than that.
  assert.deepEqual(effectiveTtsPreferences(saved, { engine: "edge" }, true), { primary: { engine: "edge" }, secondary: null, allow_online_fallback: true })
  assert.deepEqual(effectiveTtsPreferences({ ...saved, allow_online_fallback: false }, { engine: "edge" }), { primary: { engine: "edge" }, secondary: null, allow_online_fallback: false })
  assert.deepEqual(effectiveTtsPreferences(saved, faber), { primary: faber, secondary: null, allow_online_fallback: false })
  assert.deepEqual(effectiveTtsPreferences(saved, { ...edge, voice: "pt-BR-AntonioNeural" }, true).secondary, edge)
  const inherited = effectiveTtsPreferences(saved, null)
  inherited.primary.engine = "edge"
  assert.equal(saved.primary.engine, "piper")
})

function storedFile(size) {
  return { size, lastModified: 42, arrayBuffer: async () => new ArrayBuffer(1) }
}
const bytes = (hex) => Uint8Array.from(hex.match(/../g), (value) => parseInt(value, 16)).buffer
function directory(sizeFor) {
  const removed = []
  const opened = []
  return {
    removed, opened,
    getFileHandle: async (name) => {
      opened.push(name)
      if (!sizeFor(name)) throw new DOMException("missing", "NotFoundError")
      return { getFile: async () => storedFile(sizeFor(name)) }
    },
    removeEntry: async (name) => { removed.push(name) },
  }
}

test("corrupt Faber artifacts are removed before inference", async () => {
  const files = directory(() => 63_201_294)
  const integrity = new ModelIntegrity({ digest: async () => new ArrayBuffer(32) })
  await assert.rejects(integrity.verifyFaber(files), /checksum validation failed\. Corrupt model files were removed/)
  assert.deepEqual(files.removed, FABER_ARTIFACTS.map((artifact) => artifact.name))
})

test("both catalog checksums are verified once per unchanged file", async () => {
  const files = directory((name) => name.endsWith(".json") ? 4_855 : 63_201_294)
  const digests = [ bytes(FABER_ARTIFACTS[0].sha256), bytes(FABER_ARTIFACTS[1].sha256) ]
  let calls = 0
  const integrity = new ModelIntegrity({ digest: async () => digests[calls++] })
  await integrity.verifyFaber(files)
  await integrity.verifyFaber(files)
  assert.equal(calls, 2)
  assert.deepEqual(files.removed, [])
  integrity.invalidate()
  await assert.rejects(integrity.verifyFaber(files), /checksum validation failed/)
})

test("catalog models are checked under their OPFS names and are never removed on mismatch", async () => {
  const files = directory((name) => name === "voice.onnx" ? 10 : 0)
  const integrity = new ModelIntegrity({ openDirectory: async () => files, digest: async () => new ArrayBuffer(32) })
  await assert.rejects(integrity.verifyModel(model("voice")), /voice checksum validation failed\. Reinstall the model explicitly\./)
  assert.deepEqual(files.opened, [ "voice.onnx" ])
  assert.deepEqual(files.removed, [])
  await assert.rejects(integrity.verifyModel(model("absent")), /absent is incomplete\. Install the model before converting\./)
})

/** A Piper client double that answers immediately with fixed bytes. */
function piperDouble() {
  const calls = []
  let cancels = 0
  return {
    calls,
    get cancels() { return cancels },
    synthesize: async (...args) => {
      calls.push(args)
      return { audio: new Uint8Array([ 1, 2 ]), modelRevision: args[2] ?? "worker-revision", voice: "0" }
    },
    cancel: () => { cancels++ },
  }
}

test("a prepared Piper selection returns MP3 with the catalog identity the receipt must carry", async () => {
  const value = catalog()
  const verified = []
  const preparation = createPiperPreparation({ loadCatalog: async () => value, verifyModel: async (m) => { verified.push(m.id) } })
  const piper = piperDouble()
  const synthesis = createSynthesis({ ...preparation, piper })
  const [ selection ] = browserSelections(value)
  const result = await synthesis.synthesize("Texto", selection)
  assert.deepEqual(verified, [ "pt_BR-faber-medium" ])
  assert.deepEqual(piper.calls, [ [ "Texto", "pt_BR-faber-medium", "sha-pt_BR-faber-medium", undefined ] ])
  assert.deepEqual(result.format, { encoding: "mp3" })
  assert.deepEqual(result.audio, new Uint8Array([ 1, 2 ]))
  assert.deepEqual(result.identity, {
    selection: { ...selection.session, voice: "0", model_revision: "sha-pt_BR-faber-medium" },
    runtime_revision: "runtime-1",
    artifacts: { "model.onnx": "sha-pt_BR-faber-medium" },
    reusable: true,
  })
})

test("selections outside the catalog or with a stale captured revision are rejected before the worker", async () => {
  const value = catalog()
  const preparation = createPiperPreparation({ loadCatalog: async () => value, verifyModel: async () => {} })
  const piper = piperDouble()
  const synthesis = createSynthesis({ ...preparation, piper })
  const [ selection ] = browserSelections(value)
  await assert.rejects(synthesis.synthesize("x", { engine: "piper", model_id: "unknown" }), /no compatible browser audio runtime/)
  await assert.rejects(synthesis.synthesize("x", { ...selection, session: { ...selection.session, model_revision: "old" } }), /incompatible with this browser/)
  await assert.rejects(synthesis.synthesize("x", { ...selection, session: { ...selection.session, options: { speed: 2 } } }), /incompatible with this browser/)
  await assert.rejects(synthesis.synthesize("x", { engine: "system" }), /adapter is unavailable/)
  assert.equal(piper.calls.length, 0)
})

test("a pending explicit installation is awaited before verification", async () => {
  const order = []
  let finish
  const installation = new Promise((resolve) => { finish = resolve })
  const preparation = createPiperPreparation({
    loadCatalog: async () => catalog(),
    verifyModel: async () => { order.push("verify") },
    pendingInstallation: modelId => modelId === faber.model_id ? installation : undefined,
  })
  const pending = preparation.prepare(faber)
  await new Promise((resolve) => setImmediate(resolve))
  assert.deepEqual(order, [])
  order.push("installed")
  finish()
  await pending
  assert.deepEqual(order, [ "installed", "verify" ])
})

test("failure to install another model does not stop synthesis with installed Faber", async t => {
  const pending = Promise.withResolvers()
  t.mock.method(navigator.locks, "request", () => pending.promise)
  const other = "pt_BR-cadu-medium"
  const installation = installModel(other)
  const failedInstall = assert.rejects(installation, /installation failed/)
  const piper = piperDouble()
  const preparation = createPiperPreparation({
    loadCatalog: async () => catalog(), verifyModel: async () => {}, pendingInstallation: pendingModelInstallation,
  })
  const synthesis = createSynthesis({ ...preparation, piper })
  const result = synthesis.synthesize("Texto", faber)
  await new Promise(resolve => setImmediate(resolve))
  pending.reject(new Error("installation failed"))
  await failedInstall
  await result
  assert.equal(piper.calls.length, 1)
})

test("cancellation during model preparation never starts inference", async () => {
  let release
  let entered
  const blocked = new Promise((resolve) => { release = resolve })
  const preparing = new Promise((resolve) => { entered = resolve })
  const piper = piperDouble()
  const synthesis = createSynthesis({
    prepare: async () => { entered(); await blocked },
    prepared: new Map(),
    piper,
  })
  const pending = synthesis.synthesize("Texto", faber)
  await preparing
  synthesis.cancelSynthesis()
  release()
  await assert.rejects(pending, /cancelled/)
  assert.equal(piper.calls.length, 0)
  assert.equal(piper.cancels, 1)
  // A request after the cancellation runs normally.
  assert.deepEqual(await synthesis.synthesize("Again", faber), new Uint8Array([ 1, 2 ]))
})

test("an additional adapter cannot replace Piper and is routed by the captured runtime", async () => {
  const piper = piperDouble()
  const base = { prepare: async () => {}, prepared: new Map(), piper }
  assert.throws(() => createSynthesis({ ...base, additionalAdapters: new Map([ [ "piper-web", { synthesize: async () => new Uint8Array() } ] ]) }), /already registered/)
  const other = { synthesize: async () => new Uint8Array([ 9 ]) }
  const synthesis = createSynthesis({ ...base, additionalAdapters: new Map([ [ "other-web", other ] ]) })
  assert.deepEqual(await synthesis.synthesize("x", { engine: "other", session: { runtime: "other-web" } }), new Uint8Array([ 9 ]))
  assert.equal(piper.calls.length, 0)
})

function runtimeWith(Session) {
  return createConversionRuntime({
    loadBindings: async () => ({ ConversionSession: Session }),
    loadCatalog: async () => catalog(),
    synthesis: { synthesize: async () => new Uint8Array(), cancelSynthesis: () => {} },
  })
}
const preferences = { policy_version: 2, primary: faber, secondary: null, allow_online_fallback: false }
const chapters = [ { index: 0, name: "Chapter", text: "Source", charCount: 6 } ]

test("a Rust preparation rejection is classified so listening recovery stays available", async () => {
  const runtime = runtimeWith(function () { throw "Language is unavailable in this runtime" })
  await assert.rejects(runtime.create(chapters, preferences, "en-US"), (error) =>
    error instanceof TtsPreparationError && /Language is unavailable/.test(error.message))
})

test("a saved-state rejection is preserved and the prepared Rust session is freed", async () => {
  let freed = 0
  const failure = new Error("Corrupt saved policy")
  const runtime = runtimeWith(function () {
    return { free: () => { freed++ }, restore_policy_state_json: () => { throw failure } }
  })
  await assert.rejects(runtime.create(chapters, preferences, "pt-BR", "corrupt"), (error) => error === failure)
  assert.equal(freed, 1)
  const legacy = runtimeWith(function () { return { free: () => { freed++ } } })
  await assert.rejects(legacy.create(chapters, preferences, "pt-BR", "state"), /cannot restore the saved session policy/)
  assert.equal(freed, 2)
})

test("the session receives the chapters, captured preferences and language as JSON", async () => {
  const received = []
  const runtime = runtimeWith(function (...args) { received.push(args); return { restore_policy_state_json: (state) => received.push(state) } })
  await runtime.create(chapters, preferences, "pt-BR", "state")
  assert.deepEqual(received, [ [ JSON.stringify(chapters), JSON.stringify(preferences), "pt-BR" ], "state" ])
})

test("capture pins the catalog session for model selections and leaves system voices untouched", async () => {
  const runtime = runtimeWith(function () {})
  const captured = await runtime.capturePreferences({ policy_version: 2, primary: { ...faber }, secondary: { ...system }, allow_online_fallback: false })
  assert.equal(captured.primary.session.runtime, "piper-web")
  assert.equal(captured.primary.session.model_revision, "sha-pt_BR-faber-medium")
  assert.deepEqual(captured.secondary, system)
  await assert.rejects(runtime.capturePreferences({ primary: { engine: "piper", model_id: "unknown" }, secondary: null }), /no compatible browser runtime/)
  await runtime.validateSelection(faber)
  await assert.rejects(runtime.validateSelection({ engine: "piper", model_id: "unknown" }), /no compatible browser audio runtime/)
  await assert.rejects(runtime.validateSelection({ ...faber, session: { runtime: "other-web" } }), /no compatible browser audio runtime/)
})
