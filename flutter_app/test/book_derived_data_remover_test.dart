import 'dart:io';

import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/services/storage/book_derived_data_remover.dart';
import 'package:flutter_app/services/storage/local_fulltext_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio_player_service.dart';

const _book = '64b0bac4443cf046cc38fe00dba78c95';
const _other = '0123456789abcdef0123456789abcdef';

Future<File> _write(String path) async {
  final file = File(path);
  await file.create(recursive: true);
  await file.writeAsString('x');
  return file;
}

void main() {
  late Directory root;
  late SharedPreferences prefs;
  late LocalFulltextCache cache;
  late BookDerivedDataRemover remover;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('derived-data-');
    addTearDown(() => root.delete(recursive: true));
    SharedPreferences.setMockInitialValues({
      'readPos_ch_$_book': 2,
      'readPos_pg_$_book': 1,
      'readPos_sourceChapter_$_book': 2,
      'readPos_offset_$_book': 40,
      'resume:book:$_book:chapter': 1,
      'resume:book:$_book:position': 12.5,
      'resume:local-$_book:0': 3.0,
      'resume:listen-$_book-1-99:1': 4.0,
      'local-conversion.v1:$_book:local-$_book': '{}',
      // Another book and unrelated settings stay.
      'readPos_ch_$_other': 5,
      'resume:book:$_other:chapter': 2,
      'local-conversion.v1:$_other:local-$_other': '{}',
      'readerTheme': 'sepia',
    });
    prefs = await SharedPreferences.getInstance();
    cache = LocalFulltextCache(directoryProvider: () async => Directory('${root.path}/fulltext')..createSync(recursive: true));
    remover = BookDerivedDataRemover(
      prefs: prefs,
      fulltextCache: cache,
      documents: () async => root,
    );
  });

  test('removes the derived data of one book and nothing else', () async {
    await cache.save(
      EbookFulltext.fromJson({'jobId': 'x', 'chapters': const <Map<String, dynamic>>[]}),
      _book,
    );
    await cache.save(
      EbookFulltext.fromJson({'jobId': 'y', 'chapters': const <Map<String, dynamic>>[]}),
      _other,
    );
    await _write('${root.path}/audiobooks/$_book/listen-1/chapter.mp3');
    await _write('${root.path}/audiobooks/$_other/chapter.mp3');
    await _write('${root.path}/downloads/keep.txt');
    final source = await _write('${root.path}/library/$_book.epub');

    await remover.remove(_book);

    expect(prefs.getKeys().where((key) => BookDerivedDataRemover.ownsKey(key, _book)), isEmpty);
    expect(prefs.getKeys(), containsAll(['readPos_ch_$_other', 'resume:book:$_other:chapter', 'local-conversion.v1:$_other:local-$_other', 'readerTheme']));
    expect(await cache.read(_book), isNull);
    expect(await cache.read(_other), isNotNull);
    expect(Directory('${root.path}/audiobooks/$_book').existsSync(), isFalse);
    expect(File('${root.path}/audiobooks/$_other/chapter.mp3').existsSync(), isTrue);
    expect(File('${root.path}/downloads/keep.txt').existsSync(), isTrue);
    expect(source.existsSync(), isTrue, reason: 'the imported book is never deleted');
    expect(File('${root.path}/fulltext/$_book.json.last_access').existsSync(), isFalse);
  });

  test('ignores identities that are not plain ids', () async {
    await _write('${root.path}/audiobooks/keep/chapter.mp3');
    for (final id in ['', '..', '../audiobooks', 'a/b', r'a\b']) {
      await remover.remove(id);
    }
    expect(File('${root.path}/audiobooks/keep/chapter.mp3').existsSync(), isTrue);
    expect(prefs.getKeys(), contains('readerTheme'));
  });

  test('does not follow a link in the audiobook root', () async {
    final outside = await Directory.systemTemp.createTemp('derived-outside-');
    addTearDown(() => outside.delete(recursive: true));
    await _write('${outside.path}/precious.txt');
    await Directory('${root.path}/audiobooks').create(recursive: true);
    await Link('${root.path}/audiobooks/$_book').create(outside.path);
    await remover.remove(_book);
    expect(File('${outside.path}/precious.txt').existsSync(), isTrue);
  });

  test('stops the player when it is playing the removed book', () async {
    final player = FakeAudioPlayerService()..currentBookId = _book;
    await player.setQueue([
      ChapterProgress(index: 0, name: 'One', status: 'completed', downloadUrl: 'file:///x.mp3'),
    ]);
    await player.play();
    await remover.remove(_book, player: player);
    expect(player.isPlaying, isFalse);
    expect(player.hasQueuedAudio, isFalse);
    expect(player.currentBookId, isNull);

    final unrelated = FakeAudioPlayerService()..currentBookId = _other;
    await remover.remove(_book, player: unrelated);
    expect(unrelated.currentBookId, _other);
  });

  test('removeAudio deletes only the generated audio and conversion job of one book', () async {
    await _write('${root.path}/audiobooks/$_book/local-$_book/0001.mp3');
    await _write('${root.path}/audiobooks/$_other/local-$_other/0001.mp3');
    final playing = FakeAudioPlayerService()..currentBookId = _book;

    await remover.removeAudio(_book, player: playing);

    expect(Directory('${root.path}/audiobooks/$_book').existsSync(), isFalse);
    expect(File('${root.path}/audiobooks/$_other/local-$_other/0001.mp3').existsSync(), isTrue);
    expect(playing.currentBookId, isNull);
    expect(prefs.containsKey('local-conversion.v1:$_book:local-$_book'), isFalse);
    expect(prefs.containsKey('local-conversion.v1:$_other:local-$_other'), isTrue);
    expect(prefs.containsKey('readPos_ch_$_book'), isTrue, reason: 'reading position stays');
    expect(prefs.getString('readerTheme'), 'sepia');
  });
}
