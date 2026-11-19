// Run with: node --test --test-concurrency=2 browser_runtime/
import assert from "node:assert/strict"
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pathToFileURL } from "node:url"
import { test } from "node:test"
import { prepareTtsRuntime } from "./prepare_tts_runtime.mjs"

const CLASSIC_PHONEMIZER = "var createPiperPhonemize = (() => (options) => ({ options }))();\n"

async function installedPackages(root, phonemizer = CLASSIC_PHONEMIZER) {
  const onnx = join(root, "onnxruntime-web/dist")
  const piper = join(root, "@diffusionstudio/piper-wasm/build")
  await mkdir(onnx, { recursive: true })
  await mkdir(piper, { recursive: true })
  for (const name of ["ort.wasm.min.mjs", "ort-wasm-simd-threaded.mjs", "ort-wasm-simd-threaded.wasm", "ort.all.min.mjs"])
    await writeFile(join(onnx, name), `onnx ${name}`)
  for (const name of ["piper_phonemize.wasm", "piper_phonemize.data"]) await writeFile(join(piper, name), `piper ${name}`)
  await writeFile(join(piper, "piper_phonemize.js"), phonemizer)
}

async function workspace(t) {
  const root = await mkdtemp(join(tmpdir(), "prepare-tts-runtime-"))
  t.after(() => rm(root, { recursive: true, force: true }))
  return { packages: join(root, "node_modules"), destination: join(root, "out/tts") }
}

test("copies exactly the files the worker loads, with their original names", async (t) => {
  const { packages, destination } = await workspace(t)
  await installedPackages(packages)

  await prepareTtsRuntime(destination, packages)

  assert.deepEqual((await readdir(destination)).sort(), [
    "ort-wasm-simd-threaded.mjs",
    "ort-wasm-simd-threaded.wasm",
    "ort.wasm.min.mjs",
    "piper_phonemize.data",
    "piper_phonemize.js",
    "piper_phonemize.wasm",
  ])
  assert.equal(await readFile(join(destination, "ort-wasm-simd-threaded.wasm"), "utf8"), "onnx ort-wasm-simd-threaded.wasm")
})

test("publishes the classic phonemizer script as an importable ES module", async (t) => {
  const { packages, destination } = await workspace(t)
  await installedPackages(packages)

  await prepareTtsRuntime(destination, packages)

  // Node treats .js outside a package as CommonJS; a module worker does not.
  const published = await readFile(join(destination, "piper_phonemize.js"), "utf8")
  await writeFile(join(destination, "piper_phonemize.mjs"), published)
  const module = await import(pathToFileURL(join(destination, "piper_phonemize.mjs")).href)
  assert.deepEqual(module.default({ locateFile: "kept" }), { options: { locateFile: "kept" } })
  assert.ok(published.startsWith(CLASSIC_PHONEMIZER))
})

test("stops when an upgrade changes how the phonemizer declares its factory", async (t) => {
  const { packages, destination } = await workspace(t)
  await installedPackages(packages, "export default function createPiperPhonemize() {}\n")

  await assert.rejects(prepareTtsRuntime(destination, packages), /no longer declares createPiperPhonemize/)
})

test("stops when a pinned file is missing", async (t) => {
  const { packages, destination } = await workspace(t)
  await installedPackages(packages)
  await rm(join(packages, "onnxruntime-web/dist/ort.wasm.min.mjs"))

  await assert.rejects(prepareTtsRuntime(destination, packages), { code: "ENOENT" })
})
