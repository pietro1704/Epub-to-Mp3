import Foundation
import XCTest

final class BackgroundAudioConfigurationTests: XCTestCase {
    func testApplicationDeclaresAudioAsAnArrayOfBackgroundModes() throws {
#if os(iOS)
        let metadata = try XCTUnwrap(Bundle.main.infoDictionary)
#else
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let plist = project.appendingPathComponent("EpubToMp3/Resources/Info.plist")
        let metadata = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
                as? [String: Any]
        )
#endif
        let modes = try XCTUnwrap(
            metadata["UIBackgroundModes"] as? [String],
            "Background audio requires UIBackgroundModes in application metadata, not a scalar build setting."
        )
        XCTAssertTrue(modes.contains("audio"))
    }
}
