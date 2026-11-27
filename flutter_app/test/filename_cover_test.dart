import 'package:flutter_app/services/conversion/filename_cover.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the Rust contract into a label and an opaque colour', () {
    final cover = parseFilenameCover(
      '{"label":"Dom Casmurro","backgroundRgb":[10,20,30]}',
    );
    expect(cover!.label, 'Dom Casmurro');
    expect(cover.background.toARGB32(), 0xff0a141e);
  });

  test('rejects malformed or empty contracts', () {
    expect(parseFilenameCover(null), isNull);
    expect(parseFilenameCover('nope'), isNull);
    expect(parseFilenameCover('{"label":"","backgroundRgb":[1,2,3]}'), isNull);
    expect(parseFilenameCover('{"label":"a","backgroundRgb":[1,2]}'), isNull);
  });

  test('resolver memoises one call per file name', () async {
    var calls = 0;
    final resolver = FilenameCoverResolver(
      call: (name) async {
        calls++;
        return '{"label":"$name","backgroundRgb":[1,2,3]}';
      },
    );
    await resolver.resolve('a.epub');
    await resolver.resolve('a.epub');
    expect(calls, 1);
  });
}
