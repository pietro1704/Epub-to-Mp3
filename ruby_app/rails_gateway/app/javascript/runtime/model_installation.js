// An explicit install stages and verifies every artifact before changing a model's public names.
// Copies of the original files remain readable during rollback (OPFS File snapshots do not).
import { browserArtifacts, browserSelections } from "runtime/tts_catalog"
import { loadTtsCatalog } from "runtime/converter_runtime"

async function openModels(create) {
  if (!navigator.storage?.getDirectory) throw new DOMException("Origin-private file system unavailable", "NotSupportedError")
  const root = await navigator.storage.getDirectory()
  return root.getDirectoryHandle("piper", { create })
}

async function read(directory, name) {
  try { return await (await directory.getFileHandle(name)).getFile() }
  catch (error) {
    if (error.name !== "NotFoundError") throw error
    return null
  }
}

async function write(directory, name, blob) {
  const handle = await directory.getFileHandle(name, { create: true })
  const writer = await handle.createWritable()
  try { await writer.write(blob); await writer.close() }
  catch (error) { await writer.abort().catch(() => {}); throw error }
}

async function matches(blob, artifact) {
  if (!blob || blob.size !== artifact.bytes) return false
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", await blob.arrayBuffer()))
  return Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("") === artifact.sha256
}

async function remove(directory, name) {
  try { await directory.removeEntry(name) }
  catch (error) { if (error.name !== "NotFoundError") throw error }
}

export async function installedModel(model, directory) {
  try { directory ??= await openModels(false) }
  catch (error) { if (error.name === "NotFoundError") return false; throw error }
  for (const artifact of browserArtifacts(model)) {
    if (!await matches(await read(directory, artifact.name), artifact)) return false
  }
  return true
}

export async function installArtifacts(model, directory, download = fetch) {
  if (await installedModel(model, directory)) return
  const artifacts = browserArtifacts(model)
  const prefix = ".install-" + crypto.randomUUID()
  const stage = name => prefix + "-new-" + name
  const backup = name => prefix + "-old-" + name
  const previous = new Set()
  const touched = []
  let rollbackComplete = true
  try {
    for (const artifact of artifacts) {
      const response = await download(artifact.url)
      if (!response.ok) throw new Error("Model download failed: HTTP " + response.status)
      const blob = await response.blob()
      if (!await matches(blob, artifact)) throw new Error("Model checksum validation failed: " + artifact.name)
      await write(directory, stage(artifact.name), blob)
      const old = await read(directory, artifact.name)
      if (old) {
        await write(directory, backup(artifact.name), old)
        previous.add(artifact.name)
      }
    }
    for (const { name } of artifacts) {
      touched.push(name)
      await write(directory, name, await read(directory, stage(name)))
    }
    if (!await installedModel(model, directory)) throw new Error("Installed model verification failed.")
  } catch (error) {
    for (const name of touched) {
      try {
        if (previous.has(name)) await write(directory, name, await read(directory, backup(name)))
        else await remove(directory, name)
      } catch { rollbackComplete = false }
    }
    if (!rollbackComplete) throw new Error("Model installation failed. Retained previous artifacts: " + prefix, { cause: error })
    throw error
  } finally {
    for (const { name } of artifacts) {
      await remove(directory, stage(name))
      if (rollbackComplete) await remove(directory, backup(name))
    }
  }
}

let active
export const pendingModelInstallation = modelId => active?.modelId === modelId ? active?.promise : undefined

export function installModel(modelId) {
  if (active) {
    if (active.modelId === modelId) return active.promise
    return Promise.reject(new Error("Another model installation is active."))
  }
  const install = async () => {
    const catalog = await loadTtsCatalog()
    if (!browserSelections(catalog).some(selection => selection.model_id === modelId)) {
      throw new Error("No compatible browser runtime for the selected model.")
    }
    const model = catalog.models.find(candidate => candidate.id === modelId)
    await installArtifacts(model, await openModels(true))
  }
  const promise = navigator.locks.request("ebook-tts:install-model", install).finally(() => { active = undefined })
  active = { modelId, promise }
  return promise
}
