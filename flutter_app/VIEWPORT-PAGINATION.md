# Flutter viewport pagination

`ReaderView` paginates using the committed `LayoutBuilder` constraints, physical
safe-area padding, reader margins and the actual Material text style/scaler.
`ViewportPaginator` measures complete rendered lines, including span padding and
the first-page chapter header. Long sentences may span pages while retaining their
sentence ID, raw Unicode scalar ranges and complete source text.

Repagination keeps the page containing the previous raw source anchor. An
impossible text viewport or oversized chapter header uses the existing scrolling
surface, retaining the full source. Listening anchors follow the mounted surface;
the fallback cannot report the retired paginated page as its current position.
The scrolling renderer, chapter identity and explicit page-turn callbacks keep
their existing ownership.

Focused verification on authorized Arch:

```sh
mise run flutter:test -- test/viewport_paginator_test.dart test/views/reader_view_fit_test.dart test/views/reader_listening_anchor_test.dart test/reader_chapter_cross_flicker_test.dart test/reader_center_tap_test.dart
```

Coverage includes real Material rendering at 24pt, enlarged text, viewport
changes, every page through the chapter end, raw-anchor retention, impossible
geometry fallback, RTL layout and accented/emoji source fidelity. The original
character-estimate paginator required 24,208px of vertical scrolling for the
authored single-paragraph regression; its runtime fit assertion fails before
this change. These Flutter checks do not establish Apple native-reader,
physical-device or whole-app audible acceptance.
