import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../models/book_entity.dart';
import 'public_book_catalog.dart';

class PublicBookDiscoverySheet extends StatefulWidget {
  const PublicBookDiscoverySheet({
    super.key,
    required this.onPickFile,
    required this.onDownload,
  });

  final VoidCallback onPickFile;
  final Future<BookEntity> Function(PublicBook) onDownload;

  @override
  State<PublicBookDiscoverySheet> createState() =>
      _PublicBookDiscoverySheetState();
}

class _PublicBookDiscoverySheetState extends State<PublicBookDiscoverySheet> {
  String _query = '';
  PublicBook? _downloading;
  String? _errorMessage;

  Future<void> _download(PublicBook book) async {
    setState(() {
      _downloading = book;
      _errorMessage = null;
    });
    try {
      final imported = await widget.onDownload(book);
      if (mounted) Navigator.pop(context, imported);
    } on Exception {
      if (mounted) {
        setState(() {
          _errorMessage = AppLocalizations.of(context)!
              .publicBookDownloadFailed;
        });
      }
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
  }

  Future<void> _openSourcePage(String page) async {
    setState(() => _errorMessage = null);
    try {
      if (await launchUrl(
        Uri.parse(page),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } on Exception {
      // Both platform errors and an unavailable browser use the inline message.
    }
    if (mounted) {
      setState(() {
        _errorMessage = AppLocalizations.of(context)!
            .publicBookSourceOpenFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final busy = _downloading != null;
    final books = searchPublicBooks(
      _query,
      Localizations.localeOf(context).languageCode,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: FractionallySizedBox(
        heightFactor: .82,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                title: Text(
                  t.addBook,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                trailing: IconButton(
                  onPressed: busy ? null : () => Navigator.pop(context),
                  tooltip: t.cancel,
                  icon: const Icon(Icons.close),
                ),
              ),
              ListTile(
                onTap: busy ? null : widget.onPickFile,
                leading: const Icon(Icons.folder_open_outlined),
                title: Text(t.importBookFile),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: TextField(
                  enabled: !busy,
                  onChanged: (query) => setState(() {
                    _query = query;
                    _errorMessage = null;
                  }),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    labelText: t.searchPublicBooks,
                  ),
                ),
              ),
              if (_errorMessage case final message?)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: books.isEmpty
                    ? Center(child: Text(t.noResults))
                    : ListView(
                        children: [
                          for (final book in books)
                            ListTile(
                              enabled: !busy,
                              title: Text(book.title),
                              isThreeLine: book.sourcePage != null,
                              subtitle: switch (book.sourcePage) {
                                final page? => Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(book.author),
                                    TextButton(
                                      onPressed: busy
                                          ? null
                                          : () => _openSourcePage(page),
                                      child: Text(book.source),
                                    ),
                                  ],
                                ),
                                null => Text('${book.author} · ${book.source}'),
                              },
                              trailing: _downloading == book
                                  ? Text(t.downloading)
                                  : Text(book.format.name.toUpperCase()),
                              onTap: () => _download(book),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
