import assert from "node:assert/strict"
import test from "node:test"
import { setImmediate as settled } from "node:timers/promises"
import { StreamPlayer } from "../app/javascript/runtime/stream_player.js"
import { LatencyObservationStore } from "../app/javascript/runtime/latency_observation.js"

function fixture(getChapterManifest) {
  const values = new Map()
  const storage = { getItem: k => values.get(k), setItem: (k, v) => values.set(k, v), removeItem: k => values.delete(k) }
  const feedback = []
  const client = { getChapterManifest, listenFrom: async () => {}, playbackFeedback: async (...args) => { feedback.push(args) } }
  const audio = {
    currentTime: 0, duration: 3, src: "", get currentSrc() { return this.src },
    hasAttribute() { return Boolean(this.src) }, removeAttribute() { this.src = "" }, load() {}, pause() {}, async play() {},
  }
  const chapters = [ 4, 7 ].map(index => ({ index, status: "completed", name: String(index) }))
  const snapshot = { state: "finished", chapterProgress: chapters }
  const latency = new LatencyObservationStore()
  const player = new StreamPlayer({ client, audio, storage, latency, render() {}, publish() {} })
  player.update("job", snapshot)
  return { player, values, snapshot, audio, feedback, latency }
}

const manifest = (index, extras = {}) => ({
  chunks: [ { index: 0, url: "blob:chapter-" + index, durationSeconds: 3, text: "First." } ], ...extras,
})

for (const retire of [ "seek", "stop", "job" ]) {
  for (const late of [ "success", "failure" ]) {
    test("late manifest " + late + " after " + retire + " cannot change the player", async () => {
      const pending = Promise.withResolvers()
      const { player, audio, snapshot, latency } = fixture(async (_job, index) => index === 4 ? pending.promise : manifest(index))
      player.start()
      if (retire === "seek") player.jump(7)
      else if (retire === "job") player.update("another", snapshot)
      else player.stop()
      await settled()
      if (late === "success") pending.resolve(manifest(4))
      else pending.reject(new Error("outdated"))
      await settled()
      assert.equal(audio.src, retire === "seek" ? "blob:chapter-7" : "")
      assert.equal(player.error, null)
      if (retire !== "seek") assert.equal(latency.snapshot()[0].records.at(-1).transition, "cancelled")
      player.stop()
    })
  }
}

test("an unmappable bookmark survives until the listener explicitly restarts its chapter", async () => {
  const { player, values, audio } = fixture(async () => manifest(4, { legacyWholeChapter: true }))
  const key = "epub-to-mp3:player-pos:job"
  values.set(key, JSON.stringify({ chapterIndex: 4, segmentIndex: 2 }))
  player.start()
  await settled()
  assert.equal(audio.src, "")
  assert.equal(player.message, "unmapped")
  assert.equal(JSON.parse(values.get(key)).segmentIndex, 2)
  player.jump(4)
  await settled()
  assert.equal(audio.src, "blob:chapter-4")
  assert.equal(JSON.parse(values.get(key)).segmentIndex, 0)
  player.stop()
})

test("confirmed segments feed the remaining chapter buffer and speed back to the owning job", async () => {
  const { player, values, audio, feedback } = fixture(async (_job, chapter) => ({
    chunks: [
      { index: 0, url: "blob:first-" + chapter, durationSeconds: 3 },
      { index: 1, url: "blob:second-" + chapter, durationSeconds: 4 },
    ],
  }))
  player.start()
  await settled()
  player.setRate(1.25)
  audio.currentTime = 1
  player.timeUpdate()
  assert.deepEqual(feedback, [ [ "job", 4, 6, 1.25 ] ])
  player.ended()
  await settled()
  assert.equal(audio.src, "blob:second-4")
  player.ended()
  await settled()
  assert.equal(audio.src, "blob:first-7")
  player.ended()
  await settled()
  player.ended()
  await settled()
  assert.equal(player.started, false)
  assert.equal(values.has("epub-to-mp3:player-pos:job"), false)
})
