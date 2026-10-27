import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/audio_player_service.dart';
import 'package:flutter_app/services/desktop_audio_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('installed Linux decoder loads PCM and rejects an invalid replacement without claiming playback', () async {
    initializeDesktopAudioBackend(TargetPlatform.linux);
    final directory = await Directory.systemTemp.createTemp('epub-decoder-');
    final player = AudioPlayerService();
    addTearDown(() async { await player.dispose(); await directory.delete(recursive: true); });
    const sampleRate = 24000;
    final bytes = ByteData(44 + sampleRate * 2 * 2);
    void text(int offset, String value) {
      for (var index = 0; index < value.length; index++) { bytes.setUint8(offset + index, value.codeUnitAt(index)); }
    }
    text(0, 'RIFF'); bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
    text(8, 'WAVEfmt '); bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little); bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, sampleRate, Endian.little); bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little); bytes.setUint16(34, 16, Endian.little);
    text(36, 'data'); bytes.setUint32(40, bytes.lengthInBytes - 44, Endian.little);
    final valid = await File('${directory.path}/fixture.wav').writeAsBytes(bytes.buffer.asUint8List());
    await player.setQueue([ChapterProgress(index: 16, name: 'Source', downloadUrl: valid.uri.toString())]);
    final duration = await player.raw.load();
    expect(duration?.inMilliseconds, greaterThanOrEqualTo(1990));
    expect(player.isPlaying, isFalse);
    expect(player.chapterIndexForPlayerIndex(0), 16);
    final invalid = await File('${directory.path}/invalid.mp3').writeAsString('not encoded audio');
    await player.setQueue([ChapterProgress(index: 24, name: 'Replacement', downloadUrl: invalid.uri.toString())]);
    await expectLater(player.raw.load(), throwsA(isA<Exception>()));
    await Future<void>.delayed(Duration.zero);
    expect(player.isPlaying, isFalse);
  }, skip: !Platform.isLinux || !const bool.fromEnvironment('EPUB2MP3_NATIVE_DECODER'));
}
