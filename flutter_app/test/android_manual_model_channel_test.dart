import 'package:flutter/services.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final ManualTtsModelCatalog converter = AndroidEmbeddedConverter(
    channel: channel,
  );
  const root = '/app/models';
  const modelId = 'pt_BR-edresson-low';

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('manual catalog and probe send explicit native requests', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'ttsManualModels'
          ? '{"models":[]}'
          : '{"ready":true}';
    });

    expect(await converter.ttsManualModels(root: root), '{"models":[]}');
    expect(
      await converter.probeTtsModel(modelId: modelId, root: root),
      '{"ready":true}',
    );
    expect(calls.map((call) => call.method), [
      'ttsManualModels',
      'ttsProbeModel',
    ]);
    expect(calls[0].arguments, {'root': root});
    expect(calls[1].arguments, {'modelId': modelId, 'root': root});
  });

  test(
    'empty manual native results surface an unavailable converter',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => '');

      await expectLater(
        converter.ttsManualModels(root: root),
        throwsA(isA<EmbeddedConverterUnavailable>()),
      );
      await expectLater(
        converter.probeTtsModel(modelId: modelId, root: root),
        throwsA(isA<EmbeddedConverterUnavailable>()),
      );
    },
  );
}
