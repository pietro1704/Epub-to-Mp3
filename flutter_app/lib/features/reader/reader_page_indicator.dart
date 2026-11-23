import 'package:flutter/material.dart';

/// The "x / y" page indicator: full-strength text on an opaque pill tinted from
/// the text color, so it stays legible (contrast >= 4.5:1) on every reader theme.
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
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(10),
      // Opaque: the reader background tinted 12% toward the text color.
      color: Color.alphaBlend(foreground.withValues(alpha: 0.12), background),
    ),
    child: Text(
      '$page / $pages',
      style: TextStyle(
        fontSize: 12,
        color: foreground,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}
