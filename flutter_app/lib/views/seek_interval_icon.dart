import 'package:flutter/material.dart';

/// Material's built-in numbered seek icons omit 15 seconds. Keep the visible
/// interval equal to the transport action instead of displaying a false 10.
class SeekIntervalIcon extends StatelessWidget {
  const SeekIntervalIcon({super.key, required this.forward, this.seconds = 15, this.size = 24});
  final bool forward;
  final int seconds;
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(width: size, height: size, child: Stack(alignment: Alignment.center, children: [
      Transform.flip(flipX: forward, child: Icon(Icons.replay, size: size)),
      Padding(padding: EdgeInsets.only(top: size * 0.12), child: Text('$seconds',
        style: TextStyle(fontSize: size * 0.35, fontWeight: FontWeight.w600, height: 1))),
    ])),
  );
}
