import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../models/ebook_fulltext.dart';

/// Maximum heading size relative to the user-chosen body font. Mirrors
/// iOS `EpubHtmlRenderer` (commit 8485ab2). Pure helper so it can be
/// unit-tested without a Flutter binding.
double cappedHeadingSize(double bodyFontSize, {double scale = 1.5}) {
  // Designed heading wants body + 6pt; the cap clamps it to bodyFontSize * scale.
  final designed = bodyFontSize + 6;
  final maximum = bodyFontSize * scale;
  return designed < maximum ? designed : maximum;
}

/// Content equality for two span lists. Mirrors the iOS reader's
/// CONTENT-vs-pointer gate (TextKitPageView.swift, commit d473109): a
/// re-render that rebuilds the spans list with fresh-but-identical
/// instances must NOT trigger a repagination/relayout (which flickers).
/// `SentenceSpan` is a freezed value type, so `==` compares by content;
/// `identical()` would return false on a freshly-built equal list and
/// fire a needless relayout. Pure helper so it can be unit-tested
/// without a Flutter binding.
bool spansContentEqual(List<SentenceSpan> a, List<SentenceSpan> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Convert the persisted `ReaderTextAlignment` enum to Flutter's
/// `TextAlign`. Default `.justified` matches Apple Books / print
/// typography.
TextAlign flutterTextAlign(ReaderTextAlignment a) {
  switch (a) {
    case ReaderTextAlignment.justified:
      return TextAlign.justify;
    case ReaderTextAlignment.left:
      return TextAlign.left;
  }
}
