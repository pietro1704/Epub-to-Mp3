import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/ebook_fulltext.dart';

/// Search result with chapter context and match highlight info.
class _SearchResult {
  final int chapterIndex;
  final String chapterTitle;
  final String snippet;
  final int matchStart;
  final int matchLength;

  const _SearchResult({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.snippet,
    required this.matchStart,
    required this.matchLength,
  });
}

/// Material 3 search overlay for in-reader full-text search.
///
/// Slides in from the top over the reader content. Results show
/// chapter title + context snippet with highlighted match. Capped
/// at 100 results to keep performance bounded (same as iOS).
class ReaderSearchOverlay extends StatefulWidget {
  const ReaderSearchOverlay({
    super.key,
    required this.chapters,
    required this.onJumpToChapter,
    required this.onClose,
  });

  final List<FulltextChapter> chapters;
  final void Function(int chapterIndex) onJumpToChapter;
  final VoidCallback onClose;

  @override
  State<ReaderSearchOverlay> createState() => _ReaderSearchOverlayState();
}

class _ReaderSearchOverlayState extends State<ReaderSearchOverlay>
    with SingleTickerProviderStateMixin {
  static const _maxResults = 100;

  late final AnimationController _animController;
  late final Animation<Offset> _slideAnimation;
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  List<_SearchResult> _results = [];
  bool _hasSearched = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero).animate(
          CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
        );
    _animController.forward();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _animController.dispose();
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _search() {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _results = [];
        _hasSearched = false;
      });
      return;
    }
    final lowered = query.toLowerCase();
    final found = <_SearchResult>[];

    for (final ch in widget.chapters) {
      final text = ch.text;
      final lower = text.toLowerCase();
      var searchStart = 0;
      while (true) {
        final idx = lower.indexOf(lowered, searchStart);
        if (idx == -1) break;

        // Build context snippet: 40 chars before and after.
        final snippetStart = (idx - 40).clamp(0, text.length);
        final snippetEnd = (idx + lowered.length + 40).clamp(0, text.length);
        final raw = text
            .substring(snippetStart, snippetEnd)
            .replaceAll('\n', ' ');
        final snippet =
            '${snippetStart > 0 ? '...' : ''}'
            '$raw'
            '${snippetEnd < text.length ? '...' : ''}';

        // Compute match offset within the snippet string.
        final prefixLen = snippetStart > 0 ? 3 : 0; // '...' length
        final matchInSnippet = idx - snippetStart + prefixLen;

        found.add(
          _SearchResult(
            chapterIndex: ch.index,
            chapterTitle: ch.displayTitle,
            snippet: snippet,
            matchStart: matchInSnippet,
            matchLength: lowered.length,
          ),
        );

        searchStart = idx + lowered.length;
        if (found.length >= _maxResults) break;
      }
      if (found.length >= _maxResults) break;
    }

    setState(() {
      _results = found;
      _hasSearched = true;
    });
  }

  void _clear() {
    _searchController.clear();
    setState(() {
      _results = [];
      _hasSearched = false;
    });
  }

  Future<void> _close() async {
    await _animController.reverse();
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return SlideTransition(
      position: _slideAnimation,
      child: Semantics(
        label: t.searchInBook,
        container: true,
        child: Material(
          color: cs.surface,
          elevation: 4,
          surfaceTintColor: cs.surfaceTint,
          child: SafeArea(
            bottom: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Search bar row
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    children: [
                      Icon(Icons.search, color: cs.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          focusNode: _focusNode,
                          decoration: InputDecoration(
                            hintText: t.searchInBook,
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            isDense: true,
                          ),
                          textInputAction: TextInputAction.search,
                          autocorrect: false,
                          onSubmitted: (_) => _search(),
                        ),
                      ),
                      if (_searchController.text.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: _clear,
                          tooltip: t.cancel,
                        ),
                      TextButton(onPressed: _close, child: Text(t.done)),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // Results or empty state
                Flexible(
                  child: _hasSearched && _results.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(top: 40),
                          child: Text(
                            t.noResults,
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_results.length >= _maxResults)
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  t.searchResultsCapped,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: cs.onSurfaceVariant),
                                ),
                              ),
                            Flexible(
                              child: ListView.builder(
                                shrinkWrap: true,
                                itemCount: _results.length,
                                itemBuilder: (context, i) {
                                  final r = _results[i];
                                  return _ResultTile(
                                    result: r,
                                    onTap: () {
                                      widget.onJumpToChapter(r.chapterIndex);
                                      _close();
                                    },
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.result, required this.onTap});

  final _SearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.chapterTitle,
              style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            _HighlightedSnippet(
              snippet: result.snippet,
              matchStart: result.matchStart,
              matchLength: result.matchLength,
            ),
          ],
        ),
      ),
    );
  }
}

class _HighlightedSnippet extends StatelessWidget {
  const _HighlightedSnippet({
    required this.snippet,
    required this.matchStart,
    required this.matchLength,
  });

  final String snippet;
  final int matchStart;
  final int matchLength;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodyMedium;

    // Clamp to avoid out-of-bounds on edge cases.
    final safeStart = matchStart.clamp(0, snippet.length);
    final safeEnd = (matchStart + matchLength).clamp(0, snippet.length);

    if (safeStart >= safeEnd) {
      return Text(snippet, style: style, maxLines: 3);
    }

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: snippet.substring(0, safeStart)),
          TextSpan(
            text: snippet.substring(safeStart, safeEnd),
            style: TextStyle(
              backgroundColor: cs.primaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(text: snippet.substring(safeEnd)),
        ],
      ),
      style: style,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}
