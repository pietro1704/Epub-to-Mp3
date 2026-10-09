import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/audio_player_service.dart';
import 'package:flutter_app/services/playback_resume_persistence.dart';
import 'package:flutter_app/services/resume_store.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('provider disposal saves without reading a disposed ref', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final player = FakeAudioPlayerService();
    await player.setQueue(const [
      ChapterProgress(index: 0, name: 'First', status: 'completed'),
    ]);
    await player.seek(const Duration(seconds: 19), index: 0);
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(preferences),
        globalAudioPlayerProvider.overrideWithValue(player),
      ],
    );
    container.read(currentlyPlayingBookIdProvider.notifier).state = 'book-a';
    container.read(playbackResumePersistenceProvider);
    container.read(currentlyPlayingBookIdProvider.notifier).state = 'book-b';

    container.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(ResumeStore(preferences).loadBookPosition('book-a'), isNull);
    expect(ResumeStore(preferences).loadBookPosition('book-b'), (
      chapter: 0,
      seconds: 19.0,
    ));
    await player.dispose();
  });

  test('backgrounding saves position even when playback is paused', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final player = FakeAudioPlayerService();
    await player.setQueue(const [
      ChapterProgress(index: 0, name: 'First', status: 'completed'),
    ]);
    await player.seek(const Duration(seconds: 23), index: 0);
    final persistence = PlaybackResumePersistence(
      player: player,
      preferences: preferences,
      bookId: () => 'book-a',
    );
    addTearDown(player.dispose);
    addTearDown(persistence.dispose);

    await persistence.save();
    expect(ResumeStore(preferences).loadBookPosition('book-a'), isNull);
    persistence.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);

    expect(ResumeStore(preferences).loadBookPosition('book-a'), (
      chapter: 0,
      seconds: 23.0,
    ));
  });

  test('queued saves retain the position of their original book', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final player = FakeAudioPlayerService();
    await player.setQueue(const [
      ChapterProgress(index: 0, name: 'First', status: 'completed'),
      ChapterProgress(index: 1, name: 'Second', status: 'completed'),
    ]);
    await player.seek(const Duration(seconds: 37), index: 0);
    var bookId = 'book-a';
    final persistence = PlaybackResumePersistence(
      player: player,
      preferences: preferences,
      bookId: () => bookId,
    );
    addTearDown(player.dispose);
    addTearDown(persistence.dispose);

    final first = persistence.save(force: true);
    final queued = persistence.save(force: true);
    bookId = 'book-b';
    await player.seek(const Duration(seconds: 120), index: 1);
    final latest = persistence.save(force: true);
    await Future.wait([first, queued, latest]);

    expect(ResumeStore(preferences).loadBookPosition('book-a'), (
      chapter: 0,
      seconds: 37.0,
    ));
    expect(ResumeStore(preferences).loadBookPosition('book-b'), (
      chapter: 1,
      seconds: 120.0,
    ));
  });

  test('persists the active playback chapter and position', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final player = FakeAudioPlayerService();
    await player.setQueue(const [
      ChapterProgress(
        index: 0,
        name: 'Chapter 1',
        status: 'completed',
        downloadUrl: '/tmp/chapter.mp3',
      ),
    ]);
    final persistence = PlaybackResumePersistence(
      player: player,
      preferences: preferences,
      bookId: () => 'book-1',
    );

    await player.play();
    await player.seek(const Duration(seconds: 37), index: 0);
    await persistence.save();

    expect(ResumeStore(preferences).loadBookPosition('book-1'), (
      chapter: 0,
      seconds: 37.0,
    ));

    await persistence.dispose();
    await player.dispose();
  });
}
