import Foundation

@MainActor
struct LocalConversionQueueStore {
    typealias ResumeRequest = LocalAudioConversionScheduler.ResumeRequest
    let persistence: UserDefaults?

    private static let persistenceKey = "localAudioConversionScheduler.queue.v1"
    private static let persistenceSchemaVersion = 1

    private struct PersistedQueue: Codable {
        let schemaVersion: Int
        let requests: [ResumeRequest]
    }

    func save(_ requests: [ResumeRequest]) {
        guard let persistence else { return }
        guard requests.isEmpty == false else {
            persistence.removeObject(forKey: Self.persistenceKey)
            return
        }
        let payload = PersistedQueue(
            schemaVersion: Self.persistenceSchemaVersion,
            requests: requests
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        persistence.set(data, forKey: Self.persistenceKey)
    }

    func load() -> [ResumeRequest] {
        guard let persistence,
              let data = persistence.data(forKey: Self.persistenceKey),
              let payload = try? JSONDecoder().decode(PersistedQueue.self, from: data),
              payload.schemaVersion == Self.persistenceSchemaVersion else {
            return []
        }
        return payload.requests
    }

}
