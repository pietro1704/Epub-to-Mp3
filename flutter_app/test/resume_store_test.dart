import 'package:flutter_app/services/resume_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('save/load round-trip', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = ResumeStore(prefs);
    await store.save('job1', 2, 42.5);
    expect(store.load('job1', 2), 42.5);
    expect(store.load('job1', 99), null);
    await store.clear('job1', 2);
    expect(store.load('job1', 2), null);
  });
}
