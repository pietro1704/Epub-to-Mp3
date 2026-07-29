import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../state/providers.dart';
import '../views/mini_player_bar.dart';
import 'library_screen.dart';
import 'reader_tab.dart';
import 'settings_screen.dart';
import 'convert_screen.dart';
import 'jobs_list_screen.dart';

/// Top-level shell with a BottomNavigationBar + persistent MiniPlayerBar.
/// Tab order mirrors the iOS workflow: Reader, Library, Convert, Jobs, Settings.
class RootScreen extends ConsumerWidget {
  const RootScreen({super.key});

  static const _screens = <Widget>[
    ReaderTab(),
    LibraryScreen(),
    ConvertScreen(),
    JobsListScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final tabIndex = ref.watch(rootTabIndexProvider);
    final chromeVisible = ref.watch(readerChromeVisibleProvider);
    final showShellChrome = tabIndex != 0 || chromeVisible;

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(index: tabIndex, children: _screens),
          ),
          if (showShellChrome) const MiniPlayerBar(),
        ],
      ),
      bottomNavigationBar: showShellChrome
          ? NavigationBar(
              selectedIndex: tabIndex,
              onDestinationSelected: (i) =>
                  ref.read(rootTabIndexProvider.notifier).state = i,
              destinations: [
                NavigationDestination(
                  icon: const Icon(Icons.menu_book_outlined),
                  selectedIcon: const Icon(Icons.menu_book),
                  label: t.readerTitle,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.library_books_outlined),
                  selectedIcon: const Icon(Icons.library_books),
                  label: t.libraryTitle,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.transform_outlined),
                  selectedIcon: const Icon(Icons.transform),
                  label: t.convertTitle,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.work_outline),
                  selectedIcon: const Icon(Icons.work),
                  label: t.jobsTitle,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.settings_outlined),
                  selectedIcon: const Icon(Icons.settings),
                  label: t.settingsTitle,
                ),
              ],
            )
          : null,
    );
  }
}
