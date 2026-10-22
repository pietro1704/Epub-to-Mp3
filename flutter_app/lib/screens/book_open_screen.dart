// Book open screen — mirrors iOS BookOpenView.
//
// Lifecycle:
//   1. Try cached fulltext (instant).
//   2. If no cache: parse EPUB through the selected native/runtime bridge, cache the result.
//   3. On success: render InstantReaderView.
//   4. Audio is NOT auto-started — user taps the global player.
//   5. Android/Linux/Windows conversion runs through the embedded Rust runtime.
//
// This widget is embedded inside the Reader tab (not pushed as a route)
// so the MiniPlayerBar and NavigationBar remain visible.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../models/ebook_fulltext.dart';
import '../models/book_entity.dart';
import '../models/job_snapshot.dart';
import '../services/async_load_guard.dart';
import '../services/audio_player_service.dart';
import '../services/cover_writeback.dart';

import '../services/local_conversion_job.dart';
import '../services/embedded_converter.dart';
import '../services/rust_playback_conversion.dart';
import '../services/platform_voice_notice.dart';
import '../services/reader_playback_startup.dart';
import '../services/latency_observation.dart';

import '../services/playback_first_resource_policy.dart';

import '../services/speech_text_policy.dart';
import '../services/resume_position_router.dart';
import '../services/resume_restoration_guard.dart';
import '../services/sse_subscription_lifecycle.dart';
import '../state/providers.dart';
import '../views/instant_reader_view.dart';
import 'library_screen.dart';
import 'pdf_reader_screen.dart';

part 'book_content_session.dart';
part 'book_playback_session.dart';
part 'book_local_playback_execution.dart';
part 'book_reader_body.dart';

enum _Phase { resolving, ready, error }

class BookOpenScreen extends ConsumerStatefulWidget {
  const BookOpenScreen({super.key, required this.bookId});
  final String bookId;

  @override
  ConsumerState<BookOpenScreen> createState() => _BookOpenScreenState();
}

class _BookOpenScreenState extends ConsumerState<BookOpenScreen>
    with BookContentSession, BookPlaybackSession, BookLocalPlaybackExecution, WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      _platformVoiceSubscription = _platformVoiceSession.listen(() {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              platformVoiceNotice(Localizations.localeOf(context).languageCode),
            ),
          ),
        );
      });
    }

    _playbackRequest = () async {
      if (!mounted) return;
      await _startConversion();
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(playbackRequestProvider.notifier).state = _playbackRequest;
      }
    });

    final book = ref
        .read(libraryStoreProvider)
        .books
        .where((b) => b.id == widget.bookId)
        .firstOrNull;
    if (book == null || !isPdfFilePath(book.filePath)) {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant BookOpenScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId) {
      _platformVoiceSession.end();
      _cancelConversion();
      _load();
    }
  }

  @override
  void dispose() {
    _playbackStartup.invalidate();
    _localConversionGeneration++;
    _stopNativeConversion();
    _platformVoiceSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _sseSubscription?.cancel();
    _chapterIndexSub?.cancel();
    _chapterIndexSub = null;
    _positionSub?.cancel();
    _positionSub = null;
    _resumeSaveTimer?.cancel();
    _closePlaybackWindowChanges();
    super.dispose();
  }

  @override
  void didHaveMemoryPressure() {
    _resourcePolicy.recordMemoryPressure();
  }

  @override
  Widget build(BuildContext context) => _BookReaderBody(
    bookId: widget.bookId,
    phase: _phase,
    errorMessage: _errorMessage,
    fulltext: _fulltext,
    localJob: _localJob,
    resourcePolicy: _resourcePolicy,
    isConverting: _isConverting,
    playableChapters: _playableChapters,
    onRetry: _load,
  );
}
