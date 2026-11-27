import XCTest
@testable import EpubToMp3

@MainActor
final class ConversionEventDeliveryTests: XCTestCase {
    /// APPLE-CONVERSION-LATE-CHAPTER-EVENT: `convert()` returned before the last chapter event.
    func testDrainWaitsForEverySlowEventAndKeepsTheirOrder() async {
        let delivery = ConversionEventDelivery()
        let log = DeliveredEvents()
        await Task.detached {
            for index in 0..<3 {
                delivery.post {
                    // Earlier events take longer, as a slow recovery write would.
                    try? await Task.sleep(nanoseconds: UInt64(3 - index) * 20_000_000)
                    log.indices.append(index)
                }
            }
        }.value

        await delivery.drain()

        XCTAssertEqual(log.indices, [0, 1, 2])
    }
}

@MainActor
private final class DeliveredEvents {
    var indices: [Int] = []
}
