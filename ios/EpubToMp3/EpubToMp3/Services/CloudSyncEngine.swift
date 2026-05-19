import Foundation
import CloudKit
import Combine

/// Synchronises the local library (UserDefaults-backed `LibraryStore`)
/// with a private CloudKit database so users see the same books on all
/// their devices. Sync is **metadata-only**: titles, authors, tags,
/// reading position, and small cover thumbnails travel via CKRecord.
/// The actual EPUB files remain local (too large for CloudKit's 1 MB
/// record limit and users typically have them in iCloud Drive anyway).
///
/// Design:
/// - Each `BookEntity` maps to one CKRecord of type "Book" in the
///   user's private database, default zone.
/// - On push: local changes are saved to CloudKit.
/// - On pull: a CKFetchDatabaseChangesOperation + CKFetchRecordZoneChangesOperation
///   fetches server-side changes and merges them into the local store.
/// - Conflict resolution: last-write-wins using `lastOpenedAt`.
///
/// This is a scaffold — full implementation requires iCloud entitlements
/// and a CloudKit container configured in the Xcode project.
final class CloudSyncEngine: ObservableObject {
    static let recordType = "Book"
    static let containerIdentifier = "iCloud.com.epubtomp3.library"

    @Published private(set) var syncStatus: SyncStatus = .idle
    @Published private(set) var lastSyncDate: Date?

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case error(String)
    }

    // Lazy: `CKContainer(identifier:)` traps (SIGILL) when the running
    // bundle is not provisioned with that iCloud container entitlement
    // — e.g. a Debug / unit-test host. Deferring construction to first
    // sync keeps `init` (and reading `syncStatus`) safe everywhere.
    private lazy var container: CKContainer = CKContainer(identifier: Self.containerIdentifier)
    private lazy var database: CKDatabase = container.privateCloudDatabase
    private weak var library: LibraryStore?

    private let changeTokenKey = "cloudSync.changeToken.v1"
    private let defaults: UserDefaults

    init(
        library: LibraryStore,
        defaults: UserDefaults = .standard
    ) {
        self.library = library
        self.defaults = defaults
    }

    // MARK: - Push

    func pushAllBooks() async {
        guard let library else { return }
        syncStatus = .syncing
        do {
            let records = library.books.map { recordFrom(book: $0) }
            _ = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys)
            syncStatus = .idle
            lastSyncDate = Date()
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    func pushBook(_ book: BookEntity) async {
        syncStatus = .syncing
        do {
            let record = recordFrom(book: book)
            try await database.save(record)
            syncStatus = .idle
            lastSyncDate = Date()
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    func deleteBook(id: String) async {
        let recordID = CKRecord.ID(recordName: id)
        do {
            try await database.deleteRecord(withID: recordID)
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Pull

    func fetchChanges() async {
        guard let library else { return }
        syncStatus = .syncing
        do {
            let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
            let (results, _) = try await database.records(matching: query)
            for (_, result) in results {
                switch result {
                case .success(let record):
                    let book = bookFrom(record: record)
                    mergeIntoLibrary(book, library: library)
                case .failure:
                    continue
                }
            }
            syncStatus = .idle
            lastSyncDate = Date()
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Subscriptions

    func setupSubscription() async {
        let subscription = CKDatabaseSubscription(subscriptionID: "library-changes")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            try await database.save(subscription)
        } catch {
            // Subscription may already exist — that's fine.
        }
    }

    // MARK: - Record mapping

    private func recordFrom(book: BookEntity) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType,
                               recordID: CKRecord.ID(recordName: book.id))
        record["title"] = book.title as CKRecordValue
        record["author"] = (book.author ?? "") as CKRecordValue
        record["displayFilename"] = book.displayFilename as CKRecordValue
        record["addedAt"] = book.addedAt as CKRecordValue
        record["lastOpenedAt"] = book.lastOpenedAt as CKRecordValue?
        record["lastChapterIndex"] = (book.lastChapterIndex ?? 0) as CKRecordValue
        record["lastPositionSeconds"] = (book.lastPositionSeconds ?? 0) as CKRecordValue
        record["cachedOffline"] = (book.cachedOffline ? 1 : 0) as CKRecordValue
        record["fileType"] = book.fileType.rawValue as CKRecordValue
        record["tags"] = book.tags as CKRecordValue
        if let cover = book.coverPNG, cover.count < 900_000 {
            record["coverPNG"] = cover as CKRecordValue
        }
        return record
    }

    private func bookFrom(record: CKRecord) -> BookEntity {
        BookEntity(
            id: record.recordID.recordName,
            title: record["title"] as? String ?? "Untitled",
            author: record["author"] as? String,
            bookmark: Data(),
            displayFilename: record["displayFilename"] as? String ?? "",
            addedAt: record["addedAt"] as? Date ?? Date(),
            lastOpenedAt: record["lastOpenedAt"] as? Date,
            lastChapterIndex: record["lastChapterIndex"] as? Int,
            lastPositionSeconds: record["lastPositionSeconds"] as? TimeInterval,
            coverPNG: record["coverPNG"] as? Data,
            lastJobId: nil,
            cachedOffline: (record["cachedOffline"] as? Int ?? 0) == 1,
            fileType: BookFileType(rawValue: record["fileType"] as? String ?? "epub") ?? .epub,
            tags: record["tags"] as? [String] ?? []
        )
    }

    private func mergeIntoLibrary(_ remote: BookEntity, library: LibraryStore) {
        if let existing = library.books.first(where: { $0.id == remote.id }) {
            let remoteDate = remote.lastOpenedAt ?? remote.addedAt
            let localDate = existing.lastOpenedAt ?? existing.addedAt
            if remoteDate > localDate {
                var merged = existing
                merged.lastOpenedAt = remote.lastOpenedAt
                merged.lastChapterIndex = remote.lastChapterIndex
                merged.lastPositionSeconds = remote.lastPositionSeconds
                merged.tags = Array(Set(existing.tags + remote.tags))
                if merged.coverPNG == nil { merged.coverPNG = remote.coverPNG }
                library.update(merged)
            }
        }
        // Don't auto-add books that only exist remotely — the user
        // needs the local EPUB file to read them. The remote record
        // serves as a "ghost" placeholder that will activate once the
        // user imports the same EPUB on this device.
    }
}
