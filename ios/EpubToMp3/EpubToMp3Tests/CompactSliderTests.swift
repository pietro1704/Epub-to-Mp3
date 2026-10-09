#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class CompactSliderTests: XCTestCase {
    func testThumbStaysCompactAndClearOfLabelsAtEveryEndpointAndTrackingState() throws {
        let categories: [UIContentSizeCategory] = [.small, .large, .accessibilityExtraExtraExtraLarge]
        for category in categories {
            let slider = CompactSlider()
            let label = UILabel()
            label.text = "00:00"
            label.font = UIFont.preferredFont(
                forTextStyle: .caption1,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
            )
            let stack = UIStackView(arrangedSubviews: [slider, label])
            stack.axis = .vertical
            stack.frame = CGRect(x: 0, y: 0, width: 240, height: 44 + label.intrinsicContentSize.height)
            stack.layoutIfNeeded()
            XCTAssertGreaterThanOrEqual(slider.bounds.height, 44)
            for highlighted in [false, true] {
                slider.isHighlighted = highlighted
                let image = try XCTUnwrap(slider.currentThumbImage)
                XCTAssertLessThanOrEqual(image.size.width, 18)
                XCTAssertLessThanOrEqual(image.size.height, 18)
                for value in [Float(0), 0.5, 1] {
                    slider.value = value
                    slider.layoutIfNeeded()
                    let thumb = slider.thumbRect(
                        forBounds: slider.bounds,
                        trackRect: slider.trackRect(forBounds: slider.bounds),
                        value: value
                    )
                    XCTAssertLessThanOrEqual(thumb.height, 18)
                    try assertRenderedThumb(in: slider, matches: thumb)
                    XCTAssertTrue(slider.bounds.contains(thumb))
                    let labelFrame = label.convert(label.bounds, to: slider)
                    XCTAssertFalse(thumb.intersects(labelFrame))
                    XCTAssertGreaterThanOrEqual(labelFrame.minY - thumb.maxY, 12)
                    XCTAssertTrue(slider.point(inside: CGPoint(x: thumb.midX, y: 1), with: nil))
                    XCTAssertTrue(slider.point(inside: CGPoint(x: thumb.midX, y: 43), with: nil))
                }
            }
        }
    }

    func testVoiceOverRemainsAdjustableAndCommitsSeekWithoutTouchEvents() {
        let slider = CompactSlider()
        slider.minimumValue = 0
        slider.maximumValue = 100
        slider.value = 50
        let observer = ActionObserver()
        slider.addTarget(observer, action: #selector(ActionObserver.changed), for: .valueChanged)
        slider.addTarget(observer, action: #selector(ActionObserver.committed), for: .editingDidEnd)
        XCTAssertTrue(slider.accessibilityTraits.contains(.adjustable))
        slider.accessibilityIncrement()
        XCTAssertGreaterThan(slider.value, 50)
        slider.accessibilityDecrement()
        XCTAssertEqual(slider.value, 50, accuracy: 0.01)
        XCTAssertEqual(observer.changes, 2)
        XCTAssertEqual(observer.commits, 2)
    }

    func testMiniPlayerReservesTouchHeightAndKeepsEndpointTimesBelowThumb() throws {
        let miniPlayer = MiniPlayerBarUIKitView()
        let elapsed = try XCTUnwrap(find(in: miniPlayer, identifier: "miniPlayer.elapsed") as? UILabel)
        let remaining = try XCTUnwrap(find(in: miniPlayer, identifier: "miniPlayer.remaining") as? UILabel)
        elapsed.text = "00:00"
        remaining.text = "-00:00"
        miniPlayer.frame = CGRect(x: 0, y: 0, width: 390, height: miniPlayer.intrinsicContentSize.height)
        miniPlayer.layoutIfNeeded()
        let slider = try XCTUnwrap(find(in: miniPlayer, identifier: "miniPlayer.progress") as? CompactSlider)
        let material = try XCTUnwrap(find(in: miniPlayer, identifier: "miniPlayer.pillMaterial"))
        let stack = try XCTUnwrap(miniPlayer.subviews.first(where: { $0 is UIStackView }) as? UIStackView)
        let chrome = try XCTUnwrap(stack.arrangedSubviews.first)
        let materialFrame = material.convert(material.bounds, to: miniPlayer)
        let sliderFrame = slider.convert(slider.bounds, to: miniPlayer)
        let chromeFrame = chrome.convert(chrome.bounds, to: miniPlayer)
        XCTAssertEqual(material.bounds.height, 112, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(chrome.bounds.height, 44)
        XCTAssertGreaterThanOrEqual(slider.bounds.height, 44)
        XCTAssertTrue(miniPlayer.bounds.contains(sliderFrame))
        XCTAssertTrue(materialFrame.contains(sliderFrame))
        XCTAssertTrue(materialFrame.contains(chromeFrame))
        XCTAssertLessThanOrEqual(chromeFrame.maxY, sliderFrame.minY)
        XCTAssertFalse(stack.hasAmbiguousLayout)
        for label in [elapsed, remaining] {
            let labelFrame = label.convert(label.bounds, to: miniPlayer)
            XCTAssertGreaterThan(label.bounds.width, 0)
            XCTAssertGreaterThanOrEqual(label.bounds.height, label.intrinsicContentSize.height - 0.5)
            XCTAssertGreaterThanOrEqual(label.bounds.width, label.intrinsicContentSize.width - 0.5)
            XCTAssertTrue(miniPlayer.bounds.contains(labelFrame))
            XCTAssertTrue(materialFrame.contains(labelFrame))
            XCTAssertLessThanOrEqual(sliderFrame.maxY, labelFrame.minY)
            XCTAssertLessThanOrEqual(labelFrame.maxY, materialFrame.maxY - 3)
            for highlighted in [false, true] {
                slider.isHighlighted = highlighted
                let image = try XCTUnwrap(slider.currentThumbImage)
                XCTAssertEqual(image.size.width, 18)
                XCTAssertEqual(image.size.height, 18)
                for value in [Float(0), 0.5, 1] {
                    slider.value = value
                    slider.layoutIfNeeded()
                    let thumb = slider.thumbRect(
                        forBounds: slider.bounds,
                        trackRect: slider.trackRect(forBounds: slider.bounds),
                        value: value
                    )
                    XCTAssertLessThanOrEqual(thumb.maxY, label.convert(label.bounds, to: slider).minY)
                    try assertRenderedThumb(in: slider, matches: thumb)
                }
            }
        }
    }

    private func find(in root: UIView, identifier: String) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let match = find(in: child, identifier: identifier) { return match }
        }
        return nil
    }

    func testTrackingClampsEndpointsEmitsContinuousChangesAndMirrorsRightToLeft() throws {
        let slider = CompactSlider(frame: CGRect(x: 0, y: 0, width: 240, height: 44))
        slider.minimumValue = 0
        slider.maximumValue = 100
        let observer = ActionObserver()
        slider.addTarget(observer, action: #selector(ActionObserver.changed), for: .valueChanged)
        for direction in [UISemanticContentAttribute.forceLeftToRight, .forceRightToLeft] {
            slider.semanticContentAttribute = direction
            let track = slider.trackRect(forBounds: slider.bounds)
            for value in [Float(0), 50, 100] {
                let fraction = CGFloat(value / 100)
                let x = track.minX + track.width * (direction == .forceRightToLeft ? 1 - fraction : fraction)
                let previous = slider.value
                let changes = observer.changes
                slider.updateTrackingValue(at: CGPoint(x: x, y: 1))
                slider.layoutIfNeeded()
                XCTAssertEqual(slider.value, value, accuracy: 0.01)
                XCTAssertEqual(observer.changes, changes + (previous == value ? 0 : 1))
                let thumb = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.value)
                try assertRenderedThumb(in: slider, matches: thumb)
            }
            slider.updateTrackingValue(at: CGPoint(x: -100, y: 43))
            XCTAssertEqual(slider.value, direction == .forceRightToLeft ? 100 : 0)
            slider.updateTrackingValue(at: CGPoint(x: 340, y: 43))
            XCTAssertEqual(slider.value, direction == .forceRightToLeft ? 0 : 100)
        }
        XCTAssertEqual(observer.commits, 0)
        slider.accessibilityStep = 2
        slider.value = 50
        slider.accessibilityIncrement()
        XCTAssertEqual(slider.value, 52)
        slider.isEnabled = false
        slider.accessibilityIncrement()
        XCTAssertEqual(slider.value, 52)
    }

    private func assertRenderedThumb(in slider: CompactSlider, matches frame: CGRect) throws {
        let thumbView = try XCTUnwrap(slider.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertFalse(thumbView.isHidden)
        XCTAssertGreaterThan(thumbView.alpha, 0)
        XCTAssertEqual(thumbView.frame, frame)
        XCTAssertEqual(thumbView.bounds.size, CGSize(width: 18, height: 18))
        XCTAssertTrue(thumbView.image === slider.currentThumbImage)
        XCTAssertFalse(thumbView.isUserInteractionEnabled)
    }

    private final class ActionObserver: NSObject {
        var changes = 0
        var commits = 0
        @objc func changed() { changes += 1 }
        @objc func committed() { commits += 1 }
    }
}
#endif
