import 'package:flutter/material.dart';

/// The "x / y" page indicator: the reader theme's own text color on the theme's solid
/// background (black on white in the light theme), no capsule. Contrast is the theme's
/// text/background contrast, which stays >= 4.5:1.
class ReaderPageIndicator extends StatelessWidget {
  const ReaderPageIndicator({
    super.key,
    required this.page,
    required this.pages,
    required this.background,
    required this.foreground,
  });

  final int page, pages;
  final Color background, foreground;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: background,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Text(
        '$page / $pages',
        style: TextStyle(
          fontSize: 12,
          color: foreground,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    ),
  );
}
