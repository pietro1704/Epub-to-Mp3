/// Keeps the reader paired with the narration: the page shows the spoken
/// sentence. With "follow spoken text" on the page turns by itself (forward and
/// back); a manual page turn suspends that until the narration is on the page
/// again or the user asks to go back to it.
class NarrationPairing {
  bool _suspended = false;

  bool get suspended => _suspended;

  /// The user turned the page (tap, swipe, key).
  void suspendAfterManualTurn() => _suspended = true;

  /// Back to the narrated page, following again.
  void resume() => _suspended = false;

  /// The page to turn to, or null to stay where the reader is. Reaching the
  /// page that holds the narration (by any means) clears the suspension.
  int? targetPage({required int shown, required int? narrated, required bool follow}) {
    if (narrated == null) return null;
    if (narrated == shown) {
      _suspended = false;
      return null;
    }
    if (!follow || _suspended) return null;
    return narrated;
  }

  /// null: nothing is narrated here; otherwise whether the page shows it.
  static bool? paired({required int shown, required int? narrated}) =>
      narrated == null ? null : narrated == shown;
}
