import CryptoKit
import Foundation
import PDFKit

/// Persists only the derived visual document under its source/schema identity.
enum PdfNormalizedDocumentCache {
    private static let cacheSchemaVersion = "3"

    /// Scanned books can have hundreds of physical pages. Persist the visual
    /// derivative so a warm open loads the already upright logical pages
    /// without repeating Vision sampling and rasterization.
    static func document(for sourceURL: URL) -> PDFDocument? {
        guard let cacheURL = cacheURL(for: sourceURL),
              let document = PDFDocument(url: cacheURL),
              document.pageCount > 0
        else {
            return nil
        }
        return document
    }

    static func store(_ document: PDFDocument, for sourceURL: URL) {
        guard let cacheURL = cacheURL(for: sourceURL) else { return }
        let directory = cacheURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let temporaryURL = directory.appendingPathComponent(
                "\(cacheURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).tmp"
            )
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard document.write(to: temporaryURL) else { return }
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    cacheURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: cacheURL)
            }
        } catch {
            // Cache persistence is an optimization. The normalized in-memory
            // document remains valid when a storage provider rejects a write.
        }
    }

    private static func cacheURL(for sourceURL: URL) -> URL? {
        let values = try? sourceURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        let sourceIdentity = [
            sourceURL.standardizedFileURL.path,
            cacheSchemaVersion,
            values?.fileSize.map(String.init) ?? "unknown-size",
            values?.contentModificationDate?.timeIntervalSince1970.description ?? "unknown-date",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(sourceIdentity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return caches
            .appendingPathComponent("EpubToMp3", isDirectory: true)
            .appendingPathComponent("NormalizedPDF", isDirectory: true)
            .appendingPathComponent("\(digest).pdf", isDirectory: false)
    }
}
