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
}