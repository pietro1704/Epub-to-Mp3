import 'dart:io';
import 'package:flutter_app/models/tts_preferences.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RefusingManualPreferences extends Fake implements SharedPreferences {
  int writes = 0;
  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    return false;
  }
}

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
  test(
    'manual history keeps source indices and only established output paths',
    () async {
      final started = DateTime.utc(2026, 1, 1);
      await store.saveCompletedManifest(
        bookId: 'manual-book',
        startedAt: started,
        outputDirectory: Platform.isWindows ? r'C:\tmp\audio dir' : '/tmp/audio dir',
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
      expect(restored.chapters.map((chapter) => chapter.index), [5, 9]);
      expect(restored.chapters.first.outputPath, Platform.isWindows
          ? r'C:\tmp\audio dir\0001-six.mp3'
          : '/tmp/audio dir/0001-six.mp3');
      expect(restored.chapters.last.outputPath, isNull);
      expect(restored.completedOutputs, [Platform.isWindows
          ? r'C:\tmp\audio dir\0001-six.mp3'
          : '/tmp/audio dir/0001-six.mp3']);
      expect(restored.usedSelections.single.modelId, 'pt_BR-faber-medium');
      expect(restored.fallbackUsed, true);
      final withChapterReceipt = restored.copyWith(chapters: [
        const LocalConversionChapter(
          index: 5, name: 'Six', status: 'completed',
          usedSelections: [TtsSelection.edge],
        ),
      ]);
      expect(withChapterReceipt.usedSelections.map((selection) => selection.engine),
          ['piper', 'edge']);
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
        outputDirectory: Platform.isWindows ? r'C:\tmp\audio dir' : '/tmp/audio dir',
        manifest: {
          'jobId': 'literal-job',
          'chapters': [
            {'sourceIndex': 0, 'title': 'One', 'filename': filename},
          ],
        },
      );
      expect(
        job.chapters.single.outputPath,
        Platform.isWindows
            ? r'C:\tmp\audio dir\chapter%20#part.mp3'
            : '/tmp/audio dir/chapter%20#part?.mp3',
      );
    },
  );
  test('manual writer refusal preserves completed audio and playback save semantics', () async {
    final directory = await Directory.systemTemp.createTemp('manual-history-refusal-');
    final audio = File('${directory.path}/completed.mp3');
    final bytes = [0x49, 0x44, 0x33, 1, 2, 3];
    await audio.writeAsBytes(bytes);
    final refusing = _RefusingManualPreferences();
    final manualStore = LocalConversionJobStore(refusing);
    try {
      await expectLater(
        manualStore.saveCompletedManifest(
          bookId: 'book',
          startedAt: DateTime.utc(2026),
          outputDirectory: directory.path,
          manifest: {
            'jobId': 'completed',
            'chapters': [{'sourceIndex': 0, 'filename': 'completed.mp3'}],
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(refusing.writes, 1);
      expect(await audio.readAsBytes(), bytes);
      final job = await coordinator.createJob(
        bookId: 'playback', jobId: 'unchanged', chapters: const [],
      );
      await manualStore.save(job);
      expect(refusing.writes, 2);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('manual writer rejects an empty book identity without changing stored bytes', () async {
    final existing = await coordinator.createJob(
      bookId: 'existing-book',
      jobId: 'existing-job',
      chapters: const [],
    );
    final existingKey = store.key(existing.bookId, existing.jobId);
    final original = prefs.getString(existingKey);
    final originalKeys = prefs.getKeys();
    await expectLater(
      store.saveCompletedManifest(
        bookId: '',
        startedAt: DateTime.utc(2026),
        manifest: {
          'jobId': 'unreadable-identity',
          'chapters': [{'sourceIndex': 0}],
        },
      ),
      throwsA(isA<FormatException>()),
    );
    expect(prefs.getKeys(), unorderedEquals(originalKeys));
    expect(prefs.getString(existingKey), original);
    expect(prefs.getString(store.key('', 'unreadable-identity')), isNull);
  });

  test('manual projection rejects invalid identity and source indices before writing', () async {
    for (final manifest in <Map<String, dynamic>>[
      {'chapters': [{'sourceIndex': 0}]},
      {'jobId': 'empty', 'chapters': []},
      {'jobId': 'negative', 'chapters': [{'sourceIndex': -1}]},
      {'jobId': 'missing-source', 'chapters': [{'index': 0}]},
      {'jobId': 'duplicate', 'chapters': [{'sourceIndex': 1}, {'sourceIndex': 1}]},
    ]) {
      await expectLater(
        store.saveCompletedManifest(
          bookId: 'invalid', startedAt: DateTime.utc(2026), manifest: manifest,
        ),
        throwsA(isA<FormatException>()),
      );
    }
    expect((await store.loadHistory()).jobs, isEmpty);
  });

  test('manual projection never invents an output root or escapes a confirmed one', () async {
    final filenames = ['../outside.mp3', r'..\outside.mp3', '/absolute.mp3', '.', '..'];
    final job = await store.saveCompletedManifest(
      bookId: 'safe', startedAt: DateTime.utc(2026), outputDirectory: Platform.isWindows ? r'C:\tmp\owned' : '/tmp/owned',
      manifest: {
        'jobId': 'bounded',
        'chapters': [for (var i = 0; i < filenames.length; i++) {
          'sourceIndex': i, 'filename': filenames[i],
        }],
      },
    );
    expect(job.completedOutputs, isEmpty);
    expect(job.chapters.every((chapter) => chapter.outputPath == null), true);
    final withoutRoot = await store.saveCompletedManifest(
      bookId: 'safe', startedAt: DateTime.utc(2026),
      manifest: {'jobId': 'no-root', 'chapters': [{'sourceIndex': 0, 'filename': 'real.mp3'}]},
    );
    expect(withoutRoot.chapters.single.outputPath, isNull);
    final relativeRoot = await store.saveCompletedManifest(
      bookId: 'safe', startedAt: DateTime.utc(2026), outputDirectory: 'relative',
      manifest: {'jobId': 'relative-root', 'chapters': [{'sourceIndex': 0, 'filename': 'real.mp3'}]},
    );
    expect(relativeRoot.chapters.single.outputPath, isNull);

  });

  test('Windows manual history preserves drive and UNC roots literally', () async {
    const filename = 'chapter%20#part.mp3';
    for (final root in [r'C:\Audio books', r'\\server\share\Audio books']) {
      final job = await store.saveCompletedManifest(
        bookId: 'windows-book',
        startedAt: DateTime.utc(2026),
        outputDirectory: root,
        manifest: {
          'jobId': root,
          'chapters': [
            {'sourceIndex': 7, 'filename': filename},
          ],
        },
      );
      expect(job.chapters.single.outputPath, '$root\\$filename');
      expect(job.completedOutputs, ['$root\\$filename']);
    }
    final relative = await store.saveCompletedManifest(
      bookId: 'windows-book',
      startedAt: DateTime.utc(2026),
      outputDirectory: r'C:Audio books',
      manifest: {
        'jobId': 'drive-relative',
        'chapters': [
          {'sourceIndex': 7, 'filename': filename},
        ],
      },
    );
    expect(relative.completedOutputs, isEmpty);
    expect(relative.chapters.single.outputPath, isNull);
  }, skip: !Platform.isWindows);

}
