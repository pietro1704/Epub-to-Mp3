import Foundation

/// The presentation facts shared by reader navigation and bottom chrome.
/// Layout owners derive their constraints and visibility from this value
/// instead of maintaining independent immersive/loading flags.
struct ReaderPresentationState: Equatable {
    var isReaderActive: Bool = false
    var isLoading: Bool = false
    var isChromeHidden: Bool = false

    var hidesBottomChrome: Bool {
        isReaderActive && (isLoading || isChromeHidden)
    }

    var showsReaderNavigation: Bool {
        isReaderActive && !isChromeHidden
    }

    func showsMiniPlayer(bookHasPlayback: Bool) -> Bool {
        bookHasPlayback && isReaderActive && !isLoading && !isChromeHidden
    }

    mutating func resetForInactiveReader() {
        isReaderActive = false
        isLoading = false
        isChromeHidden = false
    }
}
