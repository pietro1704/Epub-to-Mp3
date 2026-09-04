import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/playback_first_resource_policy.dart';

void main() {
  test('conversion yields for playback and pending navigation', () {
    var now = DateTime.utc(2026, 9, 4, 12);
    final policy = PlaybackFirstResourcePolicy(now: () => now);

    expect(
      policy.yieldReason(playbackActive: true, pendingNavigation: false),
      ConversionYieldReason.playback,
    );
    expect(
      policy.yieldReason(playbackActive: false, pendingNavigation: true),
      ConversionYieldReason.pendingNavigation,
    );
    now = now.add(const Duration(seconds: 10));
    expect(
      policy.yieldReason(playbackActive: false, pendingNavigation: false),
      isNull,
    );
  });

  test('conversion resumes only after the reader and memory are stable', () {
    var now = DateTime.utc(2026, 9, 4, 12);
    final policy = PlaybackFirstResourcePolicy(
      now: () => now,
      stabilityWindow: const Duration(seconds: 5),
    );

    policy.recordReaderInteraction();
    expect(
      policy.yieldReason(playbackActive: false, pendingNavigation: false),
      ConversionYieldReason.readerInteraction,
    );
    now = now.add(const Duration(seconds: 5));
    policy.recordMemoryPressure();
    expect(
      policy.yieldReason(playbackActive: false, pendingNavigation: false),
      ConversionYieldReason.memoryPressure,
    );
    now = now.add(const Duration(seconds: 5));
    expect(
      policy.yieldReason(playbackActive: false, pendingNavigation: false),
      isNull,
    );
  });
}
