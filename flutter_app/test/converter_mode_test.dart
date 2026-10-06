import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  test('product conversion mode is always embedded Rust', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(converterModeProvider), ConverterMode.embedded);
  });
}
