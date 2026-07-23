import Foundation

/// Pure-logic store for "where did I leave off" markers, keyed by
/// `(jobId, chapterIndex)`. Backed by `UserDefaults` so it survives
/// relaunches without dragging in CoreData/SwiftData for what is
/// fundamentally a tiny dictionary.
///
/// This type intentionally has no AVFoundation / SwiftUI imports — that
/// keeps it covered by the headless `swift build` + XCTest suite.
struct ResumeMarker: Codable, Equatable {
    let jobId: String
    let chapterIndex: Int
    let positionSeconds: Double
    let wasPlaying: Bool
    let updatedAt: Date

    init(jobId: String, chapterIndex: Int, positionSeconds: Double, wasPlaying: Bool = false, updatedAt: Date) {
        self.jobId = jobId
        self.chapterIndex = chapterIndex
        self.positionSeconds = positionSeconds
        self.wasPlaying = wasPlaying
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case jobId, chapterIndex, positionSeconds, wasPlaying, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jobId = try c.decode(String.self, forKey: .jobId)
        self.chapterIndex = try c.decode(Int.self, forKey: .chapterIndex)
        self.positionSeconds = try c.decode(Double.self, forKey: .positionSeconds)
        self.wasPlaying = try c.decodeIfPresent(Bool.self, forKey: .wasPlaying) ?? false
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

protocol ResumeStorage: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Data?, forKey key: String)
}

extension UserDefaults: ResumeStorage {
    func set(_ value: Data?, forKey key: String) {
        if let value { set(value as Any, forKey: key) } else { removeObject(forKey: key) }
    }
}

final class ResumeStore {
    private static let storageKey = "audioPlayer.resumeMarkers.v1"

    private let storage: ResumeStorage
    private var cache: [String: ResumeMarker]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: ResumeStorage = UserDefaults.standard) {
        self.storage = storage
        if let data = storage.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: ResumeMarker].self, from: data) {
            self.cache = decoded
        } else {
            self.cache = [:]
        }
    }

    static func key(jobId: String, chapterIndex: Int) -> String {
        "\(jobId)#\(chapterIndex)"
    }

    func latestMarker(jobId: String) -> ResumeMarker? {
        cache.values
            .filter { $0.jobId == jobId }
            .max { $0.updatedAt < $1.updatedAt }
    }

    func marker(jobId: String, chapterIndex: Int) -> ResumeMarker? {
        cache[Self.key(jobId: jobId, chapterIndex: chapterIndex)]
    }

    func save(
        jobId: String,
        chapterIndex: Int,
        position: TimeInterval,
        wasPlaying: Bool = false,
        now: Date = Date()
    ) {
        let marker = ResumeMarker(
            jobId: jobId,
            chapterIndex: chapterIndex,
            positionSeconds: max(0, position),
            wasPlaying: wasPlaying,
            updatedAt: now
        )
        cache[Self.key(jobId: jobId, chapterIndex: chapterIndex)] = marker
        flush()
    }

    func clear(jobId: String) {
        let prefix = "\(jobId)#"
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        flush()
    }

    func clearAll() {
        cache.removeAll()
        flush()
    }

    private func flush() {
        let data = try? encoder.encode(cache)
        storage.set(data, forKey: Self.storageKey)
    }
}
