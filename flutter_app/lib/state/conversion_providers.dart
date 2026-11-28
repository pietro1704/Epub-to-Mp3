part of 'providers.dart';

// Embedded converter access and local conversion history.

final embeddedConverterProvider = Provider<EmbeddedConverter>((ref) {
  return EmbeddedConverterRegistry.current;
});

final ttsCatalogProvider = FutureProvider.autoDispose<TtsCatalog>(
  (ref) async {
    final converter = ref.watch(embeddedConverterProvider);
    final pending = ref.keepAlive();
    try {
      return TtsCatalog.decode(await converter.ttsModels());
    } finally {
      pending.close();
    }
  },
  retry: (_, _) => null,
);

/// The user's explicit narration per book language, written only by the Models
/// screen. Persisted as `languageModelChoices.v1`.
final languageModelChoicesProvider =
    StateNotifierProvider<LanguageModelChoicesNotifier, LanguageModelChoices>((
      ref,
    ) {
      return LanguageModelChoicesNotifier(ref.watch(sharedPrefsProvider));
    });

class LanguageModelChoicesNotifier extends StateNotifier<LanguageModelChoices> {
  LanguageModelChoicesNotifier(this._prefs)
    : super(
        LanguageModelChoices.parse(
          _prefs.getString(LanguageModelChoices.storageKey),
        ),
      );

  final SharedPreferences _prefs;

  void choose(String language, TtsSelection selection) =>
      _save(state.withChoice(language, selection));

  /// Back to automatic for [language].
  void clear(String language) => _save(state.without(language));

  void _save(LanguageModelChoices next) {
    if (identical(next, state)) return;
    state = next;
    _prefs.setString(LanguageModelChoices.storageKey, next.encode());
  }
}

/// Languages the platform's own speech engine can read; enumerated once per run.
final systemVoiceLanguagesProvider = FutureProvider<List<String>>(
  (ref) => enumerateSystemVoiceLanguages(),
);

final bookLanguageCacheProvider = Provider<BookLanguageCache>((ref) {
  return BookLanguageCache(ref.watch(sharedPrefsProvider));
});

final showLowQualityModelsProvider = StateProvider<bool>((ref) => false);

final ttsModelRootProvider = FutureProvider.autoDispose<String>((ref) async {
  final directory = await getApplicationSupportDirectory();
  return '${directory.path}/tts-models';
});

final manualLowCatalogProvider = FutureProvider.autoDispose<TtsCatalog?>(
  (ref) async {
    if (!ref.watch(showLowQualityModelsProvider)) return null;
    final converter = ref.watch(embeddedConverterProvider);
    if (converter is! ManualTtsModelCatalog) return null;
    final root = await ref.watch(ttsModelRootProvider.future);
    return TtsCatalog.decodeManual(
      await (converter as ManualTtsModelCatalog).ttsManualModels(root: root),
    );
  },
  retry: (_, _) => null,
);

/// Reload persisted local history when entering Jobs, including after a
/// conversion finishes while the IndexedStack keeps the tab mounted.
final localConversionJobStoreProvider = Provider<LocalConversionJobStore>((
  ref,
) {
  return LocalConversionJobStore(ref.watch(sharedPrefsProvider));
});

final localConversionHistoryProvider = FutureProvider<LocalConversionHistory>((
  ref,
) {
  ref.watch(
    appDestinationProvider.select(
      (destination) => destination == AppDestination.history,
    ),
  );
  return ref.watch(localConversionJobStoreProvider).loadHistory();
});

/// One-shot request created by a Library long-press to download the full book.
final manualDownloadRequestProvider = StateProvider<String?>((ref) => null);

/// The voice sample service: Rust renders a short MP3 (FFI on desktop, JNI on Android) and a
/// dedicated player plays it, apart from the book playback session. Null where unsupported.
final voiceAuditionProvider = Provider<VoiceAudition?>((ref) {
  final converter = ref.watch(embeddedConverterProvider);
  final AuditionRender? render = converter is DesktopEmbeddedConverter
      ? converter.voiceAuditionRender
      : (Platform.isAndroid
            ? androidVoiceAuditionRender(
                const MethodChannel('epub_to_mp3/embedded_converter'),
              )
            : null);
  if (render == null) return null;
  final player = AudioPlayer();
  ref.onDispose(player.dispose);
  return VoiceAudition(
    render: render,
    play: (path) async {
      await player.setFilePath(path);
      unawaited(player.play());
    },
    stopPlayback: player.stop,
  );
});
