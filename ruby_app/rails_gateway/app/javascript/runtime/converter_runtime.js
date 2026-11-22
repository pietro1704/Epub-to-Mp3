// Loads the generated Rust/WASM runtime from the un-digested tree Rails
// publishes under /runtime/<id>/. The glue locates its .wasm sibling by
// relative URL, so it is imported by URL instead of through the import map.

/**
 * @typedef {object} TtsArtifact
 * @property {string} name
 * @property {string} url
 * @property {string} sha256
 * @property {number} bytes
 */
/**
 * @typedef {object} TtsCatalogModel
 * @property {string} id
 * @property {string} engine
 * @property {string} revision
 * @property {TtsArtifact[]} artifacts
 * @property {boolean} [manual_only]
 * @property {boolean} runtime_available
 */
/**
 * @typedef {object} TtsCatalog
 * @property {2} version
 * @property {TtsCatalogModel[]} models
 * @property {Array<{provider: string, runtime: string, revision: string, targets: string[], capabilities: {audio_bytes: boolean, online: boolean}}>} providers
 */

const RUNTIME_BASE = 'meta[name="converter-runtime-base"]'
const BINDINGS_PATH = "wasm/converter_wasm.js"

/** @type {Promise<any> | undefined} */
let bindings
/** @type {Map<boolean, Promise<TtsCatalog>>} */
const catalogs = new Map()

/**
 * Absolute base URL of the runtime tree, announced by the server.
 * @param {Document} [page]
 */
export function runtimeBaseUrl(page = document) {
  const base = page.querySelector(RUNTIME_BASE)?.getAttribute("content")
  if (!base) throw new Error("The converter runtime is not published by this server.")
  return new URL(base, page.baseURI)
}

/** Imports and initialises the converter-wasm bindings once per page. */
export function loadConverterRuntime() {
  bindings ??= (async () => {
    const module = await import(new URL(BINDINGS_PATH, runtimeBaseUrl()).href)
    await module.default()
    return module
  })().catch((error) => {
    bindings = undefined
    throw error
  })
  return bindings
}

/** @param {boolean} [manual] Include models requiring explicit selection. */
export function loadTtsCatalog(manual = false) {
  const existing = catalogs.get(manual)
  if (existing) return existing
  const catalog = (async () => {
    const runtime = await loadConverterRuntime()
    if (typeof runtime.tts_catalog_json_v2 !== "function")
      throw new Error("The embedded converter does not support the version 2 TTS catalog.")
    const json = manual && typeof runtime.tts_manual_catalog_json_v2 === "function"
      ? runtime.tts_manual_catalog_json_v2() : runtime.tts_catalog_json_v2()
    if (typeof json !== "string") throw new Error("Invalid TTS catalog")
    const decoded = /** @type {TtsCatalog} */ (JSON.parse(json))
    if (decoded.version !== 2 || !Array.isArray(decoded.models) || !Array.isArray(decoded.providers))
      throw new Error("Unsupported TTS catalog version")
    return decoded
  })().catch((error) => {
    catalogs.delete(manual)
    throw error
  })
  catalogs.set(manual, catalog)
  return catalog
}
