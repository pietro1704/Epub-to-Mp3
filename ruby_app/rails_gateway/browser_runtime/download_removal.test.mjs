import assert from "node:assert/strict"
import test from "node:test"
import { JobRepository } from "../app/javascript/runtime/job_repository.js"

test("a rejected deletion leaves the job and its chapter and segment URLs usable until retry commits", async () => {
  let denied = true
  const repository = new JobRepository({ async remove() { if (denied) throw new Error("storage failure") } }, async () => true)
  const chapter = URL.createObjectURL(new Blob([ "chapter" ]))
  const segment = URL.createObjectURL(new Blob([ "segment" ]))
  const job = { snapshot: { jobId: "finished", outputs: [ { url: chapter } ] }, chunks: new Map([ [ 0, { chunks: [ { url: segment } ] } ] ]) }
  repository.jobs.set(job.snapshot.jobId, job)
  try {
    await assert.rejects(repository.remove(job), /storage failure/)
    assert.equal(repository.get("finished"), job)
    assert.equal(await (await fetch(chapter)).text(), "chapter")
    assert.equal(await (await fetch(segment)).text(), "segment")
    denied = false
    await repository.remove(job)
    assert.throws(() => repository.get("finished"), /not found/)
    await assert.rejects(fetch(chapter))
    await assert.rejects(fetch(segment))
  } finally {
    URL.revokeObjectURL(chapter)
    URL.revokeObjectURL(segment)
  }
})
