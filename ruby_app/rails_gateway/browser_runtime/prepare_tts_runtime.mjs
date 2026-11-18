// Copies the pinned browser TTS libraries into a directory that becomes the
// tts/ subtree of the generated runtime tree. Nothing is bundled or renamed:
// ONNX Runtime Web and Emscripten locate their siblings by relative URL.
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises"
import { resolve } from "node:path"
import { fileURLToPath } from "node:url"

const INSTALLED_PACKAGES = fileURLToPath(new URL("./node_modules", import.meta.url))

const COPIED_FILES = {
  // The extern-wasm ES module imports its companion loader from env.wasm.wasmPaths.
  "onnxruntime-web/dist": ["ort.wasm.min.mjs", "ort-wasm-simd-threaded.mjs", "ort-wasm-simd-threaded.wasm"],
  "@diffusionstudio/piper-wasm/build": ["piper_phonemize.wasm", "piper_phonemize.data"],
}

// Emscripten emitted the phonemizer as a classic script that only assigns a
// factory variable. A module worker cannot importScripts, so the published
// file gains a default export and is otherwise byte-identical.
const PHONEMIZER = {
  source: "@diffusionstudio/piper-wasm/build/piper_phonemize.js",
  published: "piper_phonemize.js",
  factory: "createPiperPhonemize",
}

/**
 * @param {string} destination directory that receives the tts/ files
 * @param {string} [packages] node_modules directory holding the pinned packages
 */
export async function prepareTtsRuntime(destination, packages = INSTALLED_PACKAGES) {
  await mkdir(destination, { recursive: true })
  for (const [directory, names] of Object.entries(COPIED_FILES)) {
    for (const name of names) await copyFile(resolve(packages, directory, name), resolve(destination, name))
  }
  const classicScript = await readFile(resolve(packages, PHONEMIZER.source), "utf8")
  if (!classicScript.includes(`var ${PHONEMIZER.factory} =`))
    throw new Error(`${PHONEMIZER.source} no longer declares ${PHONEMIZER.factory}; review how it is published.`)
  await writeFile(resolve(destination, PHONEMIZER.published), `${classicScript}\nexport default ${PHONEMIZER.factory};\n`)
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const destination = process.argv[2]
  if (!destination) {
    console.error("usage: node prepare_tts_runtime.mjs OUTPUT_DIR")
    process.exit(64)
  }
  await prepareTtsRuntime(resolve(destination))
}
