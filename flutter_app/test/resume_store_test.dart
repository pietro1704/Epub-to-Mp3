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

  test('saveBookPosition/loadBookPosition round-trip', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = ResumeStore(prefs);

    expect(store.loadBookPosition('book1'), null);

    await store.saveBookPosition('book1', 3, 123.45);
    final saved = store.loadBookPosition('book1');
    expect(saved, isNotNull);
    expect(saved!.chapter, 3);
    expect(saved.seconds, closeTo(123.45, 0.01));

    await store.saveBookPosition('book1', 5, 0.0);
    final updated = store.loadBookPosition('book1');
    expect(updated!.chapter, 5);
    expect(updated.seconds, 0.0);
  });
}
