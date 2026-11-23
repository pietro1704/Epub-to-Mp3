import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Runs before every test file. Desktop `flutter test` registers the real
/// Linux/Windows preferences plugin, so without this a test that reads or
/// writes preferences would touch the developer's installed app profile.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  SharedPreferences.setMockInitialValues(const {});
  SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
  await testMain();
}
