import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ebook_fulltext.dart';
import '../state/providers.dart';

/// Scrollable RichText. Highlights the currently spoken sentence and
/// auto-scrolls when it changes.
class ReaderView extends ConsumerStatefulWidget {
  const ReaderView({
    super.key,
    required this.jobId,
    required this.chapter,
  });

  final String jobId;
  final FulltextChapter chapter;

  @override
  ConsumerState<ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends ConsumerState<ReaderView> {
  final _controller = ScrollController();
  final Map<String, GlobalKey> _spanKeys = {};
  String? _lastScrolledTo;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final spans = widget.chapter.splitSentences();
    final activeId = ref.watch(currentSentenceProvider(widget.jobId)).valueOrNull;

    if (activeId != null && activeId != _lastScrolledTo) {
      _lastScrolledTo = activeId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(activeId));
    }

    return Scrollbar(
      controller: _controller,
      child: SingleChildScrollView(
        controller: _controller,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.chapter.name != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(widget.chapter.name!,
                    style: Theme.of(context).textTheme.titleLarge),
              ),
            Wrap(
              children: [
                for (final span in spans)
                  _Sentence(
                    key: _spanKeys.putIfAbsent(span.id, () => GlobalKey()),
                    span: span,
                    fontSize: settings.fontSize,
                    isActive: span.id == activeId,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _scrollTo(String id) {
    final key = _spanKeys[id];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 250),
        alignment: 0.3,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _Sentence extends StatelessWidget {
  const _Sentence({
    super.key,
    required this.span,
    required this.fontSize,
    required this.isActive,
  });

  final SentenceSpan span;
  final double fontSize;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final highlight = Theme.of(context).colorScheme.primaryContainer;
    return Container(
      decoration: isActive
          ? BoxDecoration(
              color: highlight,
              borderRadius: BorderRadius.circular(4),
            )
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: Text(
        '${span.text} ',
        style: TextStyle(fontSize: fontSize, height: 1.5),
      ),
    );
  }
}
