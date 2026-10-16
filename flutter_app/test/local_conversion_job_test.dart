import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;
  late LocalConversionJobStore store;
  late ConversionJobCoordinator coordinator;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = LocalConversionJobStore(prefs);
    coordinator = ConversionJobCoordinator(store, now: () => DateTime.utc(2026, 1, 1));
  });

  test('creates and persists job progress, outputs, and errors', () async {
    var job = await coordinator.createJob(
      bookId: 'book-1',
      jobId: 'local-book-1',
      chapters: const [LocalConversionChapterSpec(0, 'One'), LocalConversionChapterSpec(1, 'Two')],
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
      bookId: 'book-1', jobId: 'job-1',
      chapters: const [LocalConversionChapterSpec(2, 'Two'), LocalConversionChapterSpec(3, 'Three')],
    );
    job = await coordinator.failChapter(await coordinator.markChapterRunning(job, 2), 2, 'temporary');
    expect(coordinator.pendingChapterIndices(job), [3]);
    job = await coordinator.retryChapter(job, 2);
    expect(coordinator.pendingChapterIndices(job), [2, 3]);
    expect(job.status, LocalConversionJobStatus.pending);
  });

  test('cancel persists and watchdog times out an abandoned chapter', () async {
    var current = DateTime.utc(2026, 1, 1);
    final timedCoordinator = ConversionJobCoordinator(
      store, now: () => current,
      watchdogTimeout: const Duration(minutes: 30),
    );
    var job = await timedCoordinator.createJob(
      bookId: 'book-1', jobId: 'job-1',
      chapters: const [LocalConversionChapterSpec(0, 'One')],
    );
    job = await timedCoordinator.markChapterRunning(job, 0);
    current = current.add(const Duration(minutes: 31));
    job = await timedCoordinator.watchdog(job);
    expect(job.status, LocalConversionJobStatus.failed);
    expect(job.chapters.single.error, contains('timed out'));
    job = await timedCoordinator.cancel(job);
    expect((await store.load('book-1', 'job-1'))!.status, LocalConversionJobStatus.cancelled);
  });

  test('completion is idempotent', () async {
    var job = await coordinator.createJob(
      bookId: 'book-1', jobId: 'job-1',
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
      const capturedOptions =
          '{"tts_preferences":{"primary":{"engine":"piper",'
          '"model_id":"pt_BR-faber-medium"},"secondary":null,'
          '"allow_online_fallback":false}}';
      await store.save(
        older.copyWith(
          updatedAt: DateTime.utc(2026, 2, 1),
          conversionOptionsJson: capturedOptions,
          ttsPolicyState: {'opaque': 'saved-native-state'},
        ),
      );
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
      expect(history.jobs.last.conversionOptionsJson, capturedOptions);
      expect(history.jobs.last.ttsPolicyState, {'opaque': 'saved-native-state'});
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
  test(
    'history preserves mismatched and unknown-status records as unreadable',
    () async {
      final job = await coordinator.createJob(
        bookId: 'identity-book',
        jobId: 'identity-job',
        chapters: const [],
      );
      final mismatchKey = store.key('another-book', job.jobId);
      final mismatched = jsonEncode(job.toJson());
      await prefs.setString(mismatchKey, mismatched);
      final unknownKey = store.key('future-book', 'future-job');
      final unknown = jsonEncode({
        ...job.toJson(),
        'bookId': 'future-book',
        'jobId': 'future-job',
        'status': 'future-status',
      });
      await prefs.setString(unknownKey, unknown);
      final history = await LocalConversionJobStore(prefs).loadHistory();
      expect(history.jobs.map((entry) => entry.jobId), ['identity-job']);
      expect(history.unreadableKeys, containsAll([mismatchKey, unknownKey]));
      expect(prefs.getString(mismatchKey), mismatched);
      expect(prefs.getString(unknownKey), unknown);
      // Do not change the existing decoder's legacy fallback globally.
      expect(
        LocalConversionJob.fromJson(jsonDecode(unknown)).status,
        LocalConversionJobStatus.pending,
      );
    },
  );
  test(
    'history preserves unreadable timestamps without inventing dates',
    () async {
      final createdAt = DateTime.utc(2024, 2, 3, 4, 5, 6);
      final updatedAt = DateTime.utc(2025, 6, 7, 8, 9, 10);
      final valid = LocalConversionJob(
        bookId: 'dated-book',
        jobId: 'dated-job',
        chapters: const [],
        status: LocalConversionJobStatus.completed,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
      await store.save(valid);
      final corrupted = <String, String>{};
      for (final field in ['createdAt', 'updatedAt']) {
        for (final missing in [false, true]) {
          final jobId = '$field-${missing ? 'missing' : 'invalid'}';
          final record = {...valid.toJson(), 'jobId': jobId};
          if (missing) {
            record.remove(field);
          } else {
            record[field] = 'not-a-timestamp';
          }
          final key = store.key(valid.bookId, jobId);
          final bytes = jsonEncode(record);
          corrupted[key] = bytes;
          await prefs.setString(key, bytes);
        }
      }
      final history = await LocalConversionJobStore(prefs).loadHistory();
      expect(history.jobs.single.jobId, valid.jobId);
      expect(history.jobs.single.createdAt, createdAt);
      expect(history.jobs.single.updatedAt, updatedAt);
      expect(history.unreadableKeys, unorderedEquals(corrupted.keys));
      for (final entry in corrupted.entries) {
        expect(prefs.getString(entry.key), entry.value);
      }
    },
  );
}

