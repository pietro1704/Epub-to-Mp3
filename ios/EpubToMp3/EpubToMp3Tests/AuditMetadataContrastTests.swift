#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class AuditMetadataContrastTests: XCTestCase {
    func testPlayerChapterAndVoiceMeetTextContrastInBothAppearances() throws {
        let suite = "audit-playback-contrast-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let controller = FullPlayerScreenController(player: player, playbackClock: PlaybackClock(),
            library: LibraryStore(defaults: defaults), playerPresentation: PlayerPresentation(defaults: defaults),
            settings: AppSettings(defaults: defaults), onStartListening: {})
        controller.loadViewIfNeeded()
        let label = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UILabel }
            .first { $0.accessibilityIdentifier == "fullPlayer.chapterAndVoice" })
        for appearance: UIUserInterfaceStyle in [.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: appearance)
            for background in [UIColor.systemBackground, .secondarySystemBackground] {
                XCTAssertGreaterThanOrEqual(contrast(label.textColor, background, traits: traits), 4.5)
            }
        }
    }

    private func contrast(_ foreground: UIColor, _ background: UIColor, traits: UITraitCollection) -> Double {
        func components(_ color: UIColor) -> [Double] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return [Double(r), Double(g), Double(b), Double(a)]
        }
        let bg = components(background), fg = components(foreground)
        let blended = (0..<3).map { fg[$0] * fg[3] + bg[$0] * (1 - fg[3]) }
        func luminance(_ rgb: [Double]) -> Double {
            let values = rgb.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return zip(values, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let a = luminance(blended), b = luminance(bg)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
#endif
