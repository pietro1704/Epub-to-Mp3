import test from "node:test"
import assert from "node:assert/strict"
import { installArtifacts, installedModel } from "../app/javascript/runtime/model_installation.js"

const model = { id: "voice", artifacts: [] }
const content = new Map()
for (const [name, body] of [ [ "model.onnx", "Test weights" ], [ "model.onnx.json", '{"fixture":true}' ] ]) {
  const url = "https://models.example/" + name
  const bytes = new TextEncoder().encode(body)
  const sha256 = Buffer.from(await crypto.subtle.digest("SHA-256", bytes)).toString("hex")
  model.artifacts.push({ name, url, bytes: bytes.length, sha256 })
  content.set(url, bytes)
}

// Simulates a directory with atomic per-file commits; failures can occur after
// creation, so rollback must remove a newly-created empty file too.
class Directory {
  files = new Map()
  aborts = 0
  async getFileHandle(name, options = {}) {
    if (!this.files.has(name)) {
      if (!options.create) throw new DOMException("Not found", "NotFoundError")
      this.files.set(name, new Blob())
    }
    return {
      getFile: async () => this.files.get(name),
      createWritable: async () => {
        let pending
        return {
          write: async blob => { pending = blob },
          close: async () => {
            if (name === this.failName) { this.failName = null; throw new Error("Quota exceeded") }
            this.files.set(name, pending)
          },
          abort: async () => { this.aborts++ },
        }
      },
    }
  }
  async removeEntry(name) {
    if (!this.files.delete(name)) throw new DOMException("Not found", "NotFoundError")
  }
}

test("publication failure restores every original and removes temporary or newly-created artifacts", async () => {
  for (const withConfig of [ false, true ]) {
    const directory = new Directory()
    const previous = new Map([ [ "voice.onnx", new Blob([ "old" ]) ], [ "another.onnx", new Blob([ "unrelated" ]) ] ])
    if (withConfig) previous.set("voice.onnx.json", new Blob([ "old-config" ]))
    directory.files = new Map(previous)
    directory.failName = "voice.onnx.json"
    const requests = []
    const download = async url => { requests.push(url); return new Response(content.get(url)) }
    await assert.rejects(installArtifacts(model, directory, download), /Quota exceeded/)
    assert.equal(directory.aborts, 1)
    assert.deepEqual([...directory.files.keys()].sort(), [...previous.keys()].sort())
    for (const [name, blob] of previous) assert.equal(await directory.files.get(name).text(), await blob.text())
    assert.equal(await installedModel(model, directory), false)
    await installArtifacts(model, directory, download)
    assert.equal(await installedModel(model, directory), true)
    await installArtifacts(model, directory, () => { throw new Error("An installed model must stay offline") })
    assert.equal(requests.length, 4)
  }
})

test("download and digest failures leave the old pair untouched", async () => {
  for (const response of [ new Response("wrong"), new Response("", { status: 503 }) ]) {
    const directory = new Directory()
    const original = new Blob([ "old" ])
    directory.files.set("voice.onnx", original)
    await assert.rejects(installArtifacts(model, directory, async () => response), /checksum validation failed|HTTP 503/)
    assert.deepEqual([...directory.files.keys()], [ "voice.onnx" ])
    assert.equal(directory.files.get("voice.onnx"), original)
  }
})
