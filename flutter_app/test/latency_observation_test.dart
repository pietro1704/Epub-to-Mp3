import 'package:flutter_app/services/latency_observation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps queued, playable and audible boundaries distinct', () {
    final store = LatencyObservationStore();
    final id = store.begin(
      LatencyJourneyKind.progressivePlayback,
      LatencyTransition.interactionRequested,
    );
    expect(store.record(id, LatencyTransition.audioQueued), isTrue);
    expect(store.record(id, LatencyTransition.audioPlayable), isTrue);
    expect(store.record(id, LatencyTransition.audioAudible), isTrue);
    store.finish(id);

    expect(store.snapshot().single.records.map((record) => record.transition), [
      LatencyTransition.interactionRequested,
      LatencyTransition.audioQueued,
      LatencyTransition.audioPlayable,
      LatencyTransition.audioAudible,
    ]);
  });

  test('cancellation prevents a later seek completion', () {
    final store = LatencyObservationStore();
    final id = store.begin(
      LatencyJourneyKind.seek,
      LatencyTransition.seekRequested,
    );
    store.cancel(id);
    expect(store.record(id, LatencyTransition.seekTargetReached), isFalse);
    expect(
      store.snapshot().single.records.last.transition,
      LatencyTransition.cancelled,
    );
  });

  test('ignores repeated ready boundaries in one journey', () {
    final store = LatencyObservationStore();
    final id = store.begin(
      LatencyJourneyKind.progressivePlayback,
      LatencyTransition.interactionRequested,
    );

    expect(store.record(id, LatencyTransition.audioQueued), isTrue);
    expect(store.record(id, LatencyTransition.audioQueued), isFalse);
    expect(store.snapshot().single.records.map((record) => record.transition), [
      LatencyTransition.interactionRequested,
      LatencyTransition.audioQueued,
    ]);
  });
}
