import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/ebook_fulltext.dart';
import '../services/audio_player_service.dart';
import '../services/sentence_sync_coordinator.dart';
import '../state/providers.dart';
import 'full_player_sheet.dart';
import 'reader_settings_sheet.dart';
import 'reader_theme_colors.dart';
import 'reader_view.dart';

typedef Chapter = FulltextChapter;

class InstantReaderView extends ConsumerStatefulWidget {
  final EbookFulltext fulltext;
  final int initialChapterIndex;
  final String? statusBanner;
  final VoidCallback? onRequestPlay;
  final AudioPlayerService? player;
  final String? activeSentenceId;
  final Uint8List? coverArt;
  final String? bookId;

  const InstantReaderView({
    super.key,
    required this.fulltext,
    this.initialChapterIndex = 0,
    this.statusBanner,
    this.onRequestPlay,
    this.player,
    this.activeSentenceId,
    this.coverArt,
    this.bookId,
  });

  @override
  ConsumerState<InstantReaderView> createState() =>
      _InstantReaderViewState();
}

class _InstantReaderViewState extends ConsumerState<InstantReaderView> {
  late int _currentChapterIndex;
  bool _chromeVisible = true;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<String?>? _sentenceSub;
  SentenceSyncCoordinator? _sentenceSync;
  String? _liveSentenceId;

  static const _minReadableChars = 10;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    final bookId = widget.bookId;
    if (bookId != null && widget.initialChapterIndex == 0) {
      final saved = settings.savedChapterIndex(bookId);
      _currentChapterIndex =
          saved > 0 ? saved : _firstReadableIndex;
    } else {
      _currentChapterIndex = widget.initialChapterIndex == 0
          ? _firstReadableIndex
          : widget.initialChapterIndex;
    }
    // Slice 25: wire the SyncEngine so the read-along surface shipped
    // through book_open_screen → InstantReaderView gets the same
    // sentence-level highlight that PlayerReaderScreen got in slice 24.
    _wireSentenceSync();
  }

  void _wireSentenceSync() {
    final player = widget.player;
    final id = widget.bookId;
    if (player == null || id == null) return;
    final engine = ref.read(syncEngineProvider(id));
    final coordinator = SentenceSyncCoordinator(engine);
    _sentenceSync = coordinator;
    _positionSub = player.position.listen((pos) {
      if (!mounted) return;
      coordinator.updatePosition(pos.inMilliseconds / 1000.0);
    });
    _sentenceSub = engine.currentSentence.listen((id) {
      if (!mounted) return;
      if (id != _liveSentenceId) {
        setState(() => _liveSentenceId = id);
      }
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _sentenceSub?.cancel();
    // Always restore the system chrome when leaving the reader so other
    // screens are not left in immersive mode.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _applySystemChrome() {
    // Apple-Books-style chrome toggle mirrors the iOS
    // `ChromeVisibilityModifier.statusBarHidden(!visible)` behaviour:
    // the status bar AND the navigation bar both disappear when the
    // user hides the reader chrome via a centre tap. `manual` mode
    // with an explicit overlay list is the only way to guarantee
    // BOTH bars stay hidden on Android — `SystemUiMode.immersive`
    // re-shows the navigation bar on the first edge swipe and
    // `edgeToEdge` keeps both bars visible. User-reported on
    // Android 2026-05-22: "deve esconder top e bottom bar tb, como
    // no iOS."
    if (_chromeVisible) {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    } else {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: const <SystemUiOverlay>[],
      );
    }
  }

  void _setChromeVisible(bool visible) {
    if (_chromeVisible == visible) return;
    setState(() => _chromeVisible = visible);
    _applySystemChrome();
  }

  int get _firstReadableIndex {
    final idx = widget.fulltext.chapters.indexWhere(
      (c) => c.text.trim().length >= _minReadableChars,
    );
    return idx >= 0 ? idx : 0;
  }

  Chapter? _resolveChapter(int index) {
    final chapters = widget.fulltext.chapters;
    final candidates = [
      chapters.cast<Chapter?>().firstWhere(
            (c) => c!.index == index + 1,
            orElse: () => null,
          ),
      chapters.cast<Chapter?>().firstWhere(
            (c) => c!.index == index,
            orElse: () => null,
          ),
      if (index >= 0 && index < chapters.length) chapters[index],
    ];
    for (final c in candidates) {
      if (c != null && c.text.trim().length >= _minReadableChars) return c;
    }
    return candidates.whereType<Chapter>().firstOrNull;
  }

  bool advanceToNextChapter() {
    if (_currentChapterIndex + 1 >= widget.fulltext.chapters.length) {
      return false;
    }
    setState(() => _currentChapterIndex += 1);
    _savePosition();
    return true;
  }

  bool returnToPreviousChapter() {
    if (_currentChapterIndex <= 0) return false;
    setState(() => _currentChapterIndex -= 1);
    _savePosition();
    return true;
  }

  void _savePosition() {
    final bookId = widget.bookId;
    if (bookId == null) return;
    final settings = ref.read(settingsProvider);
    settings.saveChapterIndex(_currentChapterIndex, bookId);
  }

  void _showReaderSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ReaderSettingsSheet(),
    );
  }

  void _showFullPlayer(Chapter chapter) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, controller) => FullPlayerSheet(
          player: widget.player!,
          bookTitle: widget.fulltext.bookTitle,
          author: widget.fulltext.bookAuthor,
          chapterLabel: chapter.displayTitle,
          coverArt: widget.coverArt,
          bookId: widget.bookId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final chapter = _resolveChapter(_currentChapterIndex);
    // Slice 25: re-prime the sentence-sync engine for the resolved
    // chapter whenever it changes. loadIfChanged is idempotent on
    // identical inputs so calling it from build is safe.
    if (_sentenceSync != null && chapter != null) {
      _sentenceSync!.loadIfChanged(
        fulltext: widget.fulltext,
        playableChapters: widget.player?.chapters ?? const [],
        playableIndex: _currentChapterIndex,
      );
    }
    if (chapter == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(AppLocalizations.of(context)!.noContentAvailable,
                style: const TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    final spans = chapter.splitSentences();
    final bg = ReaderThemeColors.background(settings.readerTheme,
        custom: settings.readerCustomColors);
    final fg = ReaderThemeColors.foreground(settings.readerTheme,
        custom: settings.readerCustomColors);

    return Column(
      children: [
        // Toolbar with settings button — hidden when chrome is off
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          child: _chromeVisible
              ? Container(
                  color: bg,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: SafeArea(
                    bottom: false,
                    child: Row(
                      children: [
                        const Spacer(),
                        IconButton(
                          icon: Icon(Icons.text_format,
                              color: fg.withValues(alpha: 0.7)),
                          onPressed: _showReaderSettings,
                          tooltip: 'Reader settings',
                        ),
                      ],
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),

        Expanded(
          child: ReaderView(
            chapter: chapter,
            spans: spans,
            // Live sentence id (driven by SyncEngine + position stream
            // through slice 25) takes precedence over the static prop.
            currentSentenceId: _liveSentenceId ?? widget.activeSentenceId,
            onAdvanceChapter: advanceToNextChapter,
            onPreviousChapter: returnToPreviousChapter,
            onCenterTap: () => _setChromeVisible(!_chromeVisible),
            onAutoHideChrome: () => _setChromeVisible(false),
          ),
        ),

        // Bottom bar — hidden when chrome is off
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          child: _chromeVisible
              ? _buildBottomBar(context, chapter, bg, fg)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildBottomBar(
    BuildContext context,
    Chapter chapter,
    Color bg,
    Color fg,
  ) {
    final banner = widget.statusBanner;
    final isConverting = banner != null && banner.isNotEmpty;
    final isError = isConverting &&
        (banner.toLowerCase().contains('failed') ||
            banner.toLowerCase().contains('unavailable'));
    final hasPlayer = widget.player != null;

    return GestureDetector(
      onTap: hasPlayer ? () => _showFullPlayer(chapter) : null,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          border: Border(
            top: BorderSide(color: fg.withValues(alpha: 0.15)),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              // Cover art or headphones icon
              if (widget.coverArt != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.memory(
                    widget.coverArt!,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                  ),
                )
              else
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: fg.withValues(alpha: 0.1),
                  ),
                  child: Icon(Icons.headphones, color: fg.withValues(alpha: 0.6), size: 22),
                ),
              const SizedBox(width: 12),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      chapter.displayTitle,
                      style: TextStyle(
                        color: fg,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (isConverting)
                      Row(
                        children: [
                          if (isError)
                            Icon(Icons.warning_amber_rounded,
                                size: 14, color: Colors.orange[700])
                          else
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: fg.withValues(alpha: 0.5),
                              ),
                            ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              banner,
                              style: TextStyle(
                                fontSize: 12,
                                color: fg.withValues(alpha: 0.5),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      )
                    else if (widget.fulltext.bookAuthor != null)
                      Text(
                        widget.fulltext.bookAuthor!,
                        style: TextStyle(
                          fontSize: 12,
                          color: fg.withValues(alpha: 0.5),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),

              if (hasPlayer)
                StreamBuilder<bool>(
                  stream: widget.player!.playing,
                  builder: (context, snap) {
                    final isPlaying = snap.data ?? false;
                    return IconButton(
                      icon: Icon(
                        isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        size: 36,
                        color: fg,
                      ),
                      onPressed: widget.player!.togglePlayPause,
                    );
                  },
                )
              else if (!isConverting && widget.onRequestPlay != null)
                IconButton(
                  icon: Icon(Icons.play_circle_filled,
                      size: 36, color: fg),
                  onPressed: widget.onRequestPlay,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
