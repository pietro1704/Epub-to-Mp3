import '../features/playback/measured_playback_binding.dart';
import '../features/playback/measured_speech_alignment.dart';
import '../screens/bookmarks_list_screen.dart';
import '../screens/models_screen.dart';
import 'reader_search_overlay.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/ebook_fulltext.dart';
import '../services/playback/audio_player_service.dart';
import '../services/playback/sentence_sync_coordinator.dart';
import '../services/playback/sync_engine.dart';
import '../state/providers.dart';

import '../models/reader_listening_position.dart';
import '../models/tts_preferences.dart';
import '../services/reader/narration_switch_policy.dart';
import 'reader_narration_menu.dart';
import '../screens/reading_preferences_screen.dart';
import 'reader_theme_colors.dart';
import 'reader_view.dart';

import 'reader_toc_rows.dart';
import 'reader_toc_audio_state.dart';
part 'instant_reader_tools.dart';

typedef Chapter = FulltextChapter;

class InstantReaderView extends ConsumerStatefulWidget {
  final EbookFulltext fulltext;
  final void Function(int chapter, int? offset)? onVisibleTextOffset;
  final int initialChapterIndex;
  final AudioPlayerInterface? player;
  final String? activeSentenceId;
  final Uint8List? coverArt;
  final String? bookId;
  final Future<void> Function(
    TtsSelection selection,
    ReaderListeningPosition? sentence,
  )?
  onNarrationChanged;

  /// Starts listening at a position chosen with "Play from here".
  final Future<void> Function(ReaderListeningPosition position)? onListenFrom;

  /// Download, cancel and retry of the book's chapter audio (contents menu).
  final ReaderDownloadActions? downloadActions;

  const InstantReaderView({
    super.key,
    required this.fulltext,
    this.onVisibleTextOffset,
    this.initialChapterIndex = 0,
    this.player,
    this.activeSentenceId,
    this.coverArt,
    this.bookId,
    this.onNarrationChanged,
    this.onListenFrom,
    this.downloadActions,
  });

  @override
  ConsumerState<InstantReaderView> createState() => _InstantReaderViewState();
}

class _InstantReaderViewState extends ConsumerState<InstantReaderView> {
  late int _currentChapterIndex;
  bool _chromeVisible = true;
  int _visibleTextOffset = 0;
  int? _requestedSourceOffset;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<String?>? _sentenceSub;
  SentenceSyncCoordinator? _sentenceSync;
  String? _liveSentenceId;
  final ReaderPageProbe _pageProbe = ReaderPageProbe();

  /// Paused narration keeps its sentence painted (it marks where it resumes) and
  /// drops it on a seek, like the measured path and the Apple reader.
  bool _sentenceReleased = false;
  double _heldSeconds = 0;
  StreamSubscription<bool>? _playingSub;
  MeasuredPlaybackBinding? _measuredBinding;
  StreamSubscription<TextRange?>? _measuredSubscription;
  TextRange? _measuredRange;
  Object? _measuredIdentity;
  FulltextChapter? _spansChapter;
  List<SentenceSpan> _spans = const [];

  /// A highlight change rebuilds the reader; the split is O(chapter), so it is kept per chapter.
  List<SentenceSpan> _sentenceSpans(FulltextChapter chapter) {
    if (!identical(_spansChapter, chapter)) {
      _spansChapter = chapter;
      _spans = chapter.splitSentences();
    }
    return _spans;
  }

  void _bindMeasuredPlayback(FulltextChapter chapter) {
    final identity = (
      widget.bookId,
      chapter.index,
      chapter.text,
      widget.player,
    );
    if (identity == _measuredIdentity) return;
    _measuredIdentity = identity;
    _measuredBinding?.dispose();
    _measuredSubscription?.cancel();
    _measuredRange = null;
    final player = widget.player;
    if (player == null) return;
    final binding = MeasuredPlaybackBinding(
      player: player,
      bookId: widget.bookId ?? '',
      // The audio queue names chapters by their place in the book.
      chapterIndex: widget.fulltext.chapters.indexOf(chapter),
      source: chapter.text,
    );
    _measuredBinding = binding;
    _measuredSubscription = binding.changes.listen((range) {
      if (mounted) setState(() => _measuredRange = range);
    });
    binding.update(player.positionSeconds);
  }

  void _update(VoidCallback update) => setState(update);

  @override
  void initState() {
    super.initState();
    // Opening a book shows the chrome. A provider cannot change while the tree builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(readerChromeVisibleProvider.notifier).state = true;
      // The previous book may have left the system bars hidden.
      _applySystemChrome();
    });
    final settings = ref.read(settingsProvider);
    final bookId = widget.bookId;
    if (bookId != null && widget.initialChapterIndex == 0) {
      final saved = settings.savedChapterIndex(bookId);
      _currentChapterIndex = saved > 0 ? saved : _firstReadableIndex;
    } else {
      _currentChapterIndex = widget.initialChapterIndex == 0
          ? _firstReadableIndex
          : widget.initialChapterIndex;
    }
    // Slice 25: wire the SyncEngine so the read-along surface shipped
    // through book_open_screen → InstantReaderView gets the same
    // sentence-level highlight that the retired player-reader screen had.
    _wireSentenceSync();
    // A cover tap that opened this reader leaves its request pending.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyPlaybackJump(ref.read(readerPlaybackJumpProvider));
    });
  }

  void _wireSentenceSync() {
    final player = widget.player;
    final id = widget.bookId;
    if (player == null || id == null) return;
    // Initial coordinator + position subscription. The build() pass
    // below ref.watches `syncEngineProvider(id)` and rebinds the
    // coordinator + re-attaches the sentence stream whenever the
    // engine instance changes (e.g. settings.wpm edited mid-playback).
    final engine = ref.read(syncEngineProvider(id));
    _sentenceSync = SentenceSyncCoordinator(engine);
    _positionSub = player.position.listen((pos) {
      if (!mounted) return;
      final seconds = pos.inMilliseconds / 1000.0;
      _sentenceSync?.updatePosition(seconds);
      if (player.isPlaying) {
        _heldSeconds = seconds;
      } else if (!_sentenceReleased && (seconds - _heldSeconds).abs() > 0.25) {
        setState(() => _sentenceReleased = true);
      }
    });
    _playingSub = player.playing.listen((playing) {
      if (!mounted || !playing) return;
      _heldSeconds = player.positionSeconds;
      if (_sentenceReleased) setState(() => _sentenceReleased = false);
    });
    _attachSentenceStream(engine);
  }

  void _attachSentenceStream(SyncEngine engine) {
    _sentenceSub?.cancel();
    _sentenceSub = engine.currentSentence.listen((id) {
      if (!mounted) return;
      if (id != _liveSentenceId) {
        setState(() => _liveSentenceId = id);
      }
    });
  }

  @override
  void dispose() {
    _measuredBinding?.dispose();
    _measuredSubscription?.cancel();
    _positionSub?.cancel();
    _playingSub?.cancel();
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
    ref.read(readerChromeVisibleProvider.notifier).state = visible;
    _applySystemChrome();
  }

  int get _firstReadableIndex {
    final idx = widget.fulltext.chapters.indexWhere(
      (c) => c.text.trim().isNotEmpty,
    );
    return idx >= 0 ? idx : 0;
  }

  Chapter? _resolveChapter(int index) {
    final chapters = widget.fulltext.chapters;
    if (chapters.isEmpty) return null;

    // The backend's chapter index is a stable identifier, not a guaranteed
    // zero-based array offset. Prefer the actual array position here: the
    // reader advances through the complete payload, including short front
    // matter, and must not reinterpret position 1 as chapter index 1.
    final clamped = index.clamp(0, chapters.length - 1).toInt();
    return chapters[clamped];
  }

  bool advanceToNextChapter() {
    final next = _currentChapterIndex + 1;
    if (next >= widget.fulltext.chapters.length) {
      return false;
    }
    setState(() => _currentChapterIndex = next);
    _savePosition();
    return true;
  }

  bool returnToPreviousChapter() {
    if (_currentChapterIndex <= 0) return false;
    setState(() {
      _currentChapterIndex -= 1;
      _requestedSourceOffset = null;
    });
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
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReadingPreferencesScreen(bookId: widget.bookId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A request raised while this reader is already open for the same book.
    ref.listen(
      readerPlaybackJumpProvider,
      (_, request) => _applyPlaybackJump(request),
    );
    final settings = ref.watch(readerSettingsProvider(widget.bookId));
    final chapter = _resolveChapter(_currentChapterIndex);
    // Slice 25: re-prime the sentence-sync engine for the resolved
    // chapter whenever it changes. loadIfChanged is idempotent on
    // identical inputs so calling it from build is safe. Slice 30:
    // also watch `syncEngineProvider` here so the coordinator
    // rebinds + the sentence stream is re-attached whenever the
    // provider hands us a fresh engine instance (e.g. settings.wpm
    // changed mid-playback). Without the rebind the cached
    // coordinator wrote to a disposed engine and the highlight
    // silently froze.
    if (_sentenceSync != null && chapter != null) {
      final id = widget.bookId;
      if (id != null) {
        final engine = ref.watch(syncEngineProvider(id));
        if (!identical(engine, _sentenceSync!.engine)) {
          _sentenceSync!.rebindIfEngineChanged(engine);
          _attachSentenceStream(engine);
        }
      }
      _sentenceSync!.loadIfChanged(
        fulltext: widget.fulltext,
        playableChapters: widget.player?.chapters ?? const [],
        playableIndex: widget.player?.currentIndexValue ?? -1,
      );
    }
    if (chapter == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.of(context)!.noContentAvailable,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }
    final player = widget.player;
    final queueIndex = player?.currentIndexValue == null
        ? -1
        : player!.chapterIndexForPlayerIndex(player.currentIndexValue!);
    final ownsHighlight =
        player != null &&
        player.currentBookId == widget.bookId &&
        queueIndex >= 0 &&
        queueIndex < player.chapters.length &&
        player.chapters[queueIndex].index ==
            widget.fulltext.chapters.indexOf(chapter);
    _bindMeasuredPlayback(chapter);
    final spans = _sentenceSpans(chapter);
    final bg = ReaderThemeColors.background(
      settings.readerTheme,
      custom: settings.readerCustomColors,
    );
    final fg = ReaderThemeColors.foreground(
      settings.readerTheme,
      custom: settings.readerCustomColors,
    );

    return ColoredBox(
      // The hidden bars keep their space; it shows the page colour, not the scaffold.
      color: bg,
      child: Column(
        children: [
          // Toolbar with settings button. Hidden when the chrome is off, but it
          // keeps its space: the page area never moves or resizes (Pietro's rule).
          Visibility(
            visible: _chromeVisible,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: Container(
              color: bg,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SafeArea(
                bottom: false,
                child: LayoutBuilder(
                  builder: (context, bar) => Row(
                    children: [
                      BackButton(
                        color: fg,
                        onPressed: () =>
                            ref.read(appDestinationProvider.notifier).state =
                                AppDestination.library,
                      ),
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            widget.fulltext.bookTitle ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: fg,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      ),
                      // Apple-style chrome: the recent tool beside More; the
                      // other tools live in the overflow menu.
                      ..._chromeTools(chapter, fg, bar.maxWidth),
                      ReaderNarrationMenu(
                        color: fg,
                        bookId: widget.bookId,
                        entries: _menuEntries(chapter, bar.maxWidth),
                        onChanged: widget.onNarrationChanged,
                        currentSentence: _liveSentencePosition,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          Expanded(
            child: ReaderView(
              key: ValueKey((_currentChapterIndex, _requestedSourceOffset)),
              initialSourceOffset:
                  _requestedSourceOffset ??
                  (ref
                              .read(sharedPrefsProvider)
                              .getInt(
                                'readPos_sourceChapter_${widget.bookId}',
                              ) ==
                          _currentChapterIndex
                      ? ref
                                .read(sharedPrefsProvider)
                                .getInt('readPos_offset_${widget.bookId}') ??
                            0
                      : 0),
              bookId: widget.bookId,
              chapterPosition: _currentChapterIndex,
              onPlayFromHere: widget.onListenFrom == null
                  ? null
                  : (utf16) => _playFromHere(chapter, utf16),
              pageProbe: _pageProbe,
              onVisibleTextOffset: (offset) {
                _visibleTextOffset = offset ?? _visibleTextOffset;
                final book = widget.bookId;
                if (book != null && offset != null) {
                  ref
                      .read(sharedPrefsProvider)
                      .setInt(
                        'readPos_sourceChapter_$book',
                        _currentChapterIndex,
                      );
                  ref
                      .read(sharedPrefsProvider)
                      .setInt('readPos_offset_$book', offset);
                }
                widget.onVisibleTextOffset?.call(
                  widget.fulltext.chapters.indexOf(chapter),
                  offset,
                );
              },
              chapter: chapter,
              measuredHighlight: _measuredRange,
              spans: spans,
              // Live sentence id (driven by SyncEngine + position stream
              // through slice 25) takes precedence over the static prop.
              currentSentenceId: ownsHighlight && !_sentenceReleased
                  ? _liveSentenceId ?? widget.activeSentenceId
                  : null,
              onAdvanceChapter: advanceToNextChapter,
              onPreviousChapter: returnToPreviousChapter,
              onCenterTap: () => _setChromeVisible(!_chromeVisible),
              onAutoHideChrome: () => _setChromeVisible(false),
            ),
          ),
        ],
      ),
    );
  }
}
