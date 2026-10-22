part of 'full_player_sheet.dart';

/// Sheet presenting chapters from the player queue for in-player navigation.
/// Mirrors iOS ChapterListSheet.
class PlayerChapterList extends StatelessWidget {
  const PlayerChapterList({required this.chapters, required this.player});

  final List<ChapterProgress> chapters;
  final AudioPlayerInterface player;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 8, bottom: 8),
            decoration: BoxDecoration(
              color: Colors.grey[400],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text(
                  t?.tocTitle ?? 'Chapters',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(t?.done ?? 'Done'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: StreamBuilder<int?>(
              stream: player.currentIndex,
              builder: (context, snap) {
                final currentPlayerIdx = snap.data;
                final currentChapterIdx = currentPlayerIdx != null
                    ? player.chapterIndexForPlayerIndex(currentPlayerIdx)
                    : -1;

                return ListView.separated(
                  itemCount: chapters.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 16),
                  itemBuilder: (context, i) {
                    final chapter = chapters[i];
                    final isCurrent =
                        chapter.index == currentChapterIdx ||
                        i == currentChapterIdx;
                    return Semantics(
                      label: chapter.displayTitle,
                      button: true,
                      child: ListTile(
                        title: Text(
                          chapter.displayTitle,
                          style: TextStyle(
                            color: isCurrent ? cs.primary : null,
                            fontWeight: isCurrent
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                        trailing: isCurrent
                            ? Icon(Icons.volume_up, size: 16, color: cs.primary)
                            : null,
                        onTap: () {
                          player.seek(Duration.zero, index: i);
                          Navigator.pop(context);
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
