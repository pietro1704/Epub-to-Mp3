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
