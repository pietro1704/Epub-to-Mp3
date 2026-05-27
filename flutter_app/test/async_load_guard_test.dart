import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/async_load_guard.dart';

void main() {
  group('AsyncLoadGuard', () {
    test('the first started generation is the active one', () {
      final guard = AsyncLoadGuard();
      final gen = guard.start();
      expect(guard.isCurrent(gen), isTrue);
    });

    test('starting a new generation invalidates the previous one', () {
      // book_open_screen.didUpdateWidget races with an in-flight _load
      // when the user navigates between books faster than the cache
      // read / parseEpub completes. Without the guard the slow path
      // would `setState(_fulltext = X)` after the widget already
      // showed Y — flashing X's content into Y's screen. The guard
      // makes the slow continuation a no-op.
      final guard = AsyncLoadGuard();
      final genX = guard.start();
      final genY = guard.start();

      expect(guard.isCurrent(genX), isFalse,
          reason: 'older generation must surrender to the newer one');
      expect(guard.isCurrent(genY), isTrue);
    });

    test('successive checks against the same generation stay current '
        'until something else starts', () {
      final guard = AsyncLoadGuard();
      final gen = guard.start();

      for (var i = 0; i < 5; i++) {
        expect(guard.isCurrent(gen), isTrue);
      }

      guard.start();
      expect(guard.isCurrent(gen), isFalse);
    });

    test('generations are monotonically distinct so equal-key reuse '
        'still produces a fresh token', () {
      // Even if a caller restarts a load for the SAME key (e.g.
      // user taps Retry), the previous in-flight Future must be
      // marked stale so its setState does not collide with the
      // retry's setState.
      final guard = AsyncLoadGuard();
      final genA = guard.start();
      final genB = guard.start();
      expect(genA == genB, isFalse);
    });
  });
}
