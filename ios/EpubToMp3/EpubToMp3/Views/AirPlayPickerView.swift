#if os(iOS)
import SwiftUI
import AVKit

/// Thin `UIViewRepresentable` wrapper around `AVRoutePickerView` so
/// AirPlay / AirPods / Bluetooth route selection appears as a native
/// SwiftUI view in the `PlayerReaderView` toolbar.
///
/// macOS: intentionally excluded — `AVRoutePickerView` behaves differently
/// on macOS and the menu-bar route picker is the standard UX there.
struct AirPlayPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        // Blue when an external route (AirPlay / AirPods) is active.
        view.activeTintColor = .systemBlue
        // Matches .label so the icon is legible in both light and dark mode.
        view.tintColor = .label
        // Long-form audio policy so the picker shows full AirPlay speaker
        // list (e.g. HomePod, Apple TV) rather than just BT headphones.
        view.preferredRouteSharingPolicy = .longFormAudio
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
