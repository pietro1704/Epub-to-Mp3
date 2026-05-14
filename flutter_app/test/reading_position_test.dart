import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/models/app_settings.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Reading position persistence', () {
    test('saves and loads chapter index per bookId', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final s = MirrorAppSettings(prefs);

      expect(s.savedChapterIndex('book-abc'), 0);
      await s.saveChapterIndex(5, 'book-abc');
      expect(s.savedChapterIndex('book-abc'), 5);
      expect(s.savedChapterIndex('book-xyz'), 0);
    });

    test('saves and loads page index per bookId', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final s = MirrorAppSettings(prefs);

      expect(s.savedPageIndex('book-abc'), 0);
      await s.savePageIndex(12, 'book-abc');
      expect(s.savedPageIndex('book-abc'), 12);
    });

    test('different books have independent positions', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final s = MirrorAppSettings(prefs);

      await s.saveChapterIndex(3, 'book-a');
      await s.saveChapterIndex(7, 'book-b');
      await s.savePageIndex(10, 'book-a');
      await s.savePageIndex(20, 'book-b');

      expect(s.savedChapterIndex('book-a'), 3);
      expect(s.savedChapterIndex('book-b'), 7);
      expect(s.savedPageIndex('book-a'), 10);
      expect(s.savedPageIndex('book-b'), 20);
    });
  });
}
