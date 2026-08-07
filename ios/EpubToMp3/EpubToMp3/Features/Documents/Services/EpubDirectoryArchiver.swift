import Foundation
import zlib

/// Converts an expanded EPUB package directory into a standard `.epub` ZIP
/// archive. Apple Books can expose imported books in this expanded form even
/// though Finder presents the directory with an `.epub` suffix.
enum EpubDirectoryArchiver {
    enum ArchiveError: LocalizedError {
        case invalidPackage(URL)
        case archiveTooLarge(URL)

        var errorDescription: String? {
            switch self {
            case let .invalidPackage(url):
                return "\(url.lastPathComponent) is not a valid expanded EPUB package."
            case let .archiveTooLarge(url):
                return "\(url.lastPathComponent) is too large to package as an EPUB."
            }
        }
    }

    struct MaterializedArchive {
        let url: URL
        let isTemporary: Bool
    }

    /// Returns the original file unchanged, or creates a temporary EPUB ZIP
    /// when the input is a valid `.epub` directory.
    static func materializeIfNeeded(
        at source: URL,
        fileManager: FileManager = .default
    ) throws -> MaterializedArchive {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            return .init(url: source, isTemporary: false)
        }
        guard isDirectory.boolValue else {
            return .init(url: source, isTemporary: false)
        }
        guard source.pathExtension.caseInsensitiveCompare("epub") == .orderedSame,
              isValidPackage(at: source, fileManager: fileManager) else {
            throw ArchiveError.invalidPackage(source)
        }

        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("epub")
        try archive(packageDirectory: source, to: temporaryURL, fileManager: fileManager)
        return .init(url: temporaryURL, isTemporary: true)
    }

    static func isValidPackage(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard url.pathExtension.caseInsensitiveCompare("epub") == .orderedSame else {
            return false
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        let mimetype = url.appendingPathComponent("mimetype")
        let container = url.appendingPathComponent("META-INF/container.xml")
        guard fileManager.isReadableFile(atPath: mimetype.path),
              fileManager.isReadableFile(atPath: container.path),
              (try? String(contentsOf: mimetype, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)) == "application/epub+zip",
              let containerXML = try? String(contentsOf: container, encoding: .utf8),
              let match = try? NSRegularExpression(
                pattern: #"full-path\s*=\s*[\"']([^\"']+\.opf)[\"']"#
              ).firstMatch(
                in: containerXML,
                range: NSRange(containerXML.startIndex..., in: containerXML)
              ),
              let range = Range(match.range(at: 1), in: containerXML) else {
            return false
        }
        guard let opf = validatedPackageMember(
            String(containerXML[range]),
            packageDirectory: url
        ) else {
            return false
        }
        return fileManager.isReadableFile(atPath: opf.path)
    }

    private static func validatedPackageMember(_ relativePath: String, packageDirectory: URL) -> URL? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"),
              !components.contains(".."),
              !components.contains(where: { $0.isEmpty || $0 == "." }) else {
            return nil
        }
        return components.reduce(packageDirectory) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }
    }

    private static func archive(
        packageDirectory: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: packageDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            throw ArchiveError.invalidPackage(packageDirectory)
        }

        var members: [Member] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let relative = url.path.replacingOccurrences(of: packageDirectory.path + "/", with: "")
            guard !relative.isEmpty else { continue }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            members.append(try Member(
                name: relative,
                data: data,
                method: relative == "mimetype" ? .stored : .deflated
            ))
        }
        members.sort { $0.name < $1.name }
        guard let mimetypeIndex = members.firstIndex(where: { $0.name == "mimetype" }) else {
            throw ArchiveError.invalidPackage(packageDirectory)
        }
        let mimetype = members.remove(at: mimetypeIndex)
        members.insert(mimetype, at: 0)

        let archive = try ZipArchive(members: members).encoded()
        try archive.write(to: destination, options: .atomic)
    }

    private enum CompressionMethod: UInt16 {
        case stored = 0
        case deflated = 8
    }

    private struct Member {
        let name: String
        let data: Data
        let method: CompressionMethod
        let payload: Data
        let crc32: UInt32

        init(name: String, data: Data, method: CompressionMethod) throws {
            guard name.utf8.count <= Int(UInt16.max),
                  data.count <= Int(UInt32.max) else {
                throw ArchiveError.archiveTooLarge(URL(fileURLWithPath: name))
            }
            self.name = name
            self.data = data
            self.method = method
            self.payload = method == .stored ? data : Self.deflate(data)
            self.crc32 = Self.crc32(data)
        }

        private static func deflate(_ source: Data) -> Data {
            guard !source.isEmpty else { return Data() }
            let capacity = max(source.count + source.count / 100 + 128, 128)
            var destination = Data(count: capacity)
            var produced = 0
            source.withUnsafeBytes { sourceBytes in
                destination.withUnsafeMutableBytes { destinationBytes in
                    guard let sourceAddress = sourceBytes.baseAddress,
                          let destinationAddress = destinationBytes.baseAddress else { return }
                    var stream = z_stream()
                    stream.next_in = UnsafeMutablePointer(mutating: sourceAddress.assumingMemoryBound(to: Bytef.self))
                    stream.avail_in = uInt(source.count)
                    stream.next_out = destinationAddress.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(capacity)
                    guard deflateInit2_(&stream, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                                        ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return }
                    _ = zlib.deflate(&stream, Z_FINISH)
                    produced = Int(stream.total_out)
                    deflateEnd(&stream)
                }
            }
            return destination.prefix(produced)
        }

        private static func crc32(_ data: Data) -> UInt32 {
            data.withUnsafeBytes { raw in
                UInt32(zlib.crc32(0, raw.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(data.count)))
            }
        }
    }

    private struct ZipArchive {
        let members: [Member]

        func encoded() throws -> Data {
            guard members.count <= Int(UInt16.max) else {
                throw ArchiveError.archiveTooLarge(URL(fileURLWithPath: "EPUB package"))
            }
            var archive = Data()
            var offsets: [UInt32] = []
            for member in members {
                guard archive.count <= Int(UInt32.max), member.payload.count <= Int(UInt32.max) else {
                    throw ArchiveError.archiveTooLarge(URL(fileURLWithPath: member.name))
                }
                offsets.append(UInt32(archive.count))
                archive.appendZipUInt32(0x04034b50)
                archive.appendZipUInt16(20)
                archive.appendZipUInt16(0)
                archive.appendZipUInt16(member.method.rawValue)
                archive.appendZipUInt16(0)
                archive.appendZipUInt16(0)
                archive.appendZipUInt32(member.crc32)
                archive.appendZipUInt32(UInt32(member.payload.count))
                archive.appendZipUInt32(UInt32(member.data.count))
                let name = Data(member.name.utf8)
                archive.appendZipUInt16(UInt16(name.count))
                archive.appendZipUInt16(0)
                archive.append(name)
                archive.append(member.payload)
            }

            let centralDirectoryOffset = archive.count
            for (index, member) in members.enumerated() {
                archive.appendZipUInt32(0x02014b50)
                archive.appendZipUInt16(20)
                archive.appendZipUInt16(20)
                archive.appendZipUInt16(0)
                archive.appendZipUInt16(member.method.rawValue)
                archive.appendZipUInt16(0)
                archive.appendZipUInt16(0)
                archive.appendZipUInt32(member.crc32)
                archive.appendZipUInt32(UInt32(member.payload.count))
                archive.appendZipUInt32(UInt32(member.data.count))
                let name = Data(member.name.utf8)
                archive.appendZipUInt16(UInt16(name.count))
                archive.appendZipUInt16(0)
                archive.appendZipUInt16(0)
                archive.appendZipUInt16(0)
                archive.appendZipUInt16(0)
                archive.appendZipUInt32(0)
                archive.appendZipUInt32(offsets[index])
                archive.append(name)
            }
            let centralDirectorySize = archive.count - centralDirectoryOffset
            guard archive.count <= Int(UInt32.max), centralDirectorySize <= Int(UInt32.max) else {
                throw ArchiveError.archiveTooLarge(URL(fileURLWithPath: "EPUB package"))
            }
            archive.appendZipUInt32(0x06054b50)
            archive.appendZipUInt16(0)
            archive.appendZipUInt16(0)
            archive.appendZipUInt16(UInt16(members.count))
            archive.appendZipUInt16(UInt16(members.count))
            archive.appendZipUInt32(UInt32(centralDirectorySize))
            archive.appendZipUInt32(UInt32(centralDirectoryOffset))
            archive.appendZipUInt16(0)
            return archive
        }
    }
}

private extension Data {
    mutating func appendZipUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendZipUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
