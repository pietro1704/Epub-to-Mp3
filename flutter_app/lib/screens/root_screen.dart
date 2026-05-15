import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'library_screen.dart';
import 'settings_screen.dart';

/// Top-level shell with a BottomNavigationBar.
/// Mirrors the iOS TabRoot: Library (default), Reader placeholder, Settings.
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tabIndex = 0;

  static const _screens = <Widget>[
    LibraryScreen(),
    _ReaderPlaceholder(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      body: IndexedStack(index: _tabIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.library_books_outlined),
            selectedIcon: const Icon(Icons.library_books),
            label: t.libraryTitle,
          ),
          NavigationDestination(
            icon: const Icon(Icons.menu_book_outlined),
            selectedIcon: const Icon(Icons.menu_book),
            label: t.readerTitle,
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: t.settingsTitle,
          ),
        ],
      ),
    );
  }
}

/// Placeholder until a book is opened from the library.
class _ReaderPlaceholder extends StatelessWidget {
  const _ReaderPlaceholder();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(t.readerTitle)),
      body: Center(
        child: Text(
          t.readerEmptyHint,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    );
  }
}
