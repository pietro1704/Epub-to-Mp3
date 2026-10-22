part of 'book_open_screen.dart';

mixin BookLocalPlaybackExecution on ConsumerState<BookOpenScreen>, BookContentSession, BookPlaybackSession {
  @override
  Future<void> _runLocalPlaybackConversion({
    required int playbackChapterIndex,
    required int generation,
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
    final jobId = 'local-${widget.bookId}';
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
      final outDir = Directory('${docsDir.path}/audiobooks/${widget.bookId}');
      if (!await outDir.exists()) await outDir.create(recursive: true);
      if (!_isCurrentConversion(generation)) return;
      debugPrint('BookOpenScreen: local output ready path=${outDir.path}');

      final player = ref.read(globalAudioPlayerProvider);
      _setCoverOnPlayer(player);

      final existingJob = await coordinator.store.load(widget.bookId, jobId);
      if (!_isCurrentConversion(generation)) return;
      final ttsSnapshot = ref.read(settingsProvider).ttsPreferences;
      final ttsSupport = await getApplicationSupportDirectory();
      if (!_isCurrentConversion(generation)) return;
      final requestedOptionsJson = ttsSnapshot.optionsJson(
        modelsRoot: '${ttsSupport.path}/tts-models',
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
      final bookLocale = SpeechTextPolicy.detectLocale(
        ft.chapters.map((chapter) => chapter.text),
      );
      debugPrint('BookOpenScreen: verified book locale=$bookLocale');

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
            downloadUrl: 'file://$path',
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

      final converter = ref.read(embeddedConverterProvider);
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
                _scheduleRequestedPlayback(player, generation);
              }
            : null,
        onChapterCompleted: (chapter, path, updated) async {
          if (!_isCurrentConversion(generation)) return;
          final cp = ChapterProgress(
            index: chapter.index,
            name: chapter.name,
            status: 'completed',
            downloadUrl: 'file://$path',
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
          _scheduleRequestedPlayback(player, generation);
          _localJob = updated;
        },
      );
      if (!_isCurrentConversion(generation)) return;
      _localJob = job;
      if (job.status == LocalConversionJobStatus.completed) _markBookOffline();
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
      _showConversionError(e);
      setState(() => _isConverting = false);
    } finally {
      if (generation == _localConversionGeneration) {
        _platformVoiceSession.end();
        _activeConversionService = null;
      }
    }
  }

}
