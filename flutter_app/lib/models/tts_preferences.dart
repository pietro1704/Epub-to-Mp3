import 'dart:convert';

import 'tts_session_selection.dart';

bool isLowQualityPiperModel(String engine, String? modelId) {
  if (engine != 'piper' || modelId == null) return false;
  final stem = modelId.trim().toLowerCase().split('.').first;
  return stem == 'low' || stem.endsWith('-low') || stem.endsWith('_low');
}

/// Immutable provider selection captured when a conversion starts.
class TtsSelection {
  const TtsSelection({
    required this.engine,
    this.modelId,
    this.voice,
    this.session,
    this.manualModel = false,
  });
  final String engine;
  final String? modelId;
  final String? voice;
  final TtsSessionSelection? session;
  final bool manualModel;

  bool get hasManualPiperIdentity {
    final identity = session;
    return manualModel &&
        engine == 'piper' &&
        modelId?.trim().isNotEmpty == true &&
        identity?.provider == engine &&
        identity?.runtime == 'piper' &&
        identity?.modelId == modelId &&
        identity?.modelRevision?.trim().isNotEmpty == true;
  }

  bool representsSameRequest(TtsSelection other) {
    if (engine != other.engine ||
        modelId != other.modelId ||
        voice != other.voice) {
      return false;
    }
    final first = session;
    final second = other.session;
    if ((manualModel || other.manualModel) &&
        first?.modelRevision != null &&
        second?.modelRevision != null &&
        first?.modelRevision != second?.modelRevision) {
      return false;
    }
    if (first != null && second != null && first.runtime != second.runtime) {
      return false;
    }
    final options = first?.options ?? const <String, String>{};
    final otherOptions = second?.options ?? const <String, String>{};
    return options.length == otherOptions.length &&
        options.entries.every(
          (entry) => otherOptions[entry.key] == entry.value,
        );
  }

  static const automaticPiper = TtsSelection(
    engine: 'piper',
    modelId: 'piper-auto',
  );
  static const faber = TtsSelection(
    engine: 'piper',
    modelId: 'pt_BR-faber-medium',
  );
  static const edge = TtsSelection(engine: 'edge');
  static const system = TtsSelection(engine: 'system');
  String get displayName => [
    engine == 'piper'
        ? 'Piper'
        : engine == 'edge'
        ? 'Edge'
        : engine,
    modelId,
    voice,
  ].whereType<String>().join(' · ');
  Map<String, dynamic> toJson({bool includeManualModel = true}) => {
    'engine': engine,
    'model_id': modelId,
    'voice': voice,
    if (session != null) 'session': session!.toJson(),
    if (includeManualModel && manualModel) 'manual_model': true,
  };
  factory TtsSelection.fromJson(Map<String, dynamic> json) => TtsSelection(
    engine: json['engine'] as String,
    modelId: json['model_id'] as String?,
    voice: json['voice'] as String?,
    session: json['session'] == null
        ? null
        : TtsSessionSelection.fromJson(
            Map<String, dynamic>.from(json['session'] as Map),
          ),
    manualModel: json['manual_model'] == true,
  );
}

/// How the narration treats footnotes (decided and applied by the shared Rust core).
/// `inline` reads each note at its reference; `skip` leaves the notes out.
enum FootnoteNarration { inline, skip }

class TtsPreferences {
  /// Use supported app choices without rewriting a saved preference or job.
  TtsPreferences withSupportedPiperQuality() {
    bool isLow(TtsSelection selection) => isLowQualityPiperModel(
      selection.engine,
      selection.modelId ?? selection.session?.modelId,
    );
    final savedSecondary = secondary;
    final primaryIsLow = isLow(primary) && !primary.hasManualPiperIdentity;
    final secondaryIsLow = savedSecondary != null && isLow(savedSecondary);
    if (!primaryIsLow && !secondaryIsLow) return this;
    return TtsPreferences(
      primary: primaryIsLow ? TtsSelection.automaticPiper : primary,
      secondary: secondaryIsLow ? null : savedSecondary,
      allowOnlineFallback: allowOnlineFallback,
      policyVersion: policyVersion,
      footnoteNarration: footnoteNarration,
    );
  }

  TtsPreferences withPrimary(TtsSelection selection) => TtsPreferences(
    primary: selection,
    secondary: secondary?.representsSameRequest(selection) == true
        ? null
        : secondary,
    allowOnlineFallback: allowOnlineFallback,
    policyVersion: policyVersion,
    footnoteNarration: footnoteNarration,
  );

  TtsPreferences withFootnoteNarration(FootnoteNarration value) =>
      TtsPreferences(
        primary: primary,
        secondary: secondary,
        allowOnlineFallback: allowOnlineFallback,
        policyVersion: policyVersion,
        footnoteNarration: value,
      );

  /// Policy 2 continues with an installed system voice when the chosen voices
  /// fail; policy 3 continues natively but only with the chosen voices.
  bool get allowAutomaticSystemFallback => policyVersion == 2;

  TtsPreferences withAutomaticSystemFallback(bool allowed) => TtsPreferences(
    primary: primary,
    secondary: secondary,
    allowOnlineFallback: allowOnlineFallback,
    policyVersion: allowed ? 2 : 3,
    footnoteNarration: footnoteNarration,
  );

  const TtsPreferences({
    this.primary = TtsSelection.faber,
    this.secondary,
    this.allowOnlineFallback = false,
    this.policyVersion = 1,
    this.footnoteNarration = FootnoteNarration.inline,
  });

  /// New app preferences only; legacy jobs retain their captured strict policy.
  const TtsPreferences.appDefaults({this.primary = TtsSelection.automaticPiper})
    : secondary = TtsSelection.system,
      allowOnlineFallback = false,
      policyVersion = 2,
      footnoteNarration = FootnoteNarration.inline;
  final TtsSelection primary;
  final TtsSelection? secondary;
  final bool allowOnlineFallback;
  final int policyVersion;
  final FootnoteNarration footnoteNarration;
  Map<String, dynamic> toJson({bool includeManualModel = true}) => {
    'primary': primary.toJson(includeManualModel: includeManualModel),
    'secondary': secondary?.toJson(includeManualModel: includeManualModel),
    'allow_online_fallback': allowOnlineFallback,
    if (policyVersion != 1) 'policy_version': policyVersion,
    if (footnoteNarration != FootnoteNarration.inline)
      'footnote_narration': footnoteNarration.name,
  };
  factory TtsPreferences.fromJson(Map<String, dynamic> json) => TtsPreferences(
    primary: TtsSelection.fromJson(
      Map<String, dynamic>.from(json['primary'] as Map),
    ),
    secondary: json['secondary'] == null
        ? null
        : TtsSelection.fromJson(
            Map<String, dynamic>.from(json['secondary'] as Map),
          ),
    allowOnlineFallback: json['allow_online_fallback'] == true,
    policyVersion: json['policy_version'] as int? ?? 1,
    footnoteNarration: json['footnote_narration'] == 'skip'
        ? FootnoteNarration.skip
        : FootnoteNarration.inline,
  );
  String optionsJson({String? modelsRoot, String? language}) => jsonEncode({
    if (primary.session != null || secondary?.session != null)
      'contract_version': 2,
    'tts_preferences': toJson(includeManualModel: false),
    'models_root': ?modelsRoot,
    'language': ?language,
  });
}
