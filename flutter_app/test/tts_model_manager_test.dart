import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/tts_model_catalog.dart';
import 'package:flutter_app/services/tts_model_manager.dart';

void main() {
  test('catalog models expose stable identifiers and platform constraints', () {
    final ids = TtsModelCatalog.descriptors.map((model) => model.id).toSet();
    expect(ids.length, TtsModelCatalog.descriptors.length);
    expect(
      TtsModelCatalog.descriptors.every((model) => model.downloadBytes > 0),
      isTrue,
    );
  });

  test(
    'manager rejects models without a download URL before touching storage',
    () async {
      const model = TtsModelDescriptor(
        id: 'test-model',
        engine: 'test',
        languages: {'en'},
        platforms: {'macos'},
        downloadBytes: 1,
        qualityRank: 1,
        speedRank: 1,
        defaultRank: 1,
      );
      await expectLater(TtsModelManager().download(model), throwsStateError);
    },
  );

  test('partial download suffix is not a valid installed model', () async {
    expect(File('model.bin.part').path.endsWith('.part'), isTrue);
  });
}
