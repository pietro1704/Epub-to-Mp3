import Foundation
import CryptoKit

/// Stable book identity shared by library imports and conversion output ownership.
enum BookContentIdentity {
    static func hash(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.alwaysMapped])
        var hasher = SHA256()
        hasher.update(data: data)
        let digest = hasher.finalize()
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}
