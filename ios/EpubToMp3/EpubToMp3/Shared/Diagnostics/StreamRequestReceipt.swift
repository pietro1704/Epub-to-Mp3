import Foundation

extension LatencyObservation {
    /// Identifiers echoed by the response carrying these bytes, not proof of playback.
    struct StreamRequestReceipt: Codable, Equatable, Sendable {
        let journeyID: UUID
        let requestID: UUID
        let publicationID: String

        private enum CodingKeys: String, CodingKey {
            case journeyID = "journeyId"
            case requestID = "requestId"
            case publicationID = "publicationId"
        }

        init?(journeyID: UUID, requestID: UUID, publicationID: String) {
            guard !publicationID.isEmpty, publicationID.utf8.count <= 36 else { return nil }
            let bytes = Array(publicationID.utf8)
            let numeric = (1...20).contains(bytes.count) && bytes.allSatisfy { (48...57).contains($0) }
            let hexadecimal = bytes.count == 32 && bytes.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
            let canonical = bytes.count == 36
                && UUID(uuidString: publicationID)?.uuidString.lowercased() == publicationID.lowercased()
            guard numeric || hexadecimal || canonical else { return nil }
            self.journeyID = journeyID
            self.requestID = requestID
            self.publicationID = publicationID
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let journey = try values.decode(UUID.self, forKey: .journeyID)
            let request = try values.decode(UUID.self, forKey: .requestID)
            let publication = try values.decode(String.self, forKey: .publicationID)
            guard let receipt = Self(journeyID: journey, requestID: request, publicationID: publication) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "Invalid stream request receipt"))
            }
            self = receipt
        }
    }
}
