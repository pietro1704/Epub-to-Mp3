import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/sse_subscription_lifecycle.dart';

void main() {
  group('SseSubscriptionLifecycle.listen', () {
    test('onError cancels the subscription so further events are ignored',
        () async {
      // book_open_screen pre-slice-35 left _sseSubscription attached
      // after onError fired. The UI rendered the "failed" state, but
      // the stream could keep emitting (transient network blip
      // recovered by the EventSource client, backend resuming an
      // older job), and _handleSnapshot kept writing chapters into
      // the player + queue. Slice 35 cancels at the lifecycle
      // boundary.
      final controller = StreamController<int>();
      addTearDown(controller.close);

      final snapshots = <int>[];
      var errors = 0;
      var dones = 0;

      SseSubscriptionLifecycle.listen<int>(
        controller.stream,
        onData: snapshots.add,
        onError: (_) => errors++,
        onDone: () => dones++,
      );

      controller.add(1);
      controller.add(2);
      await Future<void>.delayed(Duration.zero);

      controller.addError(Exception('boom'));
      await Future<void>.delayed(Duration.zero);

      // Late event arrives after the error — must be discarded.
      controller.add(3);
      await Future<void>.delayed(Duration.zero);

      expect(snapshots, [1, 2],
          reason: 'no snapshots may be delivered after the error fires');
      expect(errors, 1);
      expect(dones, 0,
          reason: 'cancelling on error must not also fire onDone');
    });

    test('onDone cancels the subscription before forwarding the callback',
        () async {
      final controller = StreamController<int>();

      final snapshots = <int>[];
      var dones = 0;

      SseSubscriptionLifecycle.listen<int>(
        controller.stream,
        onData: snapshots.add,
        onError: (_) {},
        onDone: () => dones++,
      );

      controller.add(7);
      await Future<void>.delayed(Duration.zero);
      await controller.close();
      await Future<void>.delayed(Duration.zero);

      expect(snapshots, [7]);
      expect(dones, 1);
    });

    test('caller can still cancel the returned subscription explicitly',
        () async {
      final controller = StreamController<int>();
      addTearDown(controller.close);

      final snapshots = <int>[];

      final sub = SseSubscriptionLifecycle.listen<int>(
        controller.stream,
        onData: snapshots.add,
        onError: (_) {},
        onDone: () {},
      );

      controller.add(1);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      controller.add(2);
      await Future<void>.delayed(Duration.zero);

      expect(snapshots, [1]);
    });
  });
}
