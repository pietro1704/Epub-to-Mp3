import Foundation

final class RustConversionWorkQueues: @unchecked Sendable {
    enum Purpose {
        case listening
        case manual
    }

    static let shared = RustConversionWorkQueues()
    private let listening = DispatchQueue(label: "com.pietrocode.epubtomp3.rust-listening", qos: .userInitiated)
    private let manual = DispatchQueue(label: "com.pietrocode.epubtomp3.rust-manual", qos: .userInitiated)

    func enqueue(for purpose: Purpose, operation: @escaping @Sendable () -> Void) {
        // A playback-window wait must not occupy the manual conversion lane.
        let queue = purpose == .listening ? listening : manual
        queue.async(execute: operation)
    }
}
