import 'package:flutter/material.dart';

class PlayerAdaptiveLayout extends StatelessWidget {
  const PlayerAdaptiveLayout({
    super.key,
    required this.header,
    required this.artwork,
    required this.controls,
  });
  final Widget header, artwork, controls;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final expanded = constraints.maxWidth >= 700;
      return Column(
        children: [
          header,
          Expanded(
            child: expanded
                ? Row(
                    key: const ValueKey('tablet-player-columns'),
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: artwork,
                        ),
                      ),
                      Expanded(child: SingleChildScrollView(child: controls)),
                    ],
                  )
                : Column(
                    key: const ValueKey('phone-player-stack'),
                    children: [
                      Expanded(child: artwork),
                      controls,
                    ],
                  ),
          ),
        ],
      );
    },
  );
}
