import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state/providers.dart';
import '../../screens/library_screen.dart' show libraryStoreProvider;
import '../../services/local_conversion_job.dart';
import 'local_audio_storage.dart';

class LocalAudioStorageScreen extends ConsumerStatefulWidget {
  const LocalAudioStorageScreen({super.key});
  @override
  ConsumerState<LocalAudioStorageScreen> createState() =>
      _LocalAudioStorageState();
}

class _LocalAudioStorageState extends ConsumerState<LocalAudioStorageScreen> {
  late final Future<LocalAudioStorage> _storage;
  late Future<List<LocalAudioEntry>> _entries;
  @override
  void initState() {
    super.initState();
    _storage = getApplicationDocumentsDirectory().then(LocalAudioStorage.new);
    _entries = _storage.then((storage) => storage.scan());
  }

  Future<void> _remove(LocalAudioEntry entry) async {
    final t = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.removeAudioTitle),
        content: Text(t.removeAudioMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.remove),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final history = await ref
          .read(localConversionJobStoreProvider)
          .loadHistory();
      if (!mounted) return;
      final player = ref.read(globalAudioPlayerProvider);
      final active = <String>{
        if (player.currentBookId != null) player.currentBookId!,
        for (final book
            in ref
                .read(libraryStoreProvider)
                .books
                .where((book) => book.id == player.currentBookId))
          if (book.lastJobId != null) book.lastJobId!,
        for (final job in history.jobs.where(
          (job) => ![
            LocalConversionJobStatus.completed,
            LocalConversionJobStatus.failed,
            LocalConversionJobStatus.cancelled,
          ].contains(job.status),
        )) ...[job.bookId, job.jobId],
      };
      final storage = await _storage;
      if (await storage.remove(entry, activeIds: active)) {
        final library = ref.read(libraryStoreProvider);
        for (final book in library.books.where(
          (book) => book.id == entry.id || book.lastJobId == entry.id,
        )) {
          book.cachedOffline = false;
          library.update(book);
        }
      }
      if (mounted) setState(() => _entries = storage.scan());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t.errorWithMessage('$error'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final books = ref.watch(libraryStoreProvider).books;
    return Scaffold(
      appBar: AppBar(title: Text(t.localAudioStorage)),
      body: FutureBuilder<List<LocalAudioEntry>>(
        future: _entries,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text(t.errorWithMessage('${snapshot.error}')));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snapshot.data!;
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(t.localAudioStorageHint),
              ),
              for (final entry in entries)
                ListTile(
                  title: Text(
                    books
                            .where(
                              (book) =>
                                  book.id == entry.id ||
                                  book.lastJobId == entry.id,
                            )
                            .firstOrNull
                            ?.resolvedTitle ??
                        entry.id,
                  ),
                  subtitle: Text(
                    '${(entry.bytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                  ),
                  trailing: IconButton(
                    tooltip: t.remove,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _remove(entry),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
