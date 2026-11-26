import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/conversion/active_voice_log.dart';

/// Names the voice a running conversion is using, like the Apple conversion screen.
class ActiveVoiceLine extends StatelessWidget {
  const ActiveVoiceLine({super.key, required this.log});
  final String? log;

  @override
  Widget build(BuildContext context) {
    final voice = log == null ? null : activeVoiceFromLog(log!);
    if (voice == null) return const SizedBox.shrink();
    final t = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        voice.isSystem
            ? t.activeVoiceSystem(voice.name)
            : t.activeVoice(voice.name),
        key: const Key('conversion-active-voice'),
      ),
    );
  }
}
