import SwiftUI

#if canImport(UIKit)
import UIKit

/// `CADisplayLink`-driven progress bar for the mini/full player. Replaces
/// SwiftUI bars that read `playbackClock.positionSeconds`/`durationSeconds`
/// directly in `body` — `PlaybackClock.snapshot` is `@Published` from a
/// 0.25s `AVPlayer.addPeriodicTimeObserver` tick (~4 Hz), and reading it in
/// `body` re-evaluates the *entire* enclosing view on every tick (1086
/// lines for `FullPlayerSheet`). This view instead polls plain closures
/// each vsync and mutates a `CALayer` frame directly, so the SwiftUI tree
/// above it never re-renders for a position change.
///
/// See docs/plans/uikit-performance-migration.md (Phase 2, item 5).
struct PlaybackProgressBar: UIViewRepresentable {
    var positionProvider: () -> TimeInterval
    var durationProvider: () -> TimeInterval
    var isConvertingProvider: () -> Bool
    var conversionProgressProvider: () -> Double?
    var convertingColor: UIColor = .systemOrange

    func makeUIView(context: Context) -> PlaybackProgressBarUIView {
        let view = PlaybackProgressBarUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ view: PlaybackProgressBarUIView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: PlaybackProgressBarUIView) {
        view.positionProvider = positionProvider
        view.durationProvider = durationProvider
        view.isConvertingProvider = isConvertingProvider
        view.conversionProgressProvider = conversionProgressProvider
        view.convertingColor = convertingColor
    }
}

/// Segmented per-chapter book-progress bar (mini + full player). Rebuilds
/// its `CALayer` segments only when the chapter identity list changes
/// (once per snapshot refresh, not per tick); every other frame just
/// repositions the "current chapter" outline via `CADisplayLink`, never
/// touching SwiftUI state.
struct SegmentedPlaybackProgressBar: UIViewRepresentable {
    var bookProgressProvider: () -> BookChapterProgress?
    var currentPlayableIndexProvider: () -> Int?

    func makeUIView(context: Context) -> SegmentedPlaybackProgressBarUIView {
        let view = SegmentedPlaybackProgressBarUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ view: SegmentedPlaybackProgressBarUIView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: SegmentedPlaybackProgressBarUIView) {
        view.bookProgressProvider = bookProgressProvider
        view.currentPlayableIndexProvider = currentPlayableIndexProvider
    }
}

/// Backing view for `PlaybackProgressBar`. A `CADisplayLink` drives a
/// single `CALayer` frame update per vsync while attached to a window;
/// paused automatically off-screen (`didMoveToWindow`).
final class PlaybackProgressBarUIView: UIView {
    var positionProvider: (() -> TimeInterval)?
    var durationProvider: (() -> TimeInterval)?
    var isConvertingProvider: (() -> Bool)?
    var conversionProgressProvider: (() -> Double?)?
    var convertingColor: UIColor = .systemOrange {
        didSet { refreshColor() }
    }

    private let fillLayer = CALayer()
    private var displayLink: CADisplayLink?
    private var isConverting = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(fillLayer)
        refreshColor()
        isAccessibilityElement = false
        accessibilityIdentifier = "playbackProgressBar"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        refreshColor()
    }

    private func refreshColor() {
        fillLayer.backgroundColor = (isConverting ? convertingColor : tintColor).cgColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window != nil ? startDisplayLink() : stopDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        // A progress bar doesn't need 120 Hz precision; capping at 30fps
        // keeps ProMotion devices from spending battery redrawing a
        // ~4 Hz-changing value every vsync.
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
        tick()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        let converting = isConvertingProvider?() ?? false
        let fraction: Double
        if converting {
            fraction = conversionProgressProvider?() ?? 0
        } else {
            fraction = PlaybackProgressLayout.fraction(
                position: positionProvider?() ?? 0,
                duration: durationProvider?() ?? 0
            )
        }
        if converting != isConverting {
            isConverting = converting
            refreshColor()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(
            x: 0, y: 0,
            width: bounds.width * CGFloat(min(1, max(0, fraction))),
            height: bounds.height
        )
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tick()
    }
}

/// Backing view for `SegmentedPlaybackProgressBar`.
final class SegmentedPlaybackProgressBarUIView: UIView {
    var bookProgressProvider: (() -> BookChapterProgress?)?
    var currentPlayableIndexProvider: (() -> Int?)?

    private var segmentLayers: [CALayer] = []
    private let currentOutlineLayer = CALayer()
    private var lastChapterIDs: [Int] = []
    private var lastWidth: CGFloat = -1
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        currentOutlineLayer.borderWidth = 1
        currentOutlineLayer.borderColor = UIColor.label.cgColor
        currentOutlineLayer.isHidden = true
        layer.addSublayer(currentOutlineLayer)
        isAccessibilityElement = true
        accessibilityLabel = "Book progress"
        accessibilityIdentifier = "segmentedPlaybackProgressBar"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window != nil ? startDisplayLink() : stopDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
        tick()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard let progress = bookProgressProvider?(), !progress.chapters.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false
        let ids = progress.chapters.map(\.epubIndex)
        if ids != lastChapterIDs || bounds.width != lastWidth {
            rebuildSegments(progress: progress)
            lastChapterIDs = ids
            lastWidth = bounds.width
        }
        updateCurrentOutline(progress: progress)
    }

    private func rebuildSegments(progress: BookChapterProgress) {
        segmentLayers.forEach { $0.removeFromSuperlayer() }
        let segments = PlaybackProgressLayout.segments(
            for: progress, totalWidth: bounds.width, height: bounds.height,
            currentPlayableIndex: currentPlayableIndexProvider?()
        )
        segmentLayers = segments.map { segment in
            let segmentLayer = CALayer()
            segmentLayer.frame = segment.frame
            segmentLayer.cornerRadius = min(segment.frame.height / 2, 3)
            segmentLayer.backgroundColor = Self.color(for: segment.colorState).cgColor
            layer.insertSublayer(segmentLayer, below: currentOutlineLayer)
            return segmentLayer
        }
        accessibilityValue = "\(Int(progress.overallRatio * 100)) percent"
    }

    private func updateCurrentOutline(progress: BookChapterProgress) {
        guard let currentIndex = currentPlayableIndexProvider?(),
              let match = progress.chapters.first(where: { $0.playableIndex == currentIndex }),
              let i = progress.chapters.firstIndex(where: { $0.epubIndex == match.epubIndex }),
              i < segmentLayers.count else {
            currentOutlineLayer.isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        currentOutlineLayer.isHidden = false
        currentOutlineLayer.frame = segmentLayers[i].frame.insetBy(dx: -0.5, dy: -0.5)
        currentOutlineLayer.cornerRadius = segmentLayers[i].cornerRadius
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tick()
    }

    private static func color(for state: BookChapterProgress.State) -> UIColor {
        switch state {
        case .completed: return .tintColor
        case .running: return .systemOrange
        case .failed: return .systemRed
        case .queued: return UIColor.secondaryLabel.withAlphaComponent(0.25)
        }
    }
}
#endif
