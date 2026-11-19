import assert from "node:assert/strict"
import { afterEach, beforeEach, test } from "node:test"
import { NativeSpeech } from "../app/javascript/runtime/native_speech.js"

const local = { localService: true, name: "Lis", lang: "pt-BR", voiceURI: "lis" }
const policy = { language: "pt_BR", voice: null }
const owner = Symbol("first job")
let engine, synth, fixture, pausedAudio

beforeEach(() => {
  fixture = []
  pausedAudio = 0
  globalThis.document = { querySelectorAll: () => [ { pause() { pausedAudio++ } } ] }
  synth = Object.assign(new EventTarget(), {
    voices: [ local ], cancellations: 0, pauses: 0, resumes: 0,
    getVoices() { return this.voices },
    speak(utterance) { fixture.push(utterance) },
    cancel() { this.cancellations++ }, pause() { this.pauses++ }, resume() { this.resumes++ },
  })
  engine = new NativeSpeech(synth, text => ({ text }))
})
afterEach(() => {
  if (engine.session) engine.stop(engine.session.owner)
  delete globalThis.document
})

test("waits for an installed explicit voice, pauses other audio, and narrates every character once in bounded utterances", () => {
  const text = "Árvore em pé. ".repeat(200) + "Fim"
  engine.start(owner, text, { ...policy, voice: "selected" })
  assert.equal(engine.state.phase, "starting")
  assert.equal(fixture.length, 0)
  synth.voices.push({ ...local, name: "Chosen", voiceURI: "selected" })
  synth.dispatchEvent(new Event("voiceschanged"))
  assert.equal(pausedAudio, 1)
  assert.equal(fixture[0].voice.voiceURI, "selected")
  for (const utterance of fixture) {
    utterance.onstart()
    assert.equal(engine.state.voice, "Chosen (pt-BR)")
    utterance.onend()
  }
  assert.equal(engine.state.phase, "completed")
  assert.ok(fixture.length > 1)
  assert.ok(fixture.every(part => part.text.length <= 401))
  assert.equal(fixture.map(part => part.text).join(""), text)
})

test("late callbacks and stale owners cannot change a newer narration", () => {
  const other = Symbol("second job")
  engine.start(owner, "first", policy)
  const { onstart, onerror, onend } = fixture[0]
  engine.start(other, "second", policy)
  fixture[1].onstart()
  engine.togglePause(owner)
  engine.stop(owner)
  onerror(); onend(); onstart()
  assert.equal(engine.state.owner, other)
  assert.equal(engine.state.phase, "playing")
  assert.equal(synth.pauses, 0)
  assert.equal(synth.cancellations, 1)
  fixture[1].onerror()
  assert.equal(engine.state.phase, "failed")
})

test("cancellation releases a pending voice subscription and suppresses late speech", () => {
  synth.voices = []
  engine.start(owner, "first", policy)
  engine.stop(owner)
  synth.voices.push(local)
  synth.dispatchEvent(new Event("voiceschanged"))
  assert.equal(engine.state, null)
  assert.equal(fixture.length, 0)
})

test("the speech timeout excludes pauses and retires timed-out utterances", t => {
  t.mock.timers.enable({ apis: [ "setTimeout", "Date" ] })
  engine.start(owner, "held", policy)
  fixture[0].onstart()
  t.mock.timers.tick(110_000)
  engine.togglePause(owner)
  t.mock.timers.tick(300_000)
  assert.equal(engine.state.phase, "paused")
  engine.togglePause(owner)
  t.mock.timers.tick(9_999)
  assert.equal(engine.state.phase, "playing")
  t.mock.timers.tick(1)
  assert.equal(engine.state.phase, "failed")
  assert.equal(synth.cancellations, 1)
})
