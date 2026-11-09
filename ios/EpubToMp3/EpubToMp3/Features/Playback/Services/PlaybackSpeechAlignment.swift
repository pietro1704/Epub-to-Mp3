import AVFoundation

/// Reads only the bounded leading metadata off the main actor. Replacing the
/// current item invalidates a pending read before its result can be exposed.
@MainActor
final class PlaybackSpeechAlignment {
    private weak var loadedItem: AVPlayerItem?
    private var requestID = UUID()
    private var task: Task<Void, Never>?
    private var alignment: SpeechAudioAlignment?

    func current(_ item: AVPlayerItem?) -> SpeechAudioAlignment? {
        guard let item else {
            task?.cancel(); task = nil
            loadedItem = nil; alignment = nil; requestID = UUID()
            return nil
        }
        guard loadedItem !== item else { return alignment }
        task?.cancel()
        loadedItem = item
        requestID = UUID()
        let request = requestID
        alignment = nil
        guard let url = (item.asset as? AVURLAsset)?.url, url.isFileURL else { return nil }
        task = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { SpeechAudioAlignment.read(from: url) }.value
            guard !Task.isCancelled, let self, self.requestID == request, self.loadedItem === item else { return }
            self.alignment = loaded
        }
        return nil
    }
}
