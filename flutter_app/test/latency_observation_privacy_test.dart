import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/latency_observation.dart';

void main() {
  test('uses opaque short-lived correlations and redacted wire vocabulary', () {
    var now = DateTime.utc(2026, 9, 14);
    final store = LatencyObservationStore(
      now: () => now,
      correlationLifetime: const Duration(minutes: 5),
    );
    final id = store.begin(
      LatencyJourneyKind.readerOpen,
      LatencyTransition.interactionRequested,
      documentKind: LatencyDocumentKind.selectableTextPdf,
      cacheClass: LatencyCacheClass.cold,
    );

    expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(id, isNot(contains('book')));
    expect(store.record(id, LatencyTransition.readerUsable), isTrue);
    final json = store.snapshot().single.toJson();
    expect(json, isNot(contains('title')));
    expect(json['kind'], 'book_open');
    expect(json['documentKind'], 'selectable_text_pdf');
    expect(json['cacheClass'], 'cold');
    expect(json.toString(), isNot(contains('job')));

    now = now.add(const Duration(minutes: 5));
    expect(store.snapshot(), isEmpty);
    expect(store.record(id, LatencyTransition.controlsUsable), isFalse);
  });

  test('rejects listener-visible boundaries that skip their prerequisite', () {
    final store = LatencyObservationStore();
    final playback = store.begin(
      LatencyJourneyKind.progressivePlayback,
      LatencyTransition.interactionRequested,
    );
    expect(store.record(playback, LatencyTransition.audioAudible), isFalse);

    final seek = store.begin(
      LatencyJourneyKind.seek,
      LatencyTransition.seekRequested,
    );
    expect(store.record(seek, LatencyTransition.seekTargetReached), isTrue);
  });
}
