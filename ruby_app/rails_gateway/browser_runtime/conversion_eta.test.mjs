import test from "node:test"
import assert from "node:assert/strict"
import {
  estimateEtaSeconds, estimateWordsBasedEtaSeconds, formatEtaDuration, remainingEtaSeconds, resolveCurrentCharsPerSecond,
} from "../app/javascript/runtime/conversion_eta.js"
import { ConversionWorkspace } from "../app/javascript/runtime/conversion_workspace.js"

test("progress-based estimate scales the elapsed time by the remaining fraction", () => {
  const startedAt = 1_000_000
  assert.equal(estimateEtaSeconds({ progressPercent: 25 }, startedAt, startedAt + 10_000), 30)
  assert.equal(estimateEtaSeconds({ progress: 0.5 }, startedAt, startedAt + 10_000), 10)
  for (const snapshot of [ { progressPercent: 0 }, { progressPercent: 100 }, {} ])
    assert.equal(estimateEtaSeconds(snapshot, startedAt, startedAt + 10_000), undefined)
  assert.equal(estimateEtaSeconds({ progressPercent: 50 }, null, startedAt), undefined)
})

test("a server estimate wins unless the word-based one is longer", () => {
  const chapterProgress = [
    { status: "completed", wordCount: 100, chars: 500, charsPerSecond: 10 },
    { status: "processing", wordCount: 100, chars: 500, charsProcessed: 250, charsPerSecond: 50 },
  ]
  // 50 remaining words, 5 chars per word, 50 chars/s = 600 wpm -> 5 s.
  assert.equal(estimateWordsBasedEtaSeconds({ chapterProgress }), 5)
  assert.equal(estimateEtaSeconds({ etaSeconds: 2, chapterProgress }, null), 5)
  assert.equal(estimateEtaSeconds({ etaSeconds: 9, chapterProgress }, null), 9)
  assert.equal(resolveCurrentCharsPerSecond(chapterProgress), 50)
  assert.equal(resolveCurrentCharsPerSecond([ { status: "completed", charsPerSecond: 7 } ]), 7)
  assert.equal(estimateWordsBasedEtaSeconds({ chapterProgress: [ { status: "completed", wordCount: 3, chars: 9 } ] }), 0)
})

test("the countdown drops one per whole second and stops at one", () => {
  const reading = { seconds: 4.2, at: 0 }
  assert.deepEqual([ 0, 999, 1000, 2500, 3000, 60_000 ].map((now) => remainingEtaSeconds(reading, now)), [ 4.2, 4.2, 4, 3, 2, 1 ])
  assert.equal(remainingEtaSeconds({ seconds: 0.5, at: 0 }, 10_000), 0.5)
  assert.equal(remainingEtaSeconds(undefined, 0), undefined)
})

test("durations keep the two largest units", () => {
  assert.deepEqual([ 0, 42, 65, 3725, 90_061 ].map(formatEtaDuration), [ "0s", "42s", "1m 5s", "1h 2m", "1d 1h" ])
})

/** A client double whose job reports the given snapshots, then finishes. */
function scriptedClient(snapshots) {
  return {
    cancelled: [],
    submit: async () => ({ jobId: "job-1" }),
    cancel: async function (jobId) { this.cancelled.push(jobId) },
    poll: async (jobId, { onSnapshot }) => {
      for (const snapshot of snapshots) {
        onSnapshot({ jobId, ...snapshot })
        await new Promise((resolve) => setTimeout(resolve, 0))
      }
      return { jobId, ...snapshots.at(-1) }
    },
  }
}

test("the workspace takes a new ETA reading only when progress moves, and clears it when the job stops", async () => {
  let clock = 0
  const client = scriptedClient([
    { state: "running", progressPercent: 0 },
    { state: "running", progressPercent: 50 },
    { state: "running", progressPercent: 50 },
    { state: "finished", progressPercent: 100 },
  ])
  const workspace = new ConversionWorkspace({ client, now: () => clock })
  const readings = []
  workspace.subscribe((state) => {
    clock += 1000
    if (state.phase === "converting") readings.push(state.eta)
  })
  await workspace.submit([ { document: { chapters: [] } } ])
  const defined = readings.filter(Boolean)
  assert.ok(defined.length >= 1, "an estimate exists once progress is above zero")
  // The repeated 50% snapshot keeps the earlier reading, so the countdown runs.
  assert.equal(new Set(defined.map((reading) => reading.at)).size, 1)
  assert.equal(workspace.state.eta, undefined)
  assert.equal(workspace.state.phase, "finished")
})

test("cancelling is shown until the job reports a terminal state", async () => {
  let release
  const client = scriptedClient([ { state: "running", progressPercent: 10 } ])
  const basePoll = client.poll
  client.poll = async (jobId, options) => {
    await basePoll(jobId, options)
    await new Promise((resolve) => { release = resolve })
    options.onSnapshot({ jobId, state: "cancelled" })
    return { jobId, state: "cancelled" }
  }
  const workspace = new ConversionWorkspace({ client })
  const run = workspace.submit([ { document: { chapters: [] } } ])
  while (!release) await new Promise((resolve) => setTimeout(resolve, 0))
  await workspace.cancelCurrent()
  assert.equal(workspace.state.cancelling, true)
  assert.deepEqual(client.cancelled, [ "job-1" ])
  release()
  await run
  assert.equal(workspace.state.cancelling, false)
  assert.equal(workspace.state.phase, "cancelled")
})

test("presentation fills server strings: phase, ETA words, failure hint and log lines", async () => {
  const { etaText, failureText, format, logLine, phaseKey, plural } = await import("../app/javascript/runtime/conversion_presentation.js")
  const strings = {
    etaDone: "finished", etaCalculating: "calculating…", etaSoon: "almost there", errorPrefix: "Details: {message}",
    errorCategoryHints: { timeout: "Too long." }, defaultFailure: "Conversion failed",
    log: { job_started: "Converting “{title}”…", job_failed: "Request failed: {message}", batch_cancelled: { one: "{remaining} left", other: "{remaining} left (many)" } },
  }
  assert.equal(phaseKey({ phase: "converting", cancelling: true }), "cancelling")
  assert.deepEqual([ "idle", "converting", "finished", "failed", "cancelled" ].map((phase) => phaseKey({ phase, cancelling: false })),
    [ "idle", "polling", "success", "error", "cancelled" ])
  const running = { phase: "converting", cancelling: false }
  assert.equal(etaText(strings, { ...running, eta: undefined }, 0), "calculating…")
  assert.equal(etaText(strings, { ...running, eta: { seconds: 65, at: 0 } }, 0), "≈ 1m 5s")
  assert.equal(etaText(strings, { ...running, eta: { seconds: 0.4, at: 0 } }, 0), "almost there")
  assert.equal(etaText(strings, { phase: "finished", cancelling: false }, 0), "finished")
  assert.equal(etaText(strings, { phase: "failed", cancelling: false }, 0), "—")
  assert.deepEqual(failureText(strings, { snapshot: { state: "failed", error: "boom", errorCategory: "timeout" } }), { error: "Details: boom", hint: "Too long." })
  assert.equal(failureText(strings, { snapshot: { state: "running", error: "boom" } }), null)
  assert.equal(format("{a} {b}", { a: 1 }), "1 {b}")
  assert.equal(plural({ one: "1", other: "n" }, 2), "n")
  const at = Date.UTC(2026, 0, 1, 12, 0, 0)
  assert.match(logLine(strings, { at, key: "job_started", params: { title: "Livro" } }, "en-US"), /^\[.+\] Converting “Livro”…$/)
  assert.match(logLine(strings, { at, key: "job_failed" }, "en-US"), /\] Conversion failed$/)
  assert.match(logLine(strings, { at, key: "batch_cancelled", params: { remaining: 1 } }, "en-US"), /\] 1 left$/)
})
