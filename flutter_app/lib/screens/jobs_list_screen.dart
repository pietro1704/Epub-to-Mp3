import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../services/local_conversion_job.dart';
import '../services/embedded_converter.dart';
import '../state/providers.dart';
import 'library_screen.dart' show libraryStoreProvider;
import 'conversion_log_screen.dart';
import 'settings_screen.dart';

class JobsListScreen extends ConsumerWidget {
  const JobsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final history = ref.watch(localConversionHistoryProvider);
    final books = ref.watch(libraryStoreProvider).books;
    // Rust log lookup currently has the correct app-specific storage context
    // only through Android's native adapter. Local history works on all targets.
    final canReadRustLog =
        ref.watch(embeddedConverterProvider) is AndroidEmbeddedConverter;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.jobsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(localConversionHistoryProvider);
          await ref.read(localConversionHistoryProvider.future);
        },
        child: history.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [ListTile(title: Text(t.errorWithMessage('$e')))],
          ),
          data: (history) {
            final list = history.jobs;
            if (list.isEmpty && history.unreadableKeys.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [ListTile(title: Text(t.noJobs))],
              );
            }
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: list.length + (history.unreadableKeys.isEmpty ? 0 : 1),
              // ignore: unnecessary_underscores
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                if (history.unreadableKeys.isNotEmpty && i == 0) {
                  return ExpansionTile(
                    leading: const Icon(Icons.warning_amber_outlined),
                    title: Text(
                      t.conversionUnreadableRecords(
                        history.unreadableKeys.length,
                      ),
                    ),
                    children: [
                      SelectableText(history.unreadableKeys.join('\n')),
                    ],
                  );
                }
                if (history.unreadableKeys.isNotEmpty) i--;
                final s = list[i];
                final matchingBooks = books.where(
                  (book) => book.id == s.bookId,
                );
                final title = matchingBooks.isEmpty
                    ? s.bookTitle ?? s.bookId
                    : matchingBooks.first.resolvedTitle;
                return ListTile(
                  title: Text(title),
                  trailing: canReadRustLog
                      ? IconButton(
                          tooltip: t.conversionLogTitle,
                          icon: const Icon(Icons.article_outlined),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  ConversionLogScreen(jobId: s.jobId),
                            ),
                          ),
                        )
                      : null,
                  subtitle: Text(
                    '${t.conversionLastRecordedStateValue(_recordedStatus(t, s.status.name))} • ${s.updatedAt.toLocal()}',
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _LocalJobDetailScreen(
                          job: s,
                          title: title,
                          canReadRustLog: canReadRustLog,
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// A persisted record is a history snapshot, not proof of a live conversion or
/// of audio availability. Keep its identity, failures and output paths intact.
class _LocalJobDetailScreen extends StatelessWidget {
  const _LocalJobDetailScreen({
    required this.job,
    required this.title,
    required this.canReadRustLog,
  });
  final LocalConversionJob job;
  final String title;
  final bool canReadRustLog;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: Text(t.conversionJobLabel),
            subtitle: SelectableText(job.jobId),
          ),
          ListTile(
            title: Text(t.conversionLastRecordedState),
            subtitle: Text(_recordedStatus(t, job.status.name)),
          ),
          ListTile(
            title: Text(t.conversionLastUpdated),
            subtitle: Text(job.updatedAt.toLocal().toString()),
          ),
          if (job.usedSelections.isNotEmpty)
            ListTile(
              title: Text(t.ttsActualVoices(
                job.usedSelections.map((selection) => selection.displayName).join(', '),
              )),
            ),
          if (job.fallbackUsed)
            ListTile(title: Text(t.ttsSecondaryUsedNotice)),
          if (job.error != null)
            ListTile(
              leading: const Icon(Icons.error_outline),
              title: Text(job.error!),
            ),
          ListTile(
            title: Text(
              t.chaptersConverted(
                job.chapters
                    .where((chapter) => chapter.status == 'completed')
                    .length,
                job.chapters.length,
              ),
            ),
          ),
          for (final chapter in job.chapters)
            ListTile(
              title: Text(chapter.name),
              subtitle: Text(
                [
                  t.conversionLastRecordedStateValue(
                    _recordedStatus(t, chapter.status),
                  ),
                  if (chapter.error != null) chapter.error!,
                  if (chapter.outputPath != null)
                    t.conversionRecordedAudioPath(chapter.outputPath!),
                ].join('\n'),
              ),
            ),
          if (canReadRustLog)
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ConversionLogScreen(jobId: job.jobId),
                ),
              ),
              icon: const Icon(Icons.article_outlined),
              label: Text(t.conversionLogTitle),
            ),
        ],
      ),
    );
  }
}

String _recordedStatus(AppLocalizations t, String status) => switch (status) {
  'pending' => t.conversionStatusPending,
  'running' => t.conversionStatusRunning,
  'completed' => t.conversionStatusCompleted,
  'failed' => t.conversionStatusFailed,
  'cancelled' => t.conversionStatusCancelled,
  _ => t.conversionStatusUnknown,
};
