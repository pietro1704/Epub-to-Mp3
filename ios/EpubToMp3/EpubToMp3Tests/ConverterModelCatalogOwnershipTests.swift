import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

/// Uses real allocated C strings and the production ABI function-pointer types.
/// One scenario loop owns this fixture, so no production singleton is replaced.
final class ConverterModelCatalogOwnershipTests: XCTestCase {
    private final class Allocations: @unchecked Sendable {
        static let shared = Allocations()
        private let lock = NSLock()
        private var bytes: [UInt8]? = []
        private var live: [UInt: UnsafeMutablePointer<CChar>] = [:]
        private(set) var freed: [UInt] = []

        func reset(bytes: [UInt8]?) {
            lock.lock()
            defer { lock.unlock() }
            // Also reclaim leaked fixture strings after a failing regression.
            for pointer in live.values { pointer.deallocate() }
            live.removeAll()
            freed.removeAll()
            self.bytes = bytes
        }

        func result(bytes override: [UInt8]? = nil) -> UnsafeMutablePointer<CChar>? {
            lock.lock()
            defer { lock.unlock() }
            guard let bytes = override ?? bytes else { return nil }
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
            for (offset, byte) in bytes.enumerated() { pointer[offset] = CChar(bitPattern: byte) }
            pointer[bytes.count] = 0
            live[UInt(bitPattern: pointer)] = pointer
            return pointer
        }

        func release(_ pointer: UnsafeMutablePointer<CChar>?) {
            lock.lock()
            defer { lock.unlock() }
            guard let pointer else { return }
            let identity = UInt(bitPattern: pointer)
            freed.append(identity)
            guard let owned = live.removeValue(forKey: identity) else {
                XCTFail("Freed an unrelated pointer or released one allocation twice")
                return
            }
            owned.deallocate()
        }

        var liveCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return live.count
        }
    }

    func testEveryModelResultIsFreedForValidInvalidAndMissingUTF8() throws {
        let allocations = Allocations.shared
        defer { allocations.reset(bytes: nil) }
        let catalog = ConverterModelCatalog(
            available: true,
            freeString: { Allocations.shared.release($0) },
            lastError: { Allocations.shared.result() },
            modelsJSON: { Allocations.shared.result() },
            defaultEngine: { _, _, _ in Allocations.shared.result() },
            selectInstalledReady: { _, _, _, _, _ in Allocations.shared.result() },
            installArtifact: { _, _, _, _ in Allocations.shared.result() },
            removeModel: { _, _ in false },
            modelMetadata: { _, _ in Allocations.shared.result() },
            installManifest: { _, _, _ in Allocations.shared.result() },
            installCatalogManifest: { _, _ in Allocations.shared.result() }
        )
        let operations: [(String, () throws -> Void)] = [
            ("models", { _ = try catalog.ttsModels() }),
            ("default engine", { _ = try catalog.ttsDefaultEngine(language: "pt-BR", platform: "apple") }),
            ("installed engine", { _ = try catalog.ttsInstalledReadyEngine(language: "pt-BR", platform: "apple", installedModelIDsJSON: "[]", readyModelIDsJSON: "[]") }),
            ("artifact", { _ = try catalog.installTtsModel(modelID: "fixture", url: "fixture", sha256: "fixture", root: "/fixture") }),
            ("manifest", { _ = try catalog.installTtsModelManifest(modelID: "fixture", artifactsJSON: "[]", root: "/fixture") }),
            ("catalog manifest", { _ = try catalog.installTtsModelFromCatalog(modelID: "fixture", root: "/fixture") }),
            ("metadata", { _ = try catalog.ttsModelMetadata(modelID: "fixture", root: "/fixture") })
        ]
        for (name, operation) in operations {
            allocations.reset(bytes: Array("fixture".utf8))
            XCTAssertNoThrow(try operation(), name)
            XCTAssertEqual(allocations.freed.count, 1, name)
            XCTAssertEqual(allocations.liveCount, 0, name)

            allocations.reset(bytes: [0xFF, 0xFE])
            XCTAssertThrowsError(try operation(), name)
            XCTAssertEqual(allocations.liveCount, 0, "Malformed UTF-8 leaked: \(name)")
            XCTAssertFalse(allocations.freed.isEmpty, name)

            allocations.reset(bytes: nil)
            if name == "metadata" {
                XCTAssertNil(try catalog.ttsModelMetadata(modelID: "fixture", root: "/fixture"))
            } else {
                XCTAssertThrowsError(try operation(), name)
            }
            XCTAssertTrue(allocations.freed.isEmpty, "Missing pointer was freed: \(name)")
        }
        allocations.reset(bytes: [0xFF])
        var distinctError = catalog
        distinctError.lastError = { Allocations.shared.result(bytes: Array("sentinel catalog failure".utf8)) }
        XCTAssertThrowsError(try distinctError.ttsDefaultEngine(language: "pt-BR", platform: "apple")) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .conversionFailed("sentinel catalog failure"))
        }
        XCTAssertEqual(allocations.liveCount, 0)
        XCTAssertEqual(allocations.freed.count, 2)

        allocations.reset(bytes: [0xFF])
        XCTAssertThrowsError(try catalog.removeTtsModel(modelID: "fixture", root: "/fixture")) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .conversionFailed("unknown converter-ffi error"))
        }
        XCTAssertEqual(allocations.liveCount, 0, "Malformed last_error leaked")
        XCTAssertEqual(allocations.freed.count, 1)
    }

    func testRuntimeProbeUsesItsOwnABIAndFreesReturnedSnapshot() throws {
        let allocations = Allocations.shared
        defer { allocations.reset(bytes: nil) }
        let target = SpeechModelLibraryTarget.current()
        let catalog = ConverterModelCatalog(
            available: true,
            freeString: { Allocations.shared.release($0) },
            catalogJSONV3: { _, _, _, _, _, _ in
                XCTFail("Explicit runtime probing must not fall back to read-only inspection")
                return nil
            },
            catalogProbeJSONV3: { _, _, _, _, _, _, _ in Allocations.shared.result() }
        )
        let snapshot = Data("""
        {"schema_version":3,"generated_from_catalog_revision":"fixture","entries":[],
         "default_selection":{"version":2,"provider":"piper","runtime":"piper",
         "model_id":"pt_BR-faber-medium","model_revision":"fixture","voice":null,"options":{}}}
        """.utf8)
        allocations.reset(bytes: Array(snapshot))
        XCTAssertEqual(try catalog.speechModelSnapshot(target: target, probeRuntime: true).schemaVersion, 3)
        XCTAssertEqual(allocations.liveCount, 0)
        XCTAssertEqual(allocations.freed.count, 1)

        allocations.reset(bytes: [0xFF])
        XCTAssertThrowsError(try catalog.speechModelSnapshot(target: target, probeRuntime: true))
        XCTAssertEqual(allocations.liveCount, 0)
        XCTAssertEqual(allocations.freed.count, 1)

        allocations.reset(bytes: nil)
        var unavailable = catalog
        unavailable.catalogProbeJSONV3 = nil
        XCTAssertThrowsError(try unavailable.speechModelSnapshot(target: target, probeRuntime: true)) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
        XCTAssertTrue(allocations.freed.isEmpty)
    }
}
