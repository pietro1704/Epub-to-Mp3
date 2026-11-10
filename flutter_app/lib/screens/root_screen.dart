import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design_system/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../state/providers.dart';
import '../views/mini_player_bar.dart';
import 'library_screen.dart';
import 'reader_tab.dart';
import 'settings_screen.dart';
import 'convert_screen.dart';
import 'jobs_list_screen.dart';

/// Owns compact/expanded navigation and the reader's complete chrome.
class RootScreen extends ConsumerWidget {
  const RootScreen({super.key});

  static const destinations = [
    AppDestination.library,
    AppDestination.settings,
    AppDestination.conversion,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final destination = ref.watch(appDestinationProvider);
    final book = ref.watch(currentlyReadingBookIdProvider);
    final reader = destination == AppDestination.reader && book != null;
    final chromeVisible = !reader || ref.watch(readerChromeVisibleProvider);
    ref.watch(playbackResumePersistenceProvider);
    final selected = destinations.indexOf(destination);
    final labels = [t.libraryTitle, t.settingsTitle, t.convertTitle];
    const icons = [
      Icons.library_books_outlined,
      Icons.settings_outlined,
      Icons.auto_fix_high,
    ];
    final shellIndex = selected < 0 ? 2 : selected;

    void select(int index) {
      ref.read(appDestinationProvider.notifier).state = destinations[index];
    }

    final content = Column(
      children: [
        Expanded(
          child: IndexedStack(
            index: reader
                ? 3
                : destination == AppDestination.history
                ? 4
                : shellIndex,
            children: [
              const LibraryScreen(),
              const SettingsScreen(),
              const ConvertScreen(),
              if (book != null) const ReaderTab() else const SizedBox.shrink(),
              const JobsListScreen(),
            ],
          ),
        ),
        if (chromeVisible) const MiniPlayerBar(),
      ],
    );

    return PopScope(
      canPop: !reader && destination != AppDestination.history,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          ref.read(appDestinationProvider.notifier).state = reader
              ? AppDestination.library
              : AppDestination.conversion;
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final expanded = constraints.maxWidth >= AppTheme.expandedWidth;
          return Scaffold(
            body: Row(
              children: [
                if (expanded && !reader)
                  NavigationRail(
                    key: const ValueKey('tablet-navigation'),
                    extended: constraints.maxWidth >= 1000,
                    selectedIndex: shellIndex,
                    onDestinationSelected: select,
                    labelType: constraints.maxWidth >= 1000
                        ? NavigationRailLabelType.none
                        : NavigationRailLabelType.all,
                    destinations: [
                      for (var i = 0; i < labels.length; i++)
                        NavigationRailDestination(
                          icon: Icon(icons[i]),
                          label: Text(labels[i]),
                        ),
                    ],
                  ),
                Expanded(child: content),
              ],
            ),
            bottomNavigationBar: expanded || reader
                ? null
                : CupertinoTabBar(
                    key: const ValueKey('phone-navigation'),
                    currentIndex: shellIndex,
                    onTap: select,
                    items: [
                      for (var i = 0; i < labels.length; i++)
                        BottomNavigationBarItem(
                          icon: Icon(icons[i]),
                          label: labels[i],
                        ),
                    ],
                  ),
          );
        },
      ),
    );
  }
}
