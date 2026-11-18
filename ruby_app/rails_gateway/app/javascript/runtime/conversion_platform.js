// Composes the production conversion objects of this page: IndexedDB job
// store, repository, Rust session runtime, Piper module worker from the
// runtime tree, model verification and the conversion client. The synthesis
// can be replaced through `options.synthesis` (used only by the test page).

import { loadConverterRuntime, loadTtsCatalog, runtimeBaseUrl } from "runtime/converter_runtime"
import { PiperClient } from "runtime/piper_client"
import { pendingModelInstallation } from "runtime/model_installation"
import { ModelIntegrity } from "runtime/model_integrity"
import { createConversionRuntime, createPiperPreparation, createSynthesis } from "runtime/conversion_runtime"
import { IndexedDBJobStore } from "runtime/job_store"
import { JobRepository } from "runtime/job_repository"
import { JobExecution } from "runtime/job_execution"
import { ConversionClient } from "runtime/conversion_client"
import { audioSeals, storedAudioUse } from "runtime/audio_identity"
import { loadTtsPreferences } from "runtime/tts_preferences"

const PIPER_WORKER_PATH = "workers/piper_worker.js"

/** @param {any} source @param {any} audio */
async function seal(source, audio) {
  const bindings = await loadConverterRuntime()
  return audioSeals(source, audio, bindings.tts_request_cache_material_v2)
}

/** @param {any} saved @param {any} audio */
async function matches(saved, audio) {
  const bindings = await loadConverterRuntime()
  return storedAudioUse(saved, audio, bindings.tts_request_cache_material_v2)
}

/**
 * @param {{storage?: Storage, synthesis?: import("./conversion_runtime.js").Synthesizer, pendingInstallation?: (modelId: string) => Promise<void> | undefined}} [options]
 */
export function createConversionPlatform({ storage, synthesis, pendingInstallation = pendingModelInstallation } = {}) {
  const integrity = new ModelIntegrity()
  const piper = new PiperClient(() => new Worker(new URL(PIPER_WORKER_PATH, runtimeBaseUrl()), { type: "module" }))
  const runtime = createConversionRuntime({
    loadBindings: loadConverterRuntime,
    loadCatalog: loadTtsCatalog,
    synthesis: synthesis ?? createSynthesis({
      ...createPiperPreparation({ loadCatalog: loadTtsCatalog, verifyModel: (model) => integrity.verifyModel(model), pendingInstallation }),
      piper,
    }),
  })
  const repository = new JobRepository(new IndexedDBJobStore(), matches)
  const execution = new JobExecution({ runtime, repository, seal })
  const client = new ConversionClient({ runtime, repository, execution, loadPreferences: () => loadTtsPreferences(storage) })
  return { client, integrity, repository }
}
