import Foundation

enum LocalSpeechModelReadiness {
    /// UI installation metadata is separate from Rust's inference/readiness checks.
    static func isSelectionInstalled(_ selection: TtsSelection, modelsRoot: URL? = ttsModelsRoot(), fileManager: FileManager = .default) -> Bool {
        guard let id = selection.modelID, let modelsRoot,
              let catalog = try? ConverterFFIAdapter().ttsCatalog(),
              let model = catalog.models.first(where: { $0.id == id }),
              let expected = model.artifacts, !expected.isEmpty else { return false }
        let directory = modelsRoot.appendingPathComponent(id, isDirectory: true)
        guard let metadata = try? Data(contentsOf: directory.appendingPathComponent("metadata.json")),
              let fields = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              fields["id"] as? String == id,
              let artifacts = fields["artifacts"] as? [[String: String]] else { return false }
        return expected.allSatisfy { artifact in
            artifacts.contains { $0["path"] == artifact.name && $0["sha256"] == artifact.sha256 }
                && fileManager.fileExists(atPath: directory.appendingPathComponent(artifact.name).path)
        }
    }
    static func ttsModelsRoot(fileManager: FileManager = .default, create: Bool = true) -> URL? {
        try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        ).appendingPathComponent("EpubToMp3/TTSModels", isDirectory: true)
    }
    /// Installation UI reports readiness only for a complete catalog installation.
    static func isFaberInstalled(modelsRoot: URL? = ttsModelsRoot(), fileManager: FileManager = .default) -> Bool {
        guard let modelsRoot else { return false }
        let directory = modelsRoot.appendingPathComponent("pt_BR-faber-medium", isDirectory: true)
        guard let metadata = try? Data(contentsOf: directory.appendingPathComponent("metadata.json")),
              let fields = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              fields["id"] as? String == "pt_BR-faber-medium",
              let artifacts = fields["artifacts"] as? [[String: String]] else { return false }
        let expected = [
            "model.onnx": "858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7",
            "model.onnx.json": "7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f",
        ]
        return expected.allSatisfy { name, digest in
            guard artifacts.contains(where: { $0["path"] == name && $0["sha256"] == digest }),
                  let attributes = try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(name).path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let bytes = attributes[.size] as? NSNumber else { return false }
            return bytes.int64Value > 0
        }
    }

}
