import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n/app_localizations.dart';
import 'screens/library_screen.dart' show libraryStoreProvider;
import 'screens/root_screen.dart';
import 'services/offline_cache_eviction.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  // Run LRU+TTL eviction on every app launch (background, best-effort).
  unawaited(OfflineCacheEviction.runEviction());

  runApp(ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: const EpubToMp3App(),
  ));
}

class EpubToMp3App extends ConsumerWidget {
  const EpubToMp3App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      themeMode: settings.darkMode ? ThemeMode.dark : ThemeMode.light,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const RootScreen(),
    );
  }
}
