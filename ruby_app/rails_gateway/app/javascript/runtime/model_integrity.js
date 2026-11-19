// Verifies installed model files against the checksums of the Rust catalog
// before inference. Port of web/src/services/BrowserModelIntegrity.ts. The
// OPFS directory and the digest are injected so the policy is testable.

import { browserArtifacts } from "runtime/tts_catalog"

/**
 * @typedef {import("./converter_runtime.js").TtsCatalogModel} TtsCatalogModel
 * @typedef {{name: string, sha256: string, bytes: number}} ExpectedArtifact
 * @typedef {object} ArtifactDirectory
 * @property {(name: string) => Promise<{getFile(): Promise<File>}>} getFileHandle
 * @property {(name: string) => Promise<void>} removeEntry
 * @typedef {(data: ArrayBuffer) => Promise<ArrayBuffer>} Digest
 */

export const FABER_ARTIFACTS = Object.freeze([
  Object.freeze({ name: "pt_BR-faber-medium.onnx", sha256: "858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7", bytes: 63_201_294 }),
  Object.freeze({ name: "pt_BR-faber-medium.onnx.json", sha256: "7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f", bytes: 4_855 }),
])

/** @type {Digest} */
const sha256 = (data) => crypto.subtle.digest("SHA-256", data)

/** @returns {Promise<ArtifactDirectory>} */
async function piperDirectory() {
  return (await navigator.storage.getDirectory()).getDirectoryHandle("piper")
}

export class ModelIntegrity {
  /**
   * @param {{openDirectory?: () => Promise<ArtifactDirectory>, digest?: Digest}} [io]
   */
  constructor({ openDirectory = piperDirectory, digest = sha256 } = {}) {
    this.openDirectory = openDirectory
    this.digest = digest
    /** File identities already hashed in this page, so weights are not re-read per segment. @type {Map<string, string>} */
    this.verified = new Map()
  }

  /**
   * The Faber pair; corrupt files are removed so the next install starts clean.
   * @param {ArtifactDirectory} [directory]
   */
  verifyFaber(directory) {
    return this.verify(FABER_ARTIFACTS, "Faber medium", directory, true)
  }

  /**
   * Any catalog model; corrupt files stay until the user reinstalls explicitly.
   * @param {TtsCatalogModel} model
   * @param {ArtifactDirectory} [directory]
   */
  verifyModel(model, directory) {
    return this.verify(browserArtifacts(model), model.id, directory, false)
  }

  invalidate() { this.verified.clear() }

  /**
   * @param {readonly ExpectedArtifact[]} expected
   * @param {string} label
   * @param {ArtifactDirectory | undefined} directory
   * @param {boolean} removeCorrupt
   */
  async verify(expected, label, directory, removeCorrupt) {
    const artifacts = directory ?? await this.openDirectory()
    for (const artifact of expected) {
      /** @type {File} */
      let file
      try {
        file = await (await artifacts.getFileHandle(artifact.name)).getFile()
      } catch {
        throw new Error(`${label} is incomplete. Install the model before converting.`)
      }
      const identity = `${artifact.sha256}:${file.size}:${file.lastModified}`
      if (this.verified.get(artifact.name) === identity) continue
      const digest = await this.digest(await file.arrayBuffer())
      const hash = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")
      if (file.size !== artifact.bytes || hash !== artifact.sha256) {
        this.verified.clear()
        for (const corrupted of removeCorrupt ? expected : []) {
          try { await artifacts.removeEntry(corrupted.name) } catch { /* Preserve unrelated models. */ }
        }
        throw new Error(`${label} checksum validation failed. ${removeCorrupt
          ? "Corrupt model files were removed; reinstall the model."
          : "Reinstall the model explicitly."}`)
      }
      this.verified.set(artifact.name, identity)
    }
  }
}
