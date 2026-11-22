// Browser view of the Rust TTS catalog. Port of the pure half of
// the former React client's TtsCatalog.ts (removed in the Rails cutover); loading the catalog from converter-wasm
// stays in runtime/converter_runtime (loadTtsCatalog).

/**
 * @typedef {import("./converter_runtime.js").TtsCatalog} TtsCatalog
 * @typedef {import("./converter_runtime.js").TtsCatalogModel} TtsCatalogModel
 * @typedef {import("./converter_runtime.js").TtsArtifact} TtsArtifact
 */
/**
 * @typedef {object} TtsSessionSelection
 * @property {2} version
 * @property {string} provider
 * @property {string} runtime
 * @property {string} model_id
 * @property {string} model_revision
 * @property {string | null} voice
 * @property {Record<string, unknown>} options
 */
/**
 * @typedef {object} TtsSelection
 * @property {string} engine
 * @property {string | null} [model_id]
 * @property {string | null} [voice]
 * @property {TtsSessionSelection} [session]
 */

/**
 * Selections the browser can synthesise: catalog models whose provider has an
 * offline web adapter that returns audio bytes.
 * @param {TtsCatalog} catalog
 * @returns {TtsSelection[]}
 */
export function browserSelections(catalog) {
  return catalog.models.flatMap((model) => {
    const adapter = catalog.providers.find((provider) =>
      provider.provider === model.engine &&
      provider.targets.includes("web") &&
      provider.capabilities.audio_bytes &&
      !provider.capabilities.online)
    if (!adapter || !model.runtime_available || model.artifacts.length === 0) return []
    return [ {
      engine: model.engine,
      model_id: model.id,
      voice: null,
      session: {
        version: 2,
        provider: model.engine,
        runtime: adapter.runtime,
        model_id: model.id,
        model_revision: model.revision,
        voice: null,
        options: {},
      },
    } ]
  })
}

/**
 * Piper's OPFS adapter names a model's pair using its catalog ID.
 * @param {TtsCatalogModel} model
 * @returns {TtsArtifact[]}
 */
export function browserArtifacts(model) {
  return model.artifacts.map((artifact) => ({
    ...artifact,
    name: artifact.name === "model.onnx"
      ? `${model.id}.onnx`
      : artifact.name === "model.onnx.json" ? `${model.id}.onnx.json` : artifact.name,
  }))
}

export function browserDownloadSelections(catalog, includeLow = false) {
  const models = catalog.models.filter(model => includeLow || !model.manual_only)
  return browserSelections({ ...catalog, models })
}

export async function installedManualBrowserSelections(catalog, isInstalled) {
  const models = catalog.models.filter(model => model.manual_only)
  const selections = browserSelections({ ...catalog, models })
  const installed = await Promise.all(selections.map(async selection => {
    const model = models.find(model => model.id === selection.model_id)
    try { return await isInstalled(model) ? selection : null }
    catch { return null }
  }))
  return installed.filter(Boolean)
}
