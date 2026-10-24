part of 'desktop_embedded_converter.dart';

typedef _ControlJsonNative = ffi.Bool Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>);
typedef _ControlJsonDart = bool Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>);
typedef _ControlGenerationNative = ffi.Uint64 Function(ffi.Pointer<ffi.Void>);
typedef _ControlGenerationDart = int Function(ffi.Pointer<ffi.Void>);
typedef _ControlContainsNative = ffi.Bool Function(ffi.Pointer<ffi.Void>, ffi.UintPtr);
typedef _ControlContainsDart = bool Function(ffi.Pointer<ffi.Void>, int);

typedef _ControlObserveNative = ffi.Bool Function(ffi.Pointer<ffi.Void>, ffi.Uint64, ffi.Double, ffi.UintPtr);
typedef _ControlObserveDart = bool Function(ffi.Pointer<ffi.Void>, int, double, int);

/// A lightweight Rust control outlives individual immutable chapter requests.
final class DesktopListeningSchedule implements ListeningSchedule {
  DesktopListeningSchedule(this.library, int chapterIndex) {
    _position = library.lookupFunction<_ControlJsonNative, _ControlJsonDart>(
      'converter_job_control_set_listening_position_json_v2');
    _feedback = library.lookupFunction<_ControlJsonNative, _ControlJsonDart>(
      'converter_job_control_playback_feedback_json_v2');
    _generation = library.lookupFunction<_ControlGenerationNative, _ControlGenerationDart>(
      'converter_job_control_listening_generation_v2');
    _contains = library.lookupFunction<_ControlContainsNative, _ControlContainsDart>(
      'converter_job_control_chapter_is_in_playback_window');
    _observe = library.lookupFunction<_ControlObserveNative, _ControlObserveDart>(
      'converter_job_control_observe_generation_v2');
    _free = library.lookupFunction<_ControlActionNative, _ControlActionDart>(
      'converter_job_control_free');
    _control = library.lookupFunction<_ControlCreateNative, _ControlCreateDart>(
      'converter_job_control_create')();
    try { moveTo(chapterIndex); } catch (_) { close(); rethrow; }
  }
  final ffi.DynamicLibrary library;
  late final _ControlJsonDart _position, _feedback;
  late final _ControlGenerationDart _generation;
  late final _ControlContainsDart _contains;
  late final _ControlActionDart _free;
  late final _ControlObserveDart _observe;
  ffi.Pointer<ffi.Void> _control = ffi.nullptr;

  void _send(_ControlJsonDart operation, Map<String, Object> value) {
    if (_control == ffi.nullptr) throw StateError('Listening schedule is closed');
    using((arena) {
      if (!operation(_control, jsonEncode(value).toNativeUtf8(allocator: arena))) {
        throw StateError('Rust rejected listening intent');
      }
    });
  }
  @override
  void moveTo(int chapterIndex) => _send(_position,
    {'version': 2, 'chapter_index': chapterIndex, 'text_offset': 0});
  @override
  bool permits(int chapterIndex) => _control != ffi.nullptr && _contains(_control, chapterIndex);
  @override
  void feedback({required int chapterIndex, required double remainingSeconds,
    required double playbackRate}) => _send(_feedback, {'version': 2,
      'generation': _generation(_control), 'chapter_index': chapterIndex,
      'remaining_audio_seconds': remainingSeconds, 'playback_rate': playbackRate});
  @override
  void observeGeneration(double seconds, int textCharacters) {
    if (_control != ffi.nullptr) _observe(_control, _generation(_control), seconds, textCharacters);
  }
  @override
  void close() {
    if (_control == ffi.nullptr) return;
    _free(_control);
    _control = ffi.nullptr;
  }
}
