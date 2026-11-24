part of 'book_open_screen.dart';

mixin BookLocalPlaybackExecution on ConsumerState<BookOpenScreen>, BookContentSession, BookPlaybackSession {
  @override
  Future<void> _runLocalPlaybackConversion({
    required int playbackChapterIndex,
    required int generation,
    ReaderListeningPosition? readerPosition,
    bool explicitNarration = false,
  }) async {
    final ft = _fulltext!;
    final conversionChapters = <FulltextChapter>[
      for (var index = 0; index < ft.chapters.length; index++)
        if (ft.chapters[index].text.trim().isNotEmpty)
          FulltextChapter(
            index: index,
            name: ft.chapters[index].name,
            text: ft.chapters[index].text,
          ),
    ];
    debugPrint(
      'BookOpenScreen: local conversion entered chapters=${ft.chapters.length}',
    );
    final coordinator = ConversionJobCoordinator(
      LocalConversionJobStore(ref.read(sharedPrefsProvider)),
    );
    final jobId = readerPosition == null ? 'local-${widget.bookId}'
        : 'listen-${widget.bookId}-$generation-${DateTime.now().microsecondsSinceEpoch}';
    try {
      final library = ref.read(libraryStoreProvider);
      final book = library.books
          .where((b) => b.id == widget.bookId)
          .firstOrNull;
      if (book == null) throw StateError('Book is no longer in the library');
      debugPrint('BookOpenScreen: local book resolved path=${book.filePath}');
      final inputPath = await library.ensureSupportedBookPath(book);
      final docsDir = await getApplicationDocumentsDirectory();
      if (!_isCurrentConversion(generation)) return;
      final outputBase = '${docsDir.path}/audiobooks/${widget.bookId}';
      final outDir = Directory(readerPosition == null ? outputBase : '$outputBase/$jobId');
      if (!await outDir.exists()) await outDir.create(recursive: true);
      if (!_isCurrentConversion(generation)) return;
      debugPrint('BookOpenScreen: local output ready path=${outDir.path}');

      final player = ref.read(globalAudioPlayerProvider);
      _setCoverOnPlayer(player);

      final existingJob = await coordinator.store.load(widget.bookId, jobId);
      if (!_isCurrentConversion(generation)) return;
      final settings = ref.read(settingsProvider);
      var ttsSnapshot = settings.ttsPreferences;
      final converter = ref.read(embeddedConverterProvider);
      final isNewJob = existingJob == null ||
          existingJob.status == LocalConversionJobStatus.cancelled;
      if (isNewJob) {
        final configured = settings.configuredTtsPreferences;
        if (converter is ListeningScheduleFactory) {
          final catalog = TtsCatalog.decode(await converter.ttsModels());
          if (!_isCurrentConversion(generation)) return;
          var base = configured ?? catalog.recommendedPreferences;
          final narration = await _resolveNarration(
            converter,
            inputPath,
            base,
            explicit: explicitNarration,
          );
          if (!_isCurrentConversion(generation)) return;
          if (narration is MissingNarration) {
            await _offerModelsFor(narration, generation);
            return;
          }
          if (narration is ResolvedNarration) base = narration.preferences;
          unawaited(_warnAboutMissingLanguageModels(converter, inputPath, base));
          ttsSnapshot = catalog.captureNewPreferences(base);
        } else if (converter is AndroidEmbeddedConverter) {
          TtsCatalog? catalog;
          try {
            final loaded = await ref.read(ttsCatalogProvider.future);
            catalog = loaded;
            if (configured == null) ttsSnapshot = loaded.recommendedPreferences;
          } catch (error) {
            debugPrint('Listening voice catalog unavailable: $error');
          }
          if (!_isCurrentConversion(generation)) return;
          final narration = await _resolveNarration(
            converter,
            inputPath,
            ttsSnapshot,
            androidApi: catalog?.androidApi,
            explicit: explicitNarration,
          );
          if (!_isCurrentConversion(generation)) return;
          if (narration is MissingNarration) {
            await _offerModelsFor(narration, generation);
            return;
          }
          if (narration is ResolvedNarration) ttsSnapshot = narration.preferences;
          unawaited(_warnAboutMissingLanguageModels(
            converter,
            inputPath,
            ttsSnapshot,
            androidApi: catalog?.androidApi,
          ));
        }
      }
      final ttsSupport = await getApplicationSupportDirectory();
      if (!_isCurrentConversion(generation)) return;
      final corrections = ref.read(bookLanguageCorrectionsProvider);
      final requestedOptionsJson = corrections.applying(
        ttsSnapshot.optionsJson(modelsRoot: '${ttsSupport.path}/tts-models'),
        bookId: widget.bookId,
      );
      late LocalConversionJob job;
      if (existingJob == null ||
          existingJob.status == LocalConversionJobStatus.cancelled) {
        job = await coordinator.createJob(
          bookId: widget.bookId,
          jobId: jobId,
          conversionOptionsJson: requestedOptionsJson,
          // Preserve each chapter's source position so resume data and Rust's
          // positional chapter selector stay on the same EPUB axis.
          chapters: [
            for (final chapter in conversionChapters)
              LocalConversionChapterSpec(chapter.index, chapter.name ?? ''),
          ],
        );
      } else {
        job = await coordinator.reconcileChapters(
          existingJob,
          conversionChapters
              .map(
                (chapter) => LocalConversionChapterSpec(
                  chapter.index,
                  chapter.name ?? '',
                ),
              )
              .toList(),
        );
        // A language the user corrected since this job was created applies to
        // its remaining chapters too.
        final corrected = corrections.applying(
          job.conversionOptionsJson ?? requestedOptionsJson,
          bookId: widget.bookId,
        );
        if (corrected != job.conversionOptionsJson) {
          job = job.copyWith(conversionOptionsJson: corrected);
          await coordinator.store.save(job);
        }
        job = await coordinator.watchdog(job);
        for (final chapter in job.chapters.where((c) => c.status == 'failed')) {
          job = await coordinator.retryChapter(job, chapter.index);
        }
      }
      for (final chapter in job.chapters.where((c) => c.status == 'running')) {
        job = await coordinator.retryChapter(job, chapter.index);
      }
      if (!_isCurrentConversion(generation)) return;
      _localJob = job;

      // Rebuild the queue from files already recorded as completed. A process
      // death therefore resumes at the first pending chapter, not chapter 0.
      final restoredAudioPaths = <String>{};
      for (final saved in job.chapters.where((c) => c.status == 'completed')) {
        final path = saved.outputPath;
        if (path == null || path.isEmpty || !await File(path).exists()) {
          continue;
        }
        if (!_isCurrentConversion(generation)) return;
        // Older jobs could contain repeated EPUB structural index 0 entries.
        // Never enqueue the same physical MP3 repeatedly after migration.
        if (!restoredAudioPaths.add(path)) continue;
        final source = conversionChapters
            .where((chapter) => chapter.index == saved.index)
            .firstOrNull;
        _playableChapters.add(
          ChapterProgress(
            index: saved.index,
            name: source?.name ?? saved.name,
            status: 'completed',
            downloadUrl: Uri.file(path).toString(),
            chars: source?.text.length,
            progressRatio: 1.0,
          ),
        );
      }
      _playableChapters.sort((a, b) => a.index.compareTo(b.index));
      debugPrint(
        'BookOpenScreen: completed queue restored count=${_playableChapters.length}',
      );
      if (_playableChapters.isNotEmpty) {
        await player.setQueue(List.of(_playableChapters));
        if (!_isCurrentConversion(generation)) return;
        _chapterQueueUpdated();
        _scheduleRequestedPlayback(player, generation);
      }
      // Persist a checkpoint even when the process resumes an existing job.
      // This recreates a missing manifest before the next long chapter starts.
      final restoredManifestTemp = File('${outDir.path}/manifest.json.part');
      await restoredManifestTemp.writeAsString(
        jsonEncode(job.toJson()),
        flush: true,
      );
      await restoredManifestTemp.rename('${outDir.path}/manifest.json');
      if (!_isCurrentConversion(generation)) return;

      _platformVoiceSession.begin(inputPath);
      final conversionService = RustPlaybackConversionService(
        converter: converter,
        coordinator: coordinator,
      );
      _activeConversionService = conversionService;
      job = await conversionService.convert(
        optionsJson: requestedOptionsJson,
        bookId: widget.bookId,
        jobId: jobId,
        inputPath: inputPath,
        chapters: conversionChapters,
        outputDirectory: outDir.path,
        initialChapterIndex: playbackChapterIndex,
        initialTextOffset: readerPosition?.textOffset ?? 0,
        playbackChapterChanges: _playbackWindowChanges.stream,
        isActive: () => mounted && generation == _localConversionGeneration,
        onSecondaryUsed: (_) async {
          if (!_isCurrentConversion(generation)) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context)!.ttsSecondaryUsedNotice,
              ),
            ),
          );
        },
        onUpdate: (updated) async {
          if (!_isCurrentConversion(generation)) return;
          setState(() => _localJob = updated);
        },
        onChapterStreaming: player is StreamingChapterPlayer
            ? (chapter, source) async {
                if (!mounted || generation != _localConversionGeneration) {
                  source.fail(StateError('Reader conversion replaced'));
                  return;
                }
                // An on-demand seek needs the finished, seekable chapter.
                if (_chapterPreparation.holdsStreaming(chapter.index)) return;
                (player as StreamingChapterPlayer).registerGrowingChapter(
                  chapter.index,
                  source,
                );
                final cp = ChapterProgress(
                  index: chapter.index,
                  name: chapter.name,
                  status: 'running',
                  downloadUrl: Uri(
                    scheme: 'growing',
                    path: source.requestId,
                  ).toString(),
                  chars: chapter.text.length,
                  progressRatio: 0.0,
                );
                final existing = _playableChapters.indexWhere(
                  (item) => item.index == chapter.index,
                );
                if (existing < 0) {
                  _playableChapters.add(cp);
                } else {
                  _playableChapters[existing] = cp;
                }
                _playableChapters.sort((a, b) => a.index.compareTo(b.index));
                await player.setQueue(List.of(_playableChapters));
                if (!_isCurrentConversion(generation)) return;
                // A next/previous button waits for exactly this: the chapter is queued.
                _chapterQueueUpdated();
                _scheduleRequestedPlayback(player, generation);
              }
            : null,
        onChapterCompleted: (chapter, path, updated) async {
          if (!_isCurrentConversion(generation)) return;
          final cp = ChapterProgress(
            index: chapter.index,
            name: chapter.name,
            status: 'completed',
            downloadUrl: Uri.file(path).toString(),
            chars: chapter.text.length,
            progressRatio: 1.0,
          );
          if (player is StreamingChapterPlayer) {
            (player as StreamingChapterPlayer).finishGrowingChapter(
              chapter.index,
              path,
            );
          }
          final existing = _playableChapters.indexWhere(
            (c) => c.index == cp.index,
          );
          if (existing < 0) {
            _playableChapters.add(cp);
            _playableChapters.sort((a, b) => a.index.compareTo(b.index));
          } else {
            _playableChapters[existing] = cp;
          }
          await player.setQueue(List.of(_playableChapters));
          if (!_isCurrentConversion(generation)) return;
          _chapterQueueUpdated();
          _scheduleRequestedPlayback(player, generation);
          _localJob = updated;
        },
      );
      if (!_isCurrentConversion(generation)) return;
      _localJob = job;
      if (job.coversFullSource(conversionChapters.map((chapter) => chapter.index))) _markBookOffline();
      setState(() => _isConverting = false);
    } catch (e) {
      if (!_isCurrentConversion(generation)) return;
      if (_localJob != null &&
          _localJob!.status == LocalConversionJobStatus.running) {
        final failed = await coordinator.failChapter(
          _localJob!,
          _localJob!.currentChapterIndex ?? 0,
          e.toString(),
        );
        if (!_isCurrentConversion(generation)) return;
        _localJob = failed;
      }
      if (!_isCurrentConversion(generation)) return;
      if (isBookLanguageUncertain(e) && await _recoverBookLanguage(e)) {
        if (!_isCurrentConversion(generation)) return;
        await _runLocalPlaybackConversion(
          playbackChapterIndex: playbackChapterIndex,
          generation: generation,
          readerPosition: readerPosition,
          explicitNarration: explicitNarration,
        );
        return;
      }
      if (!_isCurrentConversion(generation)) return;
      _showConversionError(e);
      setState(() => _isConverting = false);
    } finally {
      if (generation == _localConversionGeneration) {
        _platformVoiceSession.end();
        _activeConversionService = null;
      }
    }
  }


  /// Asks which language the undetectable passage (or book) is in and stores
  /// the answer; true when the conversion should run again with it.
  Future<bool> _recoverBookLanguage(Object error) async {
    if (!mounted) return false;
    final choice = await showBookLanguagePicker(
      context,
      allowsAutomatic: false,
      inconclusive: true,
    );
    if (choice == null || choice.isEmpty || !mounted) return false;
    await ref
        .read(bookLanguageCorrectionsProvider)
        .set(
          choice,
          bookId: widget.bookId,
          passage: BookLanguageUncertain.decode(error)?.passage(choice),
        );
    return true;
  }

  /// The narration this NEW job should use for the book's language. Only a
  /// per-language choice changes anything; see [resolvePlaybackNarration].
  Future<PlaybackNarration> _resolveNarration(
    EmbeddedConverter converter,
    String inputPath,
    TtsPreferences base, {
    int? androidApi,
    bool explicit = false,
  }) => resolvePlaybackNarration(
    explicitSelection: explicit,
    converter: converter,
    cache: ref.read(bookLanguageCacheProvider),
    bookId: widget.bookId,
    bookPath: inputPath,
    configured: base,
    choices: ref.read(languageModelChoicesProvider),
    correctedLanguage: ref.read(bookLanguageCorrectionsProvider).decision(widget.bookId).bookLanguage,
    // The voice the listener chose for this book reads its main language (Rust: source book_voice).
    bookVoice: ref.read(bookVoiceProvider(widget.bookId)),
    // Fresh at each job start: the cached list may predate an install.
    installedModelIds: () {
      ref.invalidate(installedNarrationModelIdsProvider);
      return ref.read(installedNarrationModelIdsProvider.future);
    },
    systemVoices: () => ref.read(systemVoiceLanguagesProvider.future),
    platform: switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.macOS => 'Macos',
      TargetPlatform.iOS => 'Ios',
      _ => 'Linux',
    },
    androidApi: androidApi,
  );

  /// A bilingual or multilingual book: say, before the narration starts and without blocking it,
  /// which of its languages have no installed voice (they are read with the main voice).
  /// Installing a model stays an explicit action in the Models screen.
  Future<void> _warnAboutMissingLanguageModels(
    EmbeddedConverter converter,
    String inputPath,
    TtsPreferences base, {
    int? androidApi,
  }) async {
    final missing = await missingProfileLanguages(
      converter: converter,
      cache: ref.read(bookLanguageCacheProvider),
      bookId: widget.bookId,
      bookPath: inputPath,
      configured: base,
      choices: ref.read(languageModelChoicesProvider),
      correctedLanguage: ref.read(bookLanguageCorrectionsProvider).decision(widget.bookId).bookLanguage,
      installedModelIds: () => ref.read(installedNarrationModelIdsProvider.future),
      systemVoices: () => ref.read(systemVoiceLanguagesProvider.future),
      platform: switch (defaultTargetPlatform) {
        TargetPlatform.android => 'Android',
        TargetPlatform.windows => 'Windows',
        TargetPlatform.macOS => 'Macos',
        TargetPlatform.iOS => 'Ios',
        _ => 'Linux',
      },
      androidApi: androidApi,
    );
    if (mounted && missing.isNotEmpty) {
      showMissingProfileModelsNotice(context, missing);
    }
  }

  /// Nothing usable is installed for the book's language: stop before any job
  /// exists and offer the Models screen at that language.
  Future<void> _offerModelsFor(MissingNarration missing, int generation) async {
    if (!mounted) return;
    setState(() => _isConverting = false);
    await showMissingNarrationDialog(context, language: missing.language);
  }
}
