import Foundation

enum LocalAudioStorageUsage {
    typealias Manifest = LocalAudioArtifactStore.Manifest
    typealias StorageUsage = LocalAudioArtifactStore.StorageUsage

    static func storageUsage(root: URL = LocalAudioArtifactStore.defaultRoot()) -> StorageUsage {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return StorageUsage(temporaryBytes: 0, downloadedBytes: 0)
        }
        var temporaryBytes: Int64 = 0
        var downloadedBytes: Int64 = 0
        for directory in directories {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                continue
            }
            for artifact in manifest.chapters where artifact.state == .available {
                let url = directory.appendingPathComponent(artifact.relativePath)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                    .int64Value ?? 0
                if artifact.retention == .downloaded {
                    downloadedBytes += bytes
                } else {
                    temporaryBytes += bytes
                }
            }
        }
        return StorageUsage(temporaryBytes: temporaryBytes, downloadedBytes: downloadedBytes)
    }

}
