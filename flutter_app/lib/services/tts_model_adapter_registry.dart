import 'desktop_tts_model_adapter.dart';

/// Process-local access to the shared Rust model catalog on desktop targets.
class TtsModelAdapterRegistry {
  TtsModelAdapterRegistry._();

  static DesktopTtsModelAdapter? _desktop;
  static bool _desktopEnabled = false;

  static DesktopTtsModelAdapter get desktop {
    if (!_desktopEnabled) {
      throw const DesktopTtsModelAdapterError(
        'desktop TTS model adapter is not enabled',
      );
    }
    return _desktop ??= DesktopTtsModelAdapter();
  }

  static void enableDesktop() {
    _desktopEnabled = true;
  }

  static void registerDesktop(DesktopTtsModelAdapter adapter) {
    _desktop = adapter;
    _desktopEnabled = true;
  }

  static void clear() {
    _desktop = null;
    _desktopEnabled = false;
  }
}
