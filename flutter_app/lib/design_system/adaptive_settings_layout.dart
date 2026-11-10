import 'package:flutter/material.dart';

/// Tablet settings expose two independently scrollable groups. Phones retain
/// the sequential grouped-list journey and never shrink both groups side by side.
class AdaptiveSettingsLayout extends StatelessWidget {
  const AdaptiveSettingsLayout({
    super.key,
    required this.narration,
    required this.preferences,
  });
  final List<Widget> narration, preferences;

  Widget _list(List<Widget> children) =>
      ListView(padding: const EdgeInsets.all(20), children: children);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 960) {
        return _list([...narration, ...preferences]);
      }
      return Row(
        key: const ValueKey('tablet-settings-columns'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _list(narration)),
          const VerticalDivider(width: 1),
          Expanded(child: _list(preferences)),
        ],
      );
    },
  );
}
