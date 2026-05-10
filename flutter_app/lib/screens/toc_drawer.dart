import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    final chapters = fulltext?.chapters ??
        snapshot?.chapterProgress
            ?.map((c) => FulltextChapter(
                  index: c.index,
                  name: c.name,
                  text: '',
                ))
            .toList() ??
        const <FulltextChapter>[];
    return Drawer(
      child: SafeArea(
        child: ListView.builder(
          itemCount: chapters.length,
          itemBuilder: (context, i) {
            final c = chapters[i];
            return ListTile(
              leading: Icon(
                i == currentIndex
                    ? Icons.play_arrow
                    : Icons.menu_book_outlined,
              ),
              title: Text(c.displayTitle),
              onTap: () {
                Navigator.of(context).pop();
                onJump(i);
              },
            );
          },
        ),
      ),
    );
  }
}
