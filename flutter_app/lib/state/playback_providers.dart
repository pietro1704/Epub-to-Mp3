part of 'providers.dart';

// Shared audio player, playback session and background audio state.

class AudioStartupState extends ChangeNotifier {
  BackgroundAudioHandler? handler;

  void attach(BackgroundAudioHandler value) {
    handler = value;
    notifyListeners();
  }
}

final syncEngineProvider = Provider.family<SyncEngine, String>((ref, jobId) {
  final settings = ref.watch(settingsProvider);
  final engine = SyncEngine(wpm: settings.wpm);
  ref.onDispose(engine.dispose);
  return engine;
});

/// Drives `currentSentenceId` from the player position stream.
final currentSentenceProvider = StreamProvider.family<String?, String>((
  ref,
  jobId,
) {
  final engine = ref.watch(syncEngineProvider(jobId));
  return engine.currentSentence;
});

/// The book whose audio is actively playing/paused. Ephemeral (not persisted).
final StateProvider<String?> currentlyPlayingBookIdProvider =
    StateProvider<String?>((ref) => ref.watch(currentlyReadingBookIdProvider));

/// Starts local conversion when the persistent player is pressed before the
/// book has any playable audio queued.
final playbackRequestProvider = StateProvider<Future<void> Function()?>(
  (ref) => null,
);

/// Paces local synthesis while the app is backgrounded (see
/// [BackgroundPacingController]).
final backgroundPacingProvider = Provider<BackgroundPacingController>((ref) {
  // Captured now: a provider cannot be read while it is being disposed.
  final converter = ref.read(embeddedConverterProvider);
  final controller = BackgroundPacingController(converter: () => converter);
  ref.onDispose(controller.dispose);
  return controller;
});

final playbackResumePersistenceProvider = Provider<PlaybackResumePersistence>((
  ref,
) {
  var currentBookId = ref.read(currentlyPlayingBookIdProvider);
  ref.listen<String?>(currentlyPlayingBookIdProvider, (_, next) {
    currentBookId = next;
  });
  final persistence = PlaybackResumePersistence(
    player: ref.watch(globalAudioPlayerProvider),
    preferences: ref.watch(sharedPrefsProvider),
    bookId: () => currentBookId,
  );
  ref.onDispose(persistence.dispose);
  return persistence;
});

/// Singleton audio player for on-device playback. Not keyed by jobId — this
/// Flutter app runs everything locally, so one player instance suffices.
/// Typed as the interface so tests can substitute a fake player.
final globalAudioPlayerProvider = Provider<AudioPlayerInterface>((ref) {
  final settings = ref.read(settingsProvider);
  final p = AudioPlayerService();
  p.seekForwardSeconds = settings.seekForwardSeconds;
  p.seekBackwardSeconds = settings.seekBackwardSeconds;
  ref.listen(
    settingsProvider.select(
      (settings) => (settings.seekForwardSeconds, settings.seekBackwardSeconds),
    ),
    (_, intervals) {
      p.seekForwardSeconds = intervals.$1;
      p.seekBackwardSeconds = intervals.$2;
    },
  );
  ref.listen(settingsProvider.select((settings) => settings.audioRate), (
    _,
    rate,
  ) {
    p.setSpeed(rate);
  });
  ref.onDispose(p.dispose);
  return p;
});

/// Immutable playback state consumed by every Flutter playback surface.
final playbackCoordinatorProvider = Provider<PlaybackCoordinator>((ref) {
  final coordinator = PlaybackCoordinator(ref.watch(globalAudioPlayerProvider));
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

/// Android MediaSession adapter. Null on desktop/iOS and in host tests.
final audioStartupStateProvider = ChangeNotifierProvider<AudioStartupState>(
  (ref) => AudioStartupState(),
);

final backgroundAudioHandlerProvider = Provider<BackgroundAudioHandler?>(
  (ref) => ref.watch(audioStartupStateProvider).handler,
);
