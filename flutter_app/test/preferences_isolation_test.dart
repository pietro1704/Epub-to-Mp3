import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tests start with in-memory preferences, never the real app profile', () async {
    expect(SharedPreferencesStorePlatform.instance, isA<InMemorySharedPreferencesStore>());
    expect(SharedPreferencesAsyncPlatform.instance, isA<InMemorySharedPreferencesAsync>());
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty, reason: 'no installed-app values may leak into tests');
  });
}
