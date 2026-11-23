import 'dart:async';

import 'package:flutter/widgets.dart';

import '../conversion/embedded_conversion_contract.dart';

/// Tells Rust to pace local synthesis while the app is in the background or the
/// screen is locked, and to run free again when the user returns. The operating
/// system budgets background CPU per process (iOS kills at 80% over 60 s), so
/// the limit is process-wide and Rust owns how it is applied.
class BackgroundPacingController with WidgetsBindingObserver {
  BackgroundPacingController({
    required this._converter,
    this.backgroundPercent = 50,
  }) {
    WidgetsBinding.instance.addObserver(this);
  }

  final EmbeddedConverter Function() _converter;

  /// Share of one core synthesis may use while backgrounded.
  final int backgroundPercent;

  int? _applied;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      // Not "inactive": that is a transient state (dialogs, the app switcher).
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _apply(backgroundPercent);
      case AppLifecycleState.resumed:
        _apply(0);
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _apply(int percent) {
    if (_applied == percent) return;
    _applied = percent;
    final converter = _converter();
    if (converter is! BackgroundPacingCapable) return;
    unawaited(
      (converter as BackgroundPacingCapable).setBackgroundCpuLimit(percent),
    );
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Never leave the process throttled.
    _apply(0);
  }
}
