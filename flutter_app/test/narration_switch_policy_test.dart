import 'package:flutter_app/models/reader_listening_position.dart';
import 'package:flutter_app/services/reader/narration_switch_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const position = ReaderListeningPosition(3, 120);

  test('restarts at the same reader position while listening', () {
    expect(
      narrationSwitchRestartPosition(
        position: position,
        playingChapter: 3,
        listening: true,
        supportsPositionedStart: true,
      ),
      same(position),
    );
  });

  test('only saves the choice when nothing is playing', () {
    expect(
      narrationSwitchRestartPosition(
        position: position,
        playingChapter: 3,
        listening: false,
        supportsPositionedStart: true,
      ),
      isNull,
    );
  });

  test('does not restart without a position or a positioned converter', () {
    expect(
      narrationSwitchRestartPosition(
        position: null,
        playingChapter: null,
        listening: true,
        supportsPositionedStart: true,
      ),
      isNull,
    );
    expect(
      narrationSwitchRestartPosition(
        position: position,
        playingChapter: 3,
        listening: true,
        supportsPositionedStart: false,
      ),
      isNull,
    );
  });

  test('restarts from the playing chapter when the reader shows another one', () {
    final restart = narrationSwitchRestartPosition(
      position: position,
      playingChapter: 5,
      listening: true,
      supportsPositionedStart: true,
    );
    expect(restart?.chapterIndex, 5);
    expect(restart?.textOffset, 0);
  });

  test('uses the requested start while the first audio is still preparing', () {
    expect(
      narrationSwitchRestartPosition(
        position: position,
        playingChapter: null,
        listening: true,
        supportsPositionedStart: true,
      ),
      same(position),
    );
  });
}
