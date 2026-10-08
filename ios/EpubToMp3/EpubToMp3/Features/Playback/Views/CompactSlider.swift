#if os(iOS)
import UIKit

/// Owns its visuals because modern UISlider styling can ignore custom thumb images.
/// UIControl retains native touch dispatch; adjustable accessibility emits the same seek intent.
final class CompactSlider: UIControl {
    static let thumbDiameter: CGFloat = 18
    static let minimumTouchHeight: CGFloat = 44

    private let minimumTrack = UIView()
    private let maximumTrack = UIView()
    private let thumbView = UIImageView()
    private var storedValue: Float = 0
    private var thumbImages: [UInt: UIImage] = [:]

    var minimumValue: Float = 0 { didSet { value = storedValue } }
    var maximumValue: Float = 1 { didSet { value = storedValue } }
    var value: Float {
        get { storedValue }
        set {
            storedValue = min(max(newValue, minimumValue), max(minimumValue, maximumValue))
            setNeedsLayout()
        }
    }
    var isContinuous = true
    var accessibilityStep: Float?
    var minimumTrackTintColor: UIColor? { didSet { updateColors() } }
    var maximumTrackTintColor: UIColor? { didSet { updateColors() } }
    var thumbTintColor: UIColor? { didSet { installThumb() } }

    var currentThumbImage: UIImage? {
        thumbImages[state.rawValue] ?? thumbImages[UIControl.State.normal.rawValue]
    }

    override var isHighlighted: Bool { didSet { thumbView.image = currentThumbImage } }
    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.4
            thumbView.image = currentThumbImage
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isAccessibilityElement = true
        accessibilityTraits = [.adjustable]
        for view in [maximumTrack, minimumTrack, thumbView] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumTouchHeight).isActive = true
        setContentCompressionResistancePriority(.required, for: .vertical)
        installThumb()
        updateColors()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.minimumTouchHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let track = trackRect(forBounds: bounds)
        let thumb = thumbRect(forBounds: bounds, trackRect: track, value: value)
        maximumTrack.frame = track
        minimumTrack.frame = CGRect(x: track.minX, y: track.minY, width: thumb.midX - track.minX, height: track.height)
        if effectiveUserInterfaceLayoutDirection == .rightToLeft {
            minimumTrack.frame = CGRect(x: thumb.midX, y: track.minY, width: track.maxX - thumb.midX, height: track.height)
        }
        minimumTrack.layer.cornerRadius = track.height / 2
        maximumTrack.layer.cornerRadius = track.height / 2
        thumbView.frame = thumb
        thumbView.image = currentThumbImage
    }

    func trackRect(forBounds bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + Self.thumbDiameter / 2, y: bounds.midY - 2,
               width: max(0, bounds.width - Self.thumbDiameter), height: 4)
    }

    func thumbRect(forBounds bounds: CGRect, trackRect track: CGRect, value: Float) -> CGRect {
        let range = maximumValue - minimumValue
        var fraction = range > 0 ? CGFloat(min(1, max(0, (value - minimumValue) / range))) : 0
        if effectiveUserInterfaceLayoutDirection == .rightToLeft { fraction = 1 - fraction }
        return CGRect(x: track.minX + fraction * track.width - Self.thumbDiameter / 2,
                      y: bounds.midY - Self.thumbDiameter / 2,
                      width: Self.thumbDiameter, height: Self.thumbDiameter)
    }

    func setValue(_ value: Float, animated: Bool) {
        self.value = value
        if animated { UIView.animate(withDuration: 0.15) { self.layoutIfNeeded() } }
    }

    /// Shared by touch tracking and the geometry regression tests.
    func updateTrackingValue(at point: CGPoint) {
        let track = trackRect(forBounds: bounds)
        guard track.width > 0 else { return }
        var fraction = min(1, max(0, (point.x - track.minX) / track.width))
        if effectiveUserInterfaceLayoutDirection == .rightToLeft { fraction = 1 - fraction }
        let previous = value
        value = minimumValue + Float(fraction) * (maximumValue - minimumValue)
        if isContinuous && value != previous { sendActions(for: .valueChanged) }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled else { return false }
        isHighlighted = true
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        updateTrackingValue(at: touch.location(in: self))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { updateTrackingValue(at: touch.location(in: self)) }
        if !isContinuous { sendActions(for: .valueChanged) }
        isHighlighted = false
    }

    override func cancelTracking(with event: UIEvent?) {
        isHighlighted = false
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        installThumb()
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            installThumb()
            updateColors()
        }
    }

    private func updateColors() {
        minimumTrack.backgroundColor = minimumTrackTintColor ?? tintColor
        maximumTrack.backgroundColor = maximumTrackTintColor ?? .tertiaryLabel
    }

    private func installThumb() {
        let size = CGSize(width: Self.thumbDiameter, height: Self.thumbDiameter)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            (thumbTintColor ?? tintColor ?? UIColor.label)
                .resolvedColor(with: traitCollection).setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
        let states: [UIControl.State] = [.normal, .highlighted, .disabled, [.highlighted, .selected]]
        for state in states { thumbImages[state.rawValue] = image }
        thumbView.image = currentThumbImage
    }

    override var accessibilityValue: String? {
        get {
            if let custom = super.accessibilityValue { return custom }
            let range = maximumValue - minimumValue
            let percentage = range > 0 ? Int((value - minimumValue) / range * 100) : 0
            return "\(percentage)%"
        }
        set { super.accessibilityValue = newValue }
    }

    override func accessibilityIncrement() { adjustAccessibilityValue(direction: 1) }
    override func accessibilityDecrement() { adjustAccessibilityValue(direction: -1) }

    private func adjustAccessibilityValue(direction: Float) {
        guard isEnabled else { return }
        value += direction * (accessibilityStep ?? (maximumValue - minimumValue) / 10)
        sendActions(for: .valueChanged)
        sendActions(for: .editingDidEnd)
    }
}
#endif
