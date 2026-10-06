import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n/app_localizations.dart';
import 'screens/library_screen.dart' show libraryStoreProvider;
import 'screens/root_screen.dart';
import 'services/audio_player_service.dart';
import 'services/background_audio_handler.dart';
import 'services/app_deep_link.dart';
import 'services/incoming_document_service.dart';
import 'services/widget_playback_snapshot.dart';
import 'models/app_settings.dart';
import 'services/offline_cache_eviction.dart';
import 'state/providers.dart';
import 'services/embedded_converter.dart';
import 'services/tts_model_adapter_registry.dart';
import 'views/reader_theme_colors.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Register the Android platform adapter before Riverpod can resolve the
  // embedded converter. Without this registration, opening a book fails with
  // "converter-ffi runtime is not registered" even though the channel exists.
  if (defaultTargetPlatform == TargetPlatform.android) {
    EmbeddedConverterRegistry.register(AndroidEmbeddedConverter());
    final converter = EmbeddedConverterRegistry.current;
    if (converter is AndroidEmbeddedConverter) {
      unawaited(converter.isRuntimeLoaded());
    }
  }
  if (defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows) {
    // Desktop model management uses the same Rust catalog and ABI as mobile.
    // Conversion registration remains separate until the desktop native
    // conversion bridge is available for that target.
    TtsModelAdapterRegistry.enableDesktop();
  }
  // Render the shell before any disk/plugin initialization. Android 9 devices
  // must not remain on the launch window while SharedPreferences is opening.
  runApp(const _StartupShell());
  final prefs = await SharedPreferences.getInstance();

  // Match the native reader's default without changing the shared settings
  // model: existing explicit choices remain untouched, while new installs
  // open books in paginated mode.
  if (!prefs.containsKey('readerLayout')) {
    await prefs.setString('readerLayout', 'paginated');
  }
  final deepLinkStream = defaultTargetPlatform == TargetPlatform.android
      ? const EventChannel(
          'epub_to_mp3/deep_links',
        ).receiveBroadcastStream().map((event) => Uri.parse(event as String))
      : const Stream<Uri>.empty();
  final deepLinks = AppDeepLinkService(deepLinkStream);
  final audioStartup = AudioStartupState();
  final sharedPlayer = defaultTargetPlatform == TargetPlatform.android
      ? AudioPlayerService(backendBase: MirrorAppSettings(prefs).backendURL)
      : null;

  // Run LRU+TTL eviction on every app launch (background, best-effort).
  unawaited(OfflineCacheEviction.runEviction());

  runApp(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        audioStartupStateProvider.overrideWith((ref) => audioStartup),
        if (sharedPlayer != null)
          globalAudioPlayerProvider.overrideWithValue(sharedPlayer),
      ],
      child: EpubToMp3App(deepLinks: deepLinks),
    ),
  );

  if (sharedPlayer != null) {
    unawaited(_initializeAndroidAudio(sharedPlayer, prefs, audioStartup));
  }
}

Future<void> _initializeAndroidAudio(
  AudioPlayerService player,
  SharedPreferences prefs,
  AudioStartupState state,
) async {
  try {
    final handler = await AudioService.init(
      builder: () => BackgroundAudioHandler(
        player,
        snapshotStore: WidgetPlaybackSnapshotStore(prefs),
      ),
      config: AudioServiceConfig(
        androidNotificationChannelId: 'com.pietrocode.epubtomp3.audio',
        androidNotificationChannelName: 'Audiobook playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidNotificationClickStartsActivity: true,
        androidResumeOnClick: true,
      ),
    );
    state.attach(handler);
  } catch (_) {
    // MediaSession is an enhancement. The in-app player remains available
    // when Android rejects or cannot start the background service.
  }
}

class _StartupShell extends StatelessWidget {
  const _StartupShell();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: Center(child: CircularProgressIndicator())),
    );
  }
}

class EpubToMp3App extends ConsumerStatefulWidget {
  const EpubToMp3App({super.key, required this.deepLinks});

  final AppDeepLinkService deepLinks;

  @override
  ConsumerState<EpubToMp3App> createState() => _EpubToMp3AppState();
}

class _EpubToMp3AppState extends ConsumerState<EpubToMp3App> {
  late final IncomingDocumentService _incomingDocuments;
  StreamSubscription<AppDeepLink>? _deepLinkSubscription;

  @override
  void initState() {
    super.initState();
    _incomingDocuments = IncomingDocumentService(
      importCallback: (document) async {
        final library = ref.read(libraryStoreProvider);
        final book = await library.importBook(
          document.path,
          displayFilename: document.displayName,
        );
        ref.read(currentlyReadingBookIdProvider.notifier).set(book.id);
        ref.read(rootTabIndexProvider.notifier).state = 0;
      },
    );
    _deepLinkSubscription = widget.deepLinks.links.listen(_routeDeepLink);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_incomingDocuments.start());
    });
  }

  @override
  void dispose() {
    unawaited(_incomingDocuments.dispose());
    unawaited(_deepLinkSubscription?.cancel());
    unawaited(widget.deepLinks.dispose());
    super.dispose();
  }

  void _routeDeepLink(AppDeepLink link) {
    if (link.action == AppDeepLinkAction.jobs) {
      ref.read(rootTabIndexProvider.notifier).state = 3;
      return;
    }
    final bookId = link.bookId;
    if (bookId == null ||
        !ref
            .read(libraryStoreProvider)
            .books
            .any((book) => book.id == bookId)) {
      return;
    }
    if (link.action == AppDeepLinkAction.open) {
      ref.read(currentlyReadingBookIdProvider.notifier).set(bookId);
    } else {
      ref.read(currentlyPlayingBookIdProvider.notifier).state = bookId;
    }
    ref.read(rootTabIndexProvider.notifier).state = 0;
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final settings = ref.watch(settingsProvider);
    // One-shot historical-orphan prune: bookmarks created before the
    // cascade-on-delete wiring (or surviving a manual prefs edit) could
    // reference books that no longer exist in the library. Drop them
    // once per process start so they don't accumulate in SharedPrefs.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final library = ref.read(libraryStoreProvider);
      final bookmarks = ref.read(bookmarkStoreProvider);
      bookmarks.pruneOrphans(library.books.map((b) => b.id));
    });
    return MaterialApp(
      onGenerateTitle: (ctx) => AppLocalizations.of(ctx)!.appTitle,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ReaderThemeColors.themeMode(settings.readerTheme),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const RootScreen(),
    );
  }
}
