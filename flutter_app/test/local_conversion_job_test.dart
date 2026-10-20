import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RefusingPreferences extends Fake implements SharedPreferences {
  @override
  Future<bool> setString(String key, String value) async => false;
}

void main() {
  late SharedPreferences prefs;
  late LocalConversionJobStore store;
  late ConversionJobCoordinator coordinator;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = LocalConversionJobStore(prefs);
    coordinator = ConversionJobCoordinator(
      store,
      now: () => DateTime.utc(2026, 1, 1),
    );
  });

  test('creates and persists job progress, outputs, and errors', () async {
    var job = await coordinator.createJob(
      bookId: 'book-1',
      jobId: 'local-book-1',
      chapters: const [
        LocalConversionChapterSpec(0, 'One'),
        LocalConversionChapterSpec(1, 'Two'),
      ],
    );
    job = await coordinator.markChapterRunning(job, 0);
    job = await coordinator.completeChapter(job, 0, '/audio/chapter_0.mp3');
    job = await coordinator.failChapter(job, 1, 'network error');

    final restored = await store.load('book-1', 'local-book-1');
    expect(restored!.status, LocalConversionJobStatus.failed);
    expect(restored.currentChapterIndex, 1);
    expect(restored.completedOutputs, ['/audio/chapter_0.mp3']);
    expect(restored.chapters[1].error, 'network error');
  });

  test('resumes pending chapters and retries a failed chapter', () async {
    var job = await coordinator.createJob(
      bookId: 'book-1',
      jobId: 'job-1',
      chapters: const [
        LocalConversionChapterSpec(2, 'Two'),
        LocalConversionChapterSpec(3, 'Three'),
      ],
    );
    job = await coordinator.failChapter(
      await coordinator.markChapterRunning(job, 2),
      2,
      'temporary',
    );
    expect(coordinator.pendingChapterIndices(job), [3]);
    job = await coordinator.retryChapter(job, 2);
    expect(coordinator.pendingChapterIndices(job), [2, 3]);
    expect(job.status, LocalConversionJobStatus.pending);
  });

  test('cancel persists and watchdog times out an abandoned chapter', () async {
    var current = DateTime.utc(2026, 1, 1);
    final timedCoordinator = ConversionJobCoordinator(
      store,
      now: () => current,
      watchdogTimeout: const Duration(minutes: 30),
    );
    var job = await timedCoordinator.createJob(
      bookId: 'book-1',
      jobId: 'job-1',
      chapters: const [LocalConversionChapterSpec(0, 'One')],
    );
    job = await timedCoordinator.markChapterRunning(job, 0);
    current = current.add(const Duration(minutes: 31));
    job = await timedCoordinator.watchdog(job);
    expect(job.status, LocalConversionJobStatus.failed);
    expect(job.chapters.single.error, contains('timed out'));
    job = await timedCoordinator.cancel(job);
    expect(
      (await store.load('book-1', 'job-1'))!.status,
      LocalConversionJobStatus.cancelled,
    );
  });

  test('completion is idempotent', () async {
    var job = await coordinator.createJob(
      bookId: 'book-1',
      jobId: 'job-1',
      chapters: const [LocalConversionChapterSpec(0, 'One')],
    );
    job = await coordinator.completeChapter(job, 0, '/audio/one.mp3');
    final again = await coordinator.completeChapter(job, 0, '/audio/one.mp3');
    expect(again.completedOutputs, ['/audio/one.mp3']);
    expect(again.status, LocalConversionJobStatus.completed);
  });

  test(
    'history survives store recreation and reports damaged records',
    () async {
      final older = await coordinator.createJob(
        bookId: 'book-1',
        jobId: 'old-job',
        chapters: const [LocalConversionChapterSpec(0, 'One')],
      );
      await store.save(older.copyWith(updatedAt: DateTime.utc(2026, 2, 1)));
      await store.save(
        LocalConversionJob(
          bookId: 'book-2',
          jobId: 'new-job',
          chapters: const [],
          status: LocalConversionJobStatus.cancelled,
          createdAt: DateTime.utc(2026, 3, 1),
          updatedAt: DateTime.utc(2026, 3, 1),
        ),
      );
      await prefs.setString('local-conversion.v1:broken', '{broken');
      await prefs.setString('unrelated', '{broken');

      final history = await LocalConversionJobStore(prefs).loadHistory();
      expect(history.jobs.map((job) => job.jobId), ['new-job', 'old-job']);
      expect(history.unreadableKeys, ['local-conversion.v1:broken']);
      expect(prefs.getString('local-conversion.v1:broken'), '{broken');
      expect((await store.load('book-1', 'old-job'))!.jobId, 'old-job');
    },
  );
  test(
    'history reload discovers records written by a background isolate',
    () async {
      final job = LocalConversionJob(
        bookId: 'background-book',
        jobId: 'background-job',
        chapters: const [],
        status: LocalConversionJobStatus.completed,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      // Keep the foreground instance/cache while replacing platform storage,
      // matching an independent background writer rather than a foreground save.
      SharedPreferences.setMockInitialValues({
        store.key(job.bookId, job.jobId): jsonEncode(job.toJson()),
      });
      expect(prefs.getString(store.key(job.bookId, job.jobId)), isNull);
      final history = await store.loadHistory();
      expect(history.jobs.map((job) => job.jobId), ['background-job']);
    },
  );
  test('save reports a refused persistent write', () async {
    final job = await coordinator.createJob(
      bookId: 'book-1',
      jobId: 'job-1',
      chapters: const [],
    );
    await expectLater(
      LocalConversionJobStore(_RefusingPreferences()).save(job),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'manual history keeps source indices and only established output paths',
    () async {
      final started = DateTime.utc(2026, 1, 1);
      await store.saveCompletedManifest(
        bookId: 'manual-book',
        startedAt: started,
        outputDirectory: '/tmp/audio dir',
        manifest: {
          'jobId': 'rust-manual',
          'title': 'Manual Book',
          'usedSelections': [TtsSelection.faber.toJson()],
          'fallbackUsed': true,
          'chapters': [
            {
              'index': 0,
              'sourceIndex': 5,
              'title': 'Six',
              'filename': '0001-six.mp3',
            },
            {
              'index': 1,
              'sourceIndex': 9,
              'title': 'Ten',
              'filename': '../outside.mp3',
            },
          ],
        },
      );
      final restored = (await store.load('manual-book', 'rust-manual'))!;
      expect(restored.createdAt, started);
      expect(restored.bookTitle, 'Manual Book');
      expect(restored.mode, 'manual');
      expect(restored.chapters.map((chapter) => chapter.index), [5, 9]);
      expect(restored.chapters.first.outputPath, '/tmp/audio dir/0001-six.mp3');
      expect(restored.chapters.last.outputPath, isNull);
      expect(restored.completedOutputs, ['/tmp/audio dir/0001-six.mp3']);
      expect(restored.usedSelections.single.modelId, 'pt_BR-faber-medium');
      expect(restored.fallbackUsed, true);
      expect(
        restored.chapters.every((chapter) => chapter.usedSelections.isEmpty),
        true,
        reason:
            'A book-wide manifest does not establish per-chapter voice usage',
      );
    },
  );
  test(
    'manual history preserves literal percent and fragment filename characters',
    () async {
      final filename = Platform.isWindows
          ? 'chapter%20#part.mp3'
          : 'chapter%20#part?.mp3';
      final job = await store.saveCompletedManifest(
        bookId: 'literal-book',
        startedAt: DateTime.utc(2026, 1, 1),
        outputDirectory: '/tmp/audio dir',
        manifest: {
          'jobId': 'literal-job',
          'chapters': [
            {'sourceIndex': 0, 'title': 'One', 'filename': filename},
          ],
        },
      );
      expect(
        job!.chapters.single.outputPath,
        Platform.isWindows
            ? r'\tmp\audio dir\chapter%20#part.mp3'
            : '/tmp/audio dir/chapter%20#part?.mp3',
      );
    },
  );
}
