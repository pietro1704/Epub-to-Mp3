import Foundation

/// Model ABI operations borrow the adapter-owned dylib and preserve owned-string freeing.
struct ConverterModelCatalog {
    var available = false
    var freeString: ConverterStringFree = { _ in }
    var lastError: ConverterLastError = { nil }
    var modelsJSON: ConverterTtsModels = { nil }
    var defaultEngine: ConverterTtsDefaultEngine = { _, _, _ in nil }
    var selectInstalledReady: ConverterTtsInstalledReadyEngine?
    var installArtifact: ConverterTtsModelInstall?
    var removeModel: ConverterTtsModelRemove?
    var modelMetadata: ConverterTtsModelMetadata?
    var installManifest: ConverterTtsModelInstallManifest?
    var installCatalogManifest: ConverterTtsModelInstallCatalogManifest?

    func ttsModels() throws -> Data {
        guard available, let value = modelsJSON() else {
            throw EmbeddedConverterError.artifactUnavailable
        }
        defer { freeString(value) }
        guard let json = String(validatingCString: value) else {
            throw EmbeddedConverterError.artifactUnavailable
        }
        return Data(json.utf8)
    }

    func ttsDefaultEngine(language: String, platform: String, androidAPI: UInt32 = 0) throws -> String {
        guard available else { throw EmbeddedConverterError.artifactUnavailable }
        let result = language.withCString { languagePointer in
            platform.withCString { platformPointer in
                defaultEngine(languagePointer, platformPointer, androidAPI)
            }
        }
        guard let value = result else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        guard let engine = String(validatingCString: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        return engine
    }

    func ttsInstalledReadyEngine(language: String, platform: String, installedModelIDsJSON: String, readyModelIDsJSON: String, androidAPI: UInt32 = 0) throws -> String {
        guard available, let select = selectInstalledReady else { throw EmbeddedConverterError.artifactUnavailable }
        let result = language.withCString { languagePointer in
            platform.withCString { platformPointer in
                installedModelIDsJSON.withCString { installedPointer in
                    readyModelIDsJSON.withCString { readyPointer in
                        select(languagePointer, platformPointer, androidAPI, installedPointer, readyPointer)
                    }
                }
            }
        }
        guard let value = result else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        guard let engine = String(validatingCString: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        return engine
    }

    func installTtsModel(modelID: String, url: String, sha256: String, root: String) throws -> URL {
        guard available, let install = installArtifact else { throw EmbeddedConverterError.artifactUnavailable }
        let result = modelID.withCString { modelPointer in
            url.withCString { urlPointer in
                sha256.withCString { hashPointer in
                    root.withCString { rootPointer in
                        install(modelPointer, urlPointer, hashPointer, rootPointer)
                    }
                }
            }
        }
        guard let value = result else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        guard let path = String(validatingCString: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        return URL(fileURLWithPath: path)
    }

    func installTtsModelManifest(modelID: String, artifactsJSON: String, root: String) throws -> URL {
        guard available, let install = installManifest else { throw EmbeddedConverterError.artifactUnavailable }
        let result = modelID.withCString { modelPointer in
            artifactsJSON.withCString { artifactsPointer in
                root.withCString { rootPointer in
                    install(modelPointer, artifactsPointer, rootPointer)
                }
            }
        }
        guard let value = result else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        guard let path = String(validatingCString: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        return URL(fileURLWithPath: path)
    }

    func installTtsModelFromCatalog(modelID: String, root: String) throws -> URL {
        guard available, let install = installCatalogManifest else { throw EmbeddedConverterError.artifactUnavailable }
        let result = modelID.withCString { modelPointer in
            root.withCString { rootPointer in
                install(modelPointer, rootPointer)
            }
        }
        guard let value = result else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        defer { freeString(value) }
        guard let path = String(validatingCString: value) else {
            throw EmbeddedConverterError.conversionFailed(readError())
        }
        return URL(fileURLWithPath: path)
    }

    func removeTtsModel(modelID: String, root: String) throws {
        guard available, let remove = removeModel else { throw EmbeddedConverterError.artifactUnavailable }
        let removed = modelID.withCString { modelPointer in
            root.withCString { rootPointer in
                remove(modelPointer, rootPointer)
            }
        }
        guard removed else { throw EmbeddedConverterError.conversionFailed(readError()) }
    }

    func ttsModelMetadata(modelID: String, root: String) throws -> Data? {
        guard available, let metadata = modelMetadata else { throw EmbeddedConverterError.artifactUnavailable }
        let result = modelID.withCString { modelPointer in
            root.withCString { rootPointer in metadata(modelPointer, rootPointer) }
        }
        guard let value = result else { return nil }
        defer { freeString(value) }
        guard let json = String(validatingCString: value) else { throw EmbeddedConverterError.conversionFailed(readError()) }
        return Data(json.utf8)
    }

    private func readError() -> String {
        guard let value = lastError() else { return "unknown converter-ffi error" }
        defer { freeString(value) }
        guard let text = String(validatingCString: value) else { return "unknown converter-ffi error" }
        return text
    }
}
