part of 'convert_screen.dart';

/// What follows a finished manual conversion: add the book to the library with its audio
/// linked, or export the audio (MP3, chosen layout and folder). Nothing happens automatically.
class ManualConversionActions extends ConsumerStatefulWidget {
  const ManualConversionActions({
    super.key,
    required this.filePath,
    required this.bookId,
    required this.jobId,
    this.exporter,
    this.chooseFolder,
  });

  final String filePath;
  final String bookId;
  final String jobId;
  final AudioExporter? exporter;

  /// Native folder picker; defaults to the platform one.
  final Future<String?> Function()? chooseFolder;

  @override
  ConsumerState<ManualConversionActions> createState() =>
      _ManualConversionActionsState();
}

class _ManualConversionActionsState
    extends ConsumerState<ManualConversionActions> {
  late final Future<LocalConversionJob?> _job = ref
      .read(localConversionJobStoreProvider)
      .load(widget.bookId, widget.jobId);
  bool _added = false;

  bool get _inLibrary =>
      _added ||
      ref
          .read(libraryStoreProvider)
          .books
          .any((book) => book.filePath == widget.filePath);

  Future<void> _addToLibrary(LocalConversionJob? job) async {
    final t = AppLocalizations.of(context)!;
    final store = ref.read(libraryStoreProvider);
    try {
      final book = await store.importBook(widget.filePath);
      if (job != null) {
        // The reader plays the job saved as local-<book id>; point it at this audio.
        final linkedId = 'local-${book.id}';
        await ref
            .read(localConversionJobStoreProvider)
            .save(job.copyWith(bookId: book.id, jobId: linkedId));
        book.lastJobId = linkedId;
        store.update(book);
      }
      if (!mounted) return;
      setState(() => _added = true);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.manualAddedToLibrary)));
    } on Exception catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _export(List<AudioExportChapter> chapters) async {
    final t = AppLocalizations.of(context)!;
    final layout = await showDialog<AudioExportLayout>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(t.manualExportAudio),
        children: [
          SimpleDialogOption(
            key: const ValueKey('export-single'),
            onPressed: () => Navigator.pop(context, AudioExportLayout.single),
            child: Text(t.manualExportOneFile),
          ),
          SimpleDialogOption(
            key: const ValueKey('export-per-chapter'),
            onPressed: () =>
                Navigator.pop(context, AudioExportLayout.perChapter),
            child: Text(t.manualExportPerChapter),
          ),
        ],
      ),
    );
    if (layout == null || !mounted) return;
    final destination =
        await (widget.chooseFolder ??
            () => FilePicker.getDirectoryPath(
              dialogTitle: t.manualExportChooseFolder,
            ))();
    if (destination == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final book = ref
          .read(libraryStoreProvider)
          .books
          .where((book) => book.filePath == widget.filePath)
          .firstOrNull;
      final files = await (widget.exporter ?? AudioExporter()).export(
        destination: destination,
        layout: layout,
        title: book?.title ?? _stem(widget.filePath),
        author: book?.author,
        chapters: chapters,
      );
      messenger.showSnackBar(
        SnackBar(content: Text(t.manualExportDone(files.length))),
      );
    } on Exception {
      messenger.showSnackBar(SnackBar(content: Text(t.manualExportFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return FutureBuilder<LocalConversionJob?>(
      future: _job,
      builder: (context, snapshot) {
        final job = snapshot.data;
        final chapters = mp3ExportChapters([
          for (final path in availableAudioPaths(job))
            AudioExportChapter(
              title: job!.chapters
                  .firstWhere((chapter) => chapter.outputPath == path)
                  .name,
              path: path,
            ),
        ]);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            if (!_inLibrary)
              OutlinedButton.icon(
                key: const ValueKey('manual-add-to-library'),
                onPressed: () => _addToLibrary(job),
                icon: const Icon(Icons.library_add_outlined),
                label: Text(t.manualAddToLibrary),
              ),
            if (job != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('manual-export-audio'),
                onPressed: chapters.isEmpty ? null : () => _export(chapters),
                icon: const Icon(Icons.ios_share),
                label: Text(t.manualExportAudio),
              ),
              if (chapters.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    t.manualExportNeedsPiper,
                    key: const ValueKey('manual-export-needs-piper'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

String _stem(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}
