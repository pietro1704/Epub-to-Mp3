import 'dart:math';

/// Privacy-safe, in-memory latency boundaries shared by reader and playback.
///
/// Journeys contain only an opaque correlation token, document/cache classes,
/// and monotonic elapsed durations. Titles, paths, job ids, account ids, and
/// book text must never cross this boundary.
enum LatencyJourneyKind {
  readerOpen('book_open'),
  progressivePlayback('progressive_playback'),
  seek('seek');

  const LatencyJourneyKind(this.wireName);
  final String wireName;
}

enum LatencyTransition {
  interactionRequested('open_requested'),
  playRequested('play_requested'),
  readerUsable('readable_content'),
  controlsUsable('controls_usable'),
  firstPdfPage('first_pdf_page'),
  audioQueued('audio_queued'),
  audioPlayable('audio_playable'),
  audioAudible('audio_audible'),
  seekRequested('seek_requested'),
  seekTargetReached('seek_target_reached'),
  cancelled('cancelled');

  const LatencyTransition(this.wireName);
  final String wireName;
}

enum LatencyDocumentKind {
  epub('epub'),
  selectableTextPdf('selectable_text_pdf'),
  normalizedScannedPdf('normalized_scanned_pdf');

  const LatencyDocumentKind(this.wireName);
  final String wireName;
}

enum LatencyCacheClass {
  unknown('unknown'),
  inMemoryWarm('in_memory_warm'),
  preparedDisk('prepared_disk'),
  cold('cold');

  const LatencyCacheClass(this.wireName);
  final String wireName;
}

class LatencyRecord {
  const LatencyRecord(this.transition, this.elapsed);
  final LatencyTransition transition;
  final Duration elapsed;

  Map<String, Object> toJson() => {
    'transition': transition.wireName,
    'elapsedNanoseconds': elapsed.inMicroseconds * 1000,
  };
}

class LatencyJourney {
  LatencyJourney(
    this.id,
    this.kind,
    this.records, {
    this.documentKind = LatencyDocumentKind.epub,
    this.cacheClass = LatencyCacheClass.unknown,
    this.expiresAt,
    this.terminal = false,
  });

  /// Opaque random token. It is deliberately not derived from a book/job id.
  final String id;
  final LatencyJourneyKind kind;
  final LatencyDocumentKind documentKind;
  LatencyCacheClass cacheClass;
  final List<LatencyRecord> records;
  final DateTime? expiresAt;
  bool terminal;

  bool isExpired(DateTime now) =>
      expiresAt != null && !now.isBefore(expiresAt!);

  Map<String, Object> toJson() => {
    'id': id,
    'kind': kind.wireName,
    'documentKind': documentKind.wireName,
    'cacheClass': cacheClass.wireName,
    'records': records.take(5).map((record) => record.toJson()).toList(),
  };
}

class LatencyObservationStore {
  LatencyObservationStore({
    Stopwatch Function()? stopwatchFactory,
    DateTime Function()? now,
    this.capacity = 200,
    this.correlationLifetime = const Duration(minutes: 15),
  }) : _stopwatchFactory = stopwatchFactory ?? Stopwatch.new,
       _now = now ?? DateTime.now;

  final Stopwatch Function() _stopwatchFactory;
  final DateTime Function() _now;
  final int capacity;
  final Duration correlationLifetime;
  final Map<String, (Stopwatch, LatencyJourney)> _active = {};
  final List<String> _order = [];
  final Random _random = Random.secure();

  String begin(
    LatencyJourneyKind kind,
    LatencyTransition initial, {
    LatencyDocumentKind documentKind = LatencyDocumentKind.epub,
    LatencyCacheClass cacheClass = LatencyCacheClass.unknown,
  }) {
    if (initial == LatencyTransition.cancelled) {
      throw ArgumentError.value(initial, 'initial', 'must not be cancelled');
    }
    final id = _opaqueId();
    final stopwatch = _stopwatchFactory()..start();
    _active[id] = (
      stopwatch,
      LatencyJourney(
        id,
        kind,
        [LatencyRecord(initial, Duration.zero)],
        documentKind: documentKind,
        cacheClass: cacheClass,
        expiresAt: _now().add(correlationLifetime),
      ),
    );
    _order.add(id);
    _trim();
    return id;
  }

  bool record(String id, LatencyTransition transition) {
    final value = _active[id];
    if (value == null || value.$2.terminal || value.$2.isExpired(_now())) {
      return false;
    }
    if (transition == LatencyTransition.cancelled ||
        value.$2.records.any((record) => record.transition == transition) ||
        !_isValidTransition(value.$2, transition)) {
      return false;
    }
    value.$2.records.add(LatencyRecord(transition, value.$1.elapsed));
    return true;
  }

  void classifyCache(String id, LatencyCacheClass cacheClass) {
    final value = _active[id];
    if (value == null || value.$2.terminal || value.$2.isExpired(_now())) {
      return;
    }
    value.$2.cacheClass = cacheClass;
  }

  void finish(String id) {
    final value = _active[id];
    if (value != null) value.$2.terminal = true;
  }

  void cancel(String id) {
    final value = _active[id];
    if (value == null || value.$2.terminal || value.$2.isExpired(_now())) {
      return;
    }
    value.$2.records.add(
      LatencyRecord(LatencyTransition.cancelled, value.$1.elapsed),
    );
    value.$2.terminal = true;
  }

  /// Removes expired correlations without affecting protected audio or reader state.
  void purgeExpired() {
    for (final id in List<String>.from(_order)) {
      final value = _active[id];
      if (value != null && !value.$2.terminal && value.$2.isExpired(_now())) {
        _active.remove(id);
      }
    }
    _order.removeWhere((id) => !_active.containsKey(id));
  }

  List<LatencyJourney> snapshot() {
    purgeExpired();
    return _order
        .map((id) => _active[id]?.$2)
        .whereType<LatencyJourney>()
        .toList(growable: false);
  }

  String _opaqueId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  void _trim() {
    final boundedCapacity = max(1, capacity);
    while (_order.length > boundedCapacity) {
      _active.remove(_order.removeAt(0));
    }
  }

  static bool _isValidTransition(
    LatencyJourney journey,
    LatencyTransition transition,
  ) {
    final seen = journey.records.map((record) => record.transition).toSet();
    switch (journey.kind) {
      case LatencyJourneyKind.readerOpen:
        return {
          LatencyTransition.readerUsable,
          LatencyTransition.controlsUsable,
          LatencyTransition.firstPdfPage,
        }.contains(transition);
      case LatencyJourneyKind.progressivePlayback:
        return transition == LatencyTransition.audioQueued ||
            transition == LatencyTransition.audioPlayable ||
            (transition == LatencyTransition.audioAudible &&
                (seen.contains(LatencyTransition.audioQueued) ||
                    seen.contains(LatencyTransition.audioPlayable)));
      case LatencyJourneyKind.seek:
        return transition == LatencyTransition.seekTargetReached &&
            seen.contains(LatencyTransition.seekRequested);
    }
  }
}

final latencyObservations = LatencyObservationStore();
