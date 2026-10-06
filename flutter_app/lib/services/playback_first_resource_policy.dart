/// Decides whether a local conversion may start its next chapter.
///
/// Existing audio is never interrupted. A conversion cooperatively yields
/// between chapters while a listener is playing, has requested navigation,
/// is actively interacting with the reader, or the process reported memory
/// pressure. It resumes only after the listener-visible path has been quiet
/// for [stabilityWindow].
enum ConversionYieldReason {
  playback,
  pendingNavigation,
  readerInteraction,
  memoryPressure,
}

class PlaybackFirstResourcePolicy {
  PlaybackFirstResourcePolicy({
    DateTime Function()? now,
    this.stabilityWindow = const Duration(seconds: 5),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Duration stabilityWindow;
  DateTime? _lastReaderInteraction;
  DateTime? _lastMemoryPressure;

  void recordReaderInteraction() => _lastReaderInteraction = _now();

  void recordMemoryPressure() => _lastMemoryPressure = _now();

  ConversionYieldReason? yieldReason({
    required bool playbackActive,
    required bool pendingNavigation,
  }) {
    if (playbackActive) return ConversionYieldReason.playback;
    if (pendingNavigation) return ConversionYieldReason.pendingNavigation;
    if (_isWithinStabilityWindow(_lastReaderInteraction)) {
      return ConversionYieldReason.readerInteraction;
    }
    if (_isWithinStabilityWindow(_lastMemoryPressure)) {
      return ConversionYieldReason.memoryPressure;
    }
    return null;
  }

  bool _isWithinStabilityWindow(DateTime? instant) {
    if (instant == null) return false;
    return _now().difference(instant) < stabilityWindow;
  }
}
