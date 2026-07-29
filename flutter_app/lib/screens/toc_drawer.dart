import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/ebook_fulltext.dart';
import '../models/job_snapshot.dart';

class TocDrawer extends StatelessWidget {
  const TocDrawer({
    super.key,
    required this.fulltext,
    required this.snapshot,
    required this.currentIndex,
    required this.onJump,
  });

  final EbookFulltext? fulltext;
  final JobSnapshot? snapshot;
  final int currentIndex;
  final void Function(int chapterIndex) onJump;

  ChapterProgress? _progressFor(int index) {
    final progress = snapshot?.chapterProgress;
    if (progress == null) return null;
    return progress.cast<ChapterProgress?>().firstWhere(
      (c) => c!.index == index,
      orElse: () => null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final chapters =
        fulltext?.chapters ??
        snapshot?.chapterProgress
            ?.map(
              (c) => FulltextChapter(index: c.index, name: c.name, text: ''),
            )
            .toList() ??
        const <FulltextChapter>[];

    final cs = Theme.of(context).colorScheme;

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                AppLocalizations.of(context)?.tocTitle ?? 'Chapters',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: chapters.length,
                itemBuilder: (context, i) {
                  final c = chapters[i];
                  final isCurrent = i == currentIndex;
                  final progress = _progressFor(c.index);
                  final hasAudio = progress?.downloadUrl != null;
                  final isConverting = progress?.status == 'converting';
                  final charCount = c.text.trim().length;

                  return Semantics(
                    label: c.displayTitle,
                    liveRegion: isCurrent,
                    child: ListTile(
                      selected: isCurrent,
                      selectedTileColor: cs.primaryContainer.withValues(
                        alpha: 0.3,
                      ),
                      leading: _buildLeading(
                        context,
                        isCurrent: isCurrent,
                        hasAudio: hasAudio,
                        isConverting: isConverting,
                      ),
                      title: Text(
                        c.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: isCurrent
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      subtitle: charCount > 0
                          ? Text(
                              _formatCharCount(charCount),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            )
                          : null,
                      trailing: hasAudio
                          ? Icon(
                              Icons.check_circle,
                              size: 18,
                              color: cs.primary,
                            )
                          : null,
                      onTap: () {
                        Navigator.of(context).pop();
                        onJump(i);
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeading(
    BuildContext context, {
    required bool isCurrent,
    required bool hasAudio,
    required bool isConverting,
  }) {
    final cs = Theme.of(context).colorScheme;
    if (isCurrent) {
      return Icon(Icons.play_arrow, color: cs.primary);
    }
    if (isConverting) {
      return SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
      );
    }
    return Icon(
      hasAudio ? Icons.headphones : Icons.menu_book_outlined,
      color: cs.onSurfaceVariant,
    );
  }

  String _formatCharCount(int chars) {
    if (chars >= 1000) {
      return '${(chars / 1000).toStringAsFixed(1)}k chars';
    }
    return '$chars chars';
  }
}
