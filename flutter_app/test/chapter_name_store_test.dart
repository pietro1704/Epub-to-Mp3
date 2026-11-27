import 'dart:io';

import 'package:flutter_app/services/conversion/chapter_name_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the Rust overrides JSON and ignores malformed input', () {
    expect(parseChapterNames('{"names":{"2":"A Chegada","x":"no"}}'), {
      2: 'A Chegada',
    });
    expect(parseChapterNames(null), isEmpty);
    expect(parseChapterNames('{broken'), isEmpty);
  });

  test(
    'the store keeps one file per book and passes set/reset to Rust',
    () async {
      final dir = await Directory.systemTemp.createTemp('names');
      addTearDown(() => dir.delete(recursive: true));
      final calls = <(String, String?, String?)>[];
      final store = RustChapterNameStore(
        directory: () async => dir.path,
        call: (path, {index, name}) async {
          calls.add((path, index, name));
          return name == null ? '{"names":{}}' : '{"names":{"$index":"$name"}}';
        },
      );
      expect(await store.set('book/1', 3, 'Prólogo'), {3: 'Prólogo'});
      expect(await store.set('book/1', 3, null), isEmpty);
      expect(calls.first.$1, endsWith('book%2F1.json'));
      expect(calls.last, (calls.last.$1, '3', null));
    },
  );
}
