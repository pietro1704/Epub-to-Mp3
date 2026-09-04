/// Privacy-safe, in-memory latency boundaries shared by reader and playback.
/// The store never accepts a book title, job id, URI, account, or text.
enum LatencyJourneyKind { readerOpen, progressivePlayback, seek }

enum LatencyTransition {
  interactionRequested,
  readerUsable,
  audioQueued,
  audioPlayable,
  audioAudible,
  seekRequested,
  seekTargetReached,
  cancelled,
}

class LatencyRecord {
  const LatencyRecord(this.transition, this.elapsed);
  final LatencyTransition transition;
  final Duration elapsed;
}

class LatencyJourney {
  LatencyJourney(this.id, this.kind, this.records, {this.terminal = false});
  final String id;
  final LatencyJourneyKind kind;
  final List<LatencyRecord> records;
  bool terminal;
}

class LatencyObservationStore {
  LatencyObservationStore({
    Stopwatch Function()? stopwatchFactory,
    this.capacity = 200,
  }) : _stopwatchFactory = stopwatchFactory ?? Stopwatch.new;

  final Stopwatch Function() _stopwatchFactory;
  final int capacity;
  final Map<String, (Stopwatch, LatencyJourney)> _active = {};
  final List<String> _order = [];
  int _counter = 0;

  String begin(LatencyJourneyKind kind, LatencyTransition initial) {
    final id = 'journey-${++_counter}';
    final stopwatch = _stopwatchFactory()..start();
    _active[id] = (
      stopwatch,
      LatencyJourney(id, kind, [LatencyRecord(initial, Duration.zero)]),
    );
    _order.add(id);
    while (_order.length > capacity) {
      _active.remove(_order.removeAt(0));
    }
    return id;
  }

  bool record(String id, LatencyTransition transition) {
    final value = _active[id];
    if (value == null ||
        value.$2.terminal ||
        transition == LatencyTransition.cancelled) {
      return false;
    }
    if (value.$2.records.last.transition == transition) return false;
    value.$2.records.add(LatencyRecord(transition, value.$1.elapsed));
    return true;
  }

  void finish(String id) {
    final value = _active[id];
    if (value != null) value.$2.terminal = true;
  }

  void cancel(String id) {
    final value = _active[id];
    if (value == null || value.$2.terminal) return;
    value.$2.records.add(
      LatencyRecord(LatencyTransition.cancelled, value.$1.elapsed),
    );
    value.$2.terminal = true;
  }

  List<LatencyJourney> snapshot() => _order
      .map((id) => _active[id]?.$2)
      .whereType<LatencyJourney>()
      .toList(growable: false);
}

final latencyObservations = LatencyObservationStore();
