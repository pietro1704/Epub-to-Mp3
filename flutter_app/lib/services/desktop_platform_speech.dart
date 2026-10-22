part of 'desktop_embedded_converter.dart';

/// Registers installed system speech inside the worker-owned session only.
bool _installDesktopPlatformSpeech(
  ffi.DynamicLibrary library,
  ffi.Pointer<_NativeSession> session,
  Map<String, dynamic> options,
) {
  final preferences = options['tts_preferences'];
  if (preferences is Map &&
      ((preferences['primary'] is Map &&
              preferences['primary']['engine'] == 'system') ||
          (preferences['secondary'] is Map &&
              preferences['secondary']['engine'] == 'system'))) {
    final _PlatformTtsDart install;
    try {
      install = library.lookupFunction<_PlatformTtsNative, _PlatformTtsDart>(
        'converter_session_set_desktop_platform_tts_v1',
      );
    } on ArgumentError {
      throw EmbeddedConversionFailure(
        'NATIVE_TTS_ABI_UNAVAILABLE',
        'The installed converter does not support native speech fallback',
      );
    }
    if (!install(session)) {
      return false;
    }
  }
  return true;
}

typedef _PlatformTtsNative = ffi.Bool Function(ffi.Pointer<_NativeSession>);
typedef _PlatformTtsDart = bool Function(ffi.Pointer<_NativeSession>);
