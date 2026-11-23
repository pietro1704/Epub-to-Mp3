import 'package:flutter_app/models/reader_listening_position.dart';
import 'package:flutter_app/services/reader/narration_switch_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const position = ReaderListeningPosition(3, 120);

  test('restarts at the same reader position while listening', () {
    expect(
      narrationSwitchRestartPosition(
        position: position,
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
        listening: true,
        supportsPositionedStart: true,
      ),
      isNull,
    );
    expect(
      narrationSwitchRestartPosition(
        position: position,
        listening: true,
        supportsPositionedStart: false,
      ),
      isNull,
    );
  });
}
