import Foundation
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

/// Real MP3 fixture shared with Rust audio tests, embedded so the exact bytes
/// also run in device XCTest without a checkout or test-bundle resource lookup.
/// Source: tests/fixtures/audio/mono-24000-48k.mp3
/// SHA256: 761cca6a58252d9cd9338d853a6d43a8bbd35ede45462b12d77d67fd7188d10e
struct LegacyAudioImportFixture {
    let root: URL
    var legacyRoot: URL { root.appendingPathComponent("Audiobooks") }
    var storeRoot: URL { root.appendingPathComponent("LocalAudioArtifacts") }

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("legacy-audio-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func source(job: String = "job", chapter: Int = 1) -> URL {
        legacyRoot.appendingPathComponent(job).appendingPathComponent("chapters/chapter-\(chapter).mp3")
    }

    func sourceManifest(job: String = "job") -> URL {
        legacyRoot.appendingPathComponent(job).appendingPathComponent("manifest.json")
    }

    func destination(book: String = "book", chapter: Int = 0) -> URL {
        storeRoot.appendingPathComponent(book).appendingPathComponent("chapters/chapter-\(chapter).mp3")
    }

    func destinationManifest(book: String = "book") -> URL {
        storeRoot.appendingPathComponent(book).appendingPathComponent("manifest.json")
    }

    func writeSource(job: String = "job", chapters: [Int] = [1], bytes: Data = Self.audio) throws {
        let directory = legacyRoot.appendingPathComponent(job).appendingPathComponent("chapters")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for chapter in chapters { try bytes.write(to: source(job: job, chapter: chapter)) }
        let manifest = AudiobookManifest(
            jobId: job, bookTitle: "Legacy title",
            chapters: chapters.map { chapter in
                .init(index: chapter, title: "Chapter \(chapter)", mp3FileName: "chapter-\(chapter).mp3",
                      mp3Bytes: Int64(bytes.count), downloadedAt: Date(timeIntervalSince1970: 100))
            }, totalBytes: Int64(bytes.count * chapters.count), completedAt: nil)
        try JSONEncoder().encode(manifest).write(to: sourceManifest(job: job))
    }

    func identity(book: String = "book", job: String = "job", mapping: [Int: Int] = [1: 0])
        -> LocalAudioArtifactStore.LegacyImportIdentity {
        .init(bookID: book, bookTitle: "Library title", author: "Author", jobID: job, canonicalIndices: mapping)
    }

    /// PCM WAVE with an explicit RIFF/data length. The malformed container is
    /// an admission failure fixture; it does not prove decodability of a prefix.
    static func wave(declaredFrames: Int = 16_384, storedFrames: Int = 16_384) -> Data {
        var bytes = Data("RIFF".utf8)
        func append16(_ number: UInt16) {
            var littleEndian = number.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
        }
        func append32(_ number: UInt32) {
            var littleEndian = number.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
        }
        append32(UInt32(36 + declaredFrames * 2))
        bytes.append(Data("WAVEfmt ".utf8))
        append32(16)
        append16(1) // PCM
        append16(1) // Mono
        append32(16_000)
        append32(32_000)
        append16(2)
        append16(16)
        bytes.append(Data("data".utf8))
        append32(UInt32(declaredFrames * 2))
        bytes.append(Data(repeating: 0, count: storedFrames * 2))
        return bytes
    }

    static let audio = Data(base64Encoded: """
        //NkxAAccI5oF1kYADqSbhcsuWWzLLmCCAg0r03DKQOek66TnlOF02UzNFLXrrd9yH8fx2H8fyMSywLDgYGBgYtw8CAIAg6X
        P8EHQxy/hjgN+kMcBv0hjl38MdPu6ZcHw+CAIAgCADB8HwfD4IAhpb3dP8oAwfB8H4ABAENYfYAYOiEYiitMswuMLMi22PWk
        //NkxBEfcgJYA52YADDAxFT4keDEFEj3pETPUlDE0RCILXzKwXeQDBUDk0DZFJ24WTA2yBsCD9f8MshgEY4SkILf+OSLlFak
        OHOGW//JkipASkRYixj//l0mTIvF4xLpdS///LxeMS6XVF5IShL/8Girmf///rsXPFUKgASGym5gEAB2YBQALmAdAE5gYoPQ
        //NkxBYhCnYQAd8QAGDmCgRgdwRiYM2FqG/Apqxk5AWWYOKDoGB+gdhghoEcYBUAomATAE5gFAAWAQA4IAAlnS3n/rnr9P++
        lK/90Xv2Xr9r99Gsm/+n9lpvlde8f/un3lhkoQlKUbL6jsaN31dLWsSxrWz++qur0spIqhZiEdeGGHpCAEAFMASAIjASwJcw
        //NkxBQbuuoYUv7EaIxDZzApgAkwJcI5NR6aXTC8wS845aMxIzEAoBAZeBItnb8T+Ddl6U69rXvo1m/+/ftf/f76NZHSlPre
        3rSnT7Sdv0+tIXv9+3/7x9DbGW9Y1V66qqeQ2t3b45WQMHQUAQAmYA4AIGAkgG5gYwGQYpsH6GDwgZQqK3Gwj+OBhtgXcaTg
        //NkxCgj1CoEAP8KaeYoQRgkkgAUAUJgACIoKTey11ZU3r0/ur9ljP7RRTavqyVpekUrqS6MrXRln+a1rIw2jDO7PadRHRr6
        OjJ0jYDWpeyvc7eI83IolZXUctaMekZ97RyslHWlL9e1r6NpyVlvaOv3GMcVH6VhGl0medfg0ABiQBgBgLswtcBAMEUAkzAm
        //NkxBsdSu4YVP7EaIMFMEDhJzAOgZkxWKMEPwaPCILSmZHA75T3H1zpWnL37q+rLen9Y2vWnf572tdKsrrW327p129f5u/p
        tpPSA3t2Xr9P+NvdWuvyCGMaxrrLnPujEqSiIW0kCCoRIdfptVfCQACYA2ACGAxAKZhigU+YKKBnGCXhqxnlkdAYSWDgHDT5
        //NkxCgaqnYUKP7EaJylGME5gocXNbtCXWiuT606ff/Xr1/7o2ra7JL9LfpWtaU+9/12Xp9Y3f0r/WKQnbbv45u6tUp0pQxn
        Zdf3Lr9KKUUBgSHGoy7TDUTjAQEzDEdDfPIjNooTBHAis0mFa7MK8BHTl2Az4rMbEDBgFFKBZqHZdx9Xooobaz7n3LXVr02S
        //NkxEAXqFocUu/2QEm3OOdWtdPL+xuxh3/X0J0ffvvGKUtS6dOi1rPuvGo/RxmJPCvoYAELhAYIE2ajeuZTkoYJqDAGtFHf
        RhrIF8dsfmljBkQKDhpCFv4DiVKb0W7+N3q6aaKW+zerGL6/a3bz39aS1Gj2ec3VLo6EsYhlrLrv0+jSShaRYcqglsC2yAQd
        //NkxGQWMFYcKu/2QJxgCsMBDEGDAVAHUwSgCDNgrC/TDkAC88EMAU6GIw0MoxrUdCS1tvj9dHQ2Ra33uuvryqLZFpAhZnnv
        rXq6Pp7jvu/0aPv9SrlITT9tlvufHxI/zSHAwBQAOFQAkwB8CVMFFBgzBJxDEwncPJMX6FHjYKjdUx4sVBMK5BDTAcwA0wG4
        //NkxI4W+FocUs/2JAoDAagBwSABAMADpDvo1iTPr9f7G/c76tOimxvu66qeX+zvPf6/Ts7P3er/9nvx6oI0Gw4JQ4EwhAIA
        5heG5h4L5g4HT7VzGAvzntyjKlGDLJOV5OEYoA8YIgaZ9DmVA0i8cDATRRQjOz0KLG+RKr+JqirSTUaQYbBumEiYBC/97U0k
        //NkxLUYgFocIV8QAglZBrrkhIYqDBwcaMic//9rbX+sHgCBC7oqAiUFwC/QoD///+/ks3FJufjbvLRbxW1tWBTv////38Ld
        SxSc7x2ou+0nfXOGZRDP/////+fc//8Pw//vU2qavWzpd0tyr/5fRpUFAqFQmEgkOf/0NPpu3rWNGKAw8qVARZVMQU1FNC4w
        //NkxNYzkkZhG53IAFVVVVVVVVVMQU1FNC4wVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
        VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
        //NkxHwAAANIAcAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
        VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
        """, options: .ignoreUnknownCharacters)!
}
