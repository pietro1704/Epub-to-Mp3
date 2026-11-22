// The browser conversion runtime: Rust ConversionSession creation, selection
// capture against the Rust catalog, model readiness before inference and the
// synthesis adapters. Port of the former React client's BrowserConversionRuntime.ts (removed in the Rails cutover).
// All I/O (bindings, catalog, model verification, the Piper client) is
// injected, so job execution can run against this module or a test fixture.

import { browserSelections } from "runtime/tts_catalog"

/**
 * @typedef {import("./tts_catalog.js").TtsSelection} TtsSelection
 * @typedef {import("./tts_catalog.js").TtsSessionSelection} TtsSessionSelection
 * @typedef {import("./tts_preferences.js").TtsPreferences} TtsPreferences
 * @typedef {import("./converter_runtime.js").TtsCatalog} TtsCatalog
 * @typedef {import("./converter_runtime.js").TtsCatalogModel} TtsCatalogModel
 */
/**
 * @typedef {object} SynthesisIdentity
 * @property {TtsSessionSelection} selection
 * @property {string} runtime_revision
 * @property {Record<string, string>} artifacts
 * @property {boolean} reusable
 * @typedef {{format: {encoding: "mp3"}, audio: Uint8Array, identity: SynthesisIdentity}} Synthesis
 * @typedef {object} Synthesizer
 * @property {(text: string, selection: TtsSelection) => Promise<Uint8Array | Synthesis>} synthesize
 * @property {() => void} [cancelSynthesis]
 * @typedef {object} PiperAudio
 * @property {(text: string, modelId?: string, modelRevision?: string, voice?: string) => Promise<{audio: Uint8Array, modelRevision: string, voice: string}>} synthesize
 * @property {() => void} cancel
 */
/**
 * @typedef {object} ConversionRuntime
 * @property {(preferences: TtsPreferences) => Promise<TtsPreferences>} capturePreferences
 * @property {(selection: TtsSelection) => Promise<void>} validateSelection
 * @property {(chapters: unknown[], preferences: TtsPreferences, language: string, policyState?: string) => Promise<any>} create
 * @property {(text: string, selection: TtsSelection) => Promise<Uint8Array | Synthesis>} synthesize
 * @property {() => void} [cancelSynthesis]
 */

/** Preparation failures can offer listening-only system speech under the captured policy. */
export class TtsPreparationError extends Error {
  /** @param {string} message */
  constructor(message) {
    super(message)
    this.name = "TtsPreparationError"
  }
}

/**
 * Checks a Piper selection against the catalog and the installed files, and
 * remembers the identity a receipt for that model must carry.
 * @param {{loadCatalog: (manual?: boolean) => Promise<TtsCatalog>, verifyModel: (model: TtsCatalogModel) => Promise<void>, pendingInstallation?: (modelId: string) => Promise<void> | undefined}} io
 */
export function createPiperPreparation({ loadCatalog, verifyModel, pendingInstallation = () => undefined }) {
  /** @type {Map<string, {selection: TtsSessionSelection, runtimeRevision: string, artifacts: Record<string, string>}>} */
  const prepared = new Map()
  /** @param {TtsSelection} selection */
  const prepare = async (selection) => {
    const catalog = await loadCatalog(Boolean(selection.session))
    const model = catalog.models.find((candidate) => candidate.id === selection.model_id && candidate.engine === selection.engine)
    const available = browserSelections(catalog).find((candidate) =>
      candidate.model_id === selection.model_id && candidate.engine === selection.engine)
    if (!model || !available?.session) throw new Error("The selected model has no compatible browser audio runtime.")
    const session = selection.session
    if (session && (
      session.runtime !== available.session.runtime ||
      session.provider !== model.engine ||
      session.model_id !== model.id ||
      session.model_revision !== model.revision ||
      Object.keys(session.options).length > 0))
      throw new Error("The captured model/runtime revision is incompatible with this browser.")
    const installation = pendingInstallation(model.id)
    if (installation) await installation
    await verifyModel(model)
    const descriptor = catalog.providers.find((candidate) =>
      candidate.runtime === available.session?.runtime && candidate.provider === model.engine)
    if (!descriptor) throw new Error("The selected model has no compatible browser audio runtime.")
    prepared.set(model.id, {
      selection: available.session,
      runtimeRevision: descriptor.revision,
      artifacts: Object.fromEntries(model.artifacts.map((artifact) => [ artifact.name, artifact.sha256 ])),
    })
  }
  return { prepare, prepared }
}

/**
 * Routes each segment to its runtime adapter. A cancellation retires the
 * active request and any request still preparing.
 * @param {{prepare: (selection: TtsSelection) => Promise<void>, prepared: Map<string, {selection: TtsSessionSelection, runtimeRevision: string, artifacts: Record<string, string>}>, piper: PiperAudio, additionalAdapters?: ReadonlyMap<string, Synthesizer>}} options
 * @returns {Required<Synthesizer>}
 */
export function createSynthesis({ prepare, prepared, piper, additionalAdapters = new Map() }) {
  let generation = 0
  /** @type {Synthesizer} */
  const piperAdapter = {
    synthesize: async (text, selection) => {
      const requestedGeneration = generation
      await prepare(selection)
      if (requestedGeneration !== generation) throw new Error("Piper synthesis cancelled.")
      const known = prepared.get(selection.model_id ?? "")
      const audio = await piper.synthesize(
        text,
        selection.model_id ?? undefined,
        selection.session?.model_revision ?? known?.selection.model_revision ?? undefined,
        selection.voice ?? undefined,
      )
      if (!known) return audio.audio
      return {
        format: { encoding: "mp3" },
        audio: audio.audio,
        identity: {
          selection: { ...known.selection, voice: audio.voice, model_revision: audio.modelRevision },
          runtime_revision: known.runtimeRevision,
          artifacts: known.artifacts,
          reusable: true,
        },
      }
    },
    cancelSynthesis: () => {
      generation++
      piper.cancel()
    },
  }
  if (additionalAdapters.has("piper-web")) throw new Error("The Piper browser adapter is already registered")
  const adapters = new Map([ [ "piper-web", piperAdapter ], ...additionalAdapters ])
  /** @type {Synthesizer | undefined} */
  let active
  let lease = 0
  return {
    synthesize: async (text, selection) => {
      const runtime = selection.session?.runtime ?? (selection.engine === "piper" ? "piper-web" : "")
      const adapter = adapters.get(runtime)
      if (!adapter) throw new Error("The requested browser runtime adapter is unavailable")
      active = adapter
      const requestedLease = lease
      try {
        const audio = await adapter.synthesize(text, selection)
        if (requestedLease !== lease) throw new Error("Synthesis cancelled.")
        return audio
      } finally {
        if (active === adapter) active = undefined
      }
    },
    cancelSynthesis: () => {
      lease++
      active?.cancelSynthesis?.()
    },
  }
}

/**
 * @param {{loadBindings: () => Promise<any>, loadCatalog: (manual?: boolean) => Promise<TtsCatalog>, synthesis: Synthesizer}} io
 * @returns {ConversionRuntime}
 */
export function createConversionRuntime({ loadBindings, loadCatalog, synthesis }) {
  return {
    capturePreferences: async (preferences) => {
      const choices = browserSelections(await loadCatalog())
      /** @param {TtsSelection} selection @returns {TtsSelection} */
      const capture = (selection) => {
        if (selection.session || selection.engine === "system") return selection
        const match = choices.find((choice) => choice.engine === selection.engine && choice.model_id === selection.model_id)
        if (!match?.session) throw new Error("The selected model has no compatible browser runtime")
        return { ...selection, session: { ...match.session, voice: /** @type {string | null} */ (selection.voice) } }
      }
      return {
        ...structuredClone(preferences),
        primary: capture(preferences.primary),
        secondary: preferences.secondary ? capture(preferences.secondary) : null,
      }
    },
    validateSelection: async (selection) => {
      const available = browserSelections(await loadCatalog(Boolean(selection.session))).find((candidate) =>
        candidate.engine === selection.engine &&
        candidate.model_id === selection.model_id &&
        (!selection.session || candidate.session?.runtime === selection.session.runtime))
      if (!available) throw new Error("The selected model has no compatible browser audio runtime.")
    },
    create: async (chapters, preferences, language, policyState) => {
      const bindings = await loadBindings()
      let session
      try {
        session = new bindings.ConversionSession(JSON.stringify(chapters), JSON.stringify(preferences), language)
      } catch (error) {
        throw new TtsPreparationError(String(error))
      }
      if (policyState) {
        if (typeof session.restore_policy_state_json !== "function") {
          session.free?.()
          throw new Error("The embedded converter cannot restore the saved session policy")
        }
        try {
          session.restore_policy_state_json(policyState)
        } catch (error) {
          session.free?.()
          throw error
        }
      }
      return session
    },
    synthesize: (text, selection) => synthesis.synthesize(text, selection),
    cancelSynthesis: () => synthesis.cancelSynthesis?.(),
  }
}
