import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/tts_preferences.dart';

/// Picks how much silence generated speech loses (applied by the shared Rust core).
class SilenceTrimField extends StatelessWidget {
  const SilenceTrimField({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final SilenceTrim value;
  final ValueChanged<SilenceTrim> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    String label(SilenceTrim level) => switch (level) {
      SilenceTrim.off => t.silenceTrimOff,
      SilenceTrim.light => t.silenceTrimLight,
      SilenceTrim.medium => t.silenceTrimMedium,
      SilenceTrim.strong => t.silenceTrimStrong,
    };
    return DropdownButtonFormField<SilenceTrim>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: t.silenceTrimLabel,
        helperText: t.silenceTrimDescription,
        helperMaxLines: 3,
      ),
      items: [
        for (final level in SilenceTrim.values)
          DropdownMenuItem(value: level, child: Text(label(level))),
      ],
      onChanged: (level) {
        if (level != null) onChanged(level);
      },
    );
  }
}
