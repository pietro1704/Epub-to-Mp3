import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/features/settings/local_audio_storage.dart';

void main() {
  test(
    'explicit removal protects active audio, original books and models',
    () async {
      final docs = await Directory.systemTemp.createTemp('audio-storage-');
      addTearDown(() => docs.delete(recursive: true));
      final book = File('${docs.path}/library/book.epub');
      await book.parent.create(recursive: true);
      await book.writeAsString('source');
      final model = File('${docs.path}/tts-models/voice.onnx');
      await model.parent.create(recursive: true);
      await model.writeAsString('model');
      final audio = File('${docs.path}/audiobooks/book/chapter.mp3');
      await audio.parent.create(recursive: true);
      await audio.writeAsBytes([1, 2, 3]);
      final storage = LocalAudioStorage(docs);
      final entry = (await storage.scan()).single;
      expect(entry.bytes, 3);
      expect(await storage.remove(entry, activeIds: {'book'}), false);
      expect(await audio.exists(), true);
      expect(
        await storage.remove(
          const LocalAudioEntry('audiobooks', '../book', 3),
          activeIds: {},
        ),
        false,
      );
      expect(await storage.remove(entry, activeIds: {}), true);
      expect(await audio.exists(), false);
      expect(await book.exists(), true);
      expect(await model.exists(), true);
    },
  );

  test('symlink roots never expose or delete external files', () async {
    final root = await Directory.systemTemp.createTemp('audio-symlink-');
    addTearDown(() => root.delete(recursive: true));
    final docs = await Directory('${root.path}/documents').create();
    final outside = await Directory('${root.path}/outside/book')
        .create(recursive: true);
    await File('${outside.path}/audio.mp3').writeAsString('preserve');
    await Link('${docs.path}/audiobooks').create('${root.path}/outside');
    final storage = LocalAudioStorage(docs);
    expect(await storage.scan(), isEmpty);
    expect(
      await storage.remove(
        const LocalAudioEntry('audiobooks', 'book', 8),
        activeIds: {},
      ),
      false,
    );
    expect(await File('${outside.path}/audio.mp3').exists(), true);
  });
}
