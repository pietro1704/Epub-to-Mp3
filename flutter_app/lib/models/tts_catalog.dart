import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'tts_preferences.dart';
import 'tts_session_selection.dart';

class TtsCatalog {
  TtsCatalog._(
    this.models,
    this.providers,
    this.androidApi,
    this.defaultSelection,
    this._manual,
  );
  final List<Map<String, dynamic>> models;
  final List<Map<String, dynamic>> providers;
  final int? androidApi;
  final TtsSelection? defaultSelection;
  final bool _manual;

  TtsPreferences get recommendedPreferences => const TtsPreferences.appDefaults();
  factory TtsCatalog.decode(String json) => _decode(json, manual: false);

  factory TtsCatalog.decodeManual(String json) => _decode(json, manual: true);

  static bool _isLow(Map<dynamic, dynamic> entry) {
    final identity = entry['identity'] as Map;
    final engine = identity['provider'] as String;
    final presentation = entry['presentation'];
    return (engine == 'piper' && presentation is Map && presentation['quality'] == 'low') ||
        isLowQualityPiperModel(engine, identity['model_id'] as String?);
  }

  static TtsCatalog _decode(String json, {required bool manual}) {
    final decoded = jsonDecode(json);
    if (decoded is! Map || decoded['schema_version'] != 3) {
      throw const FormatException('Unsupported TTS catalog version');
    }
    final entries = decoded['entries'];
    final providers = decoded['providers'];
    if (entries is! List || providers is! List) {
      throw const FormatException('Invalid TTS model catalog');
    }
    final models = entries.where((entry) => manual || !_isLow(entry as Map)).map((entry) {
      final identity = entry['identity'] as Map;
      final compatibility = entry['compatibility'] as Map;
      final distribution = entry['distribution'] as Map;
      return Map<String, dynamic>.unmodifiable({
        'id': identity['model_id'], 'engine': identity['provider'],
        'runtime': identity['runtime'], 'revision': identity['model_revision'],
        'languages': entry['language_evidence']['routing_tags'],
        'platforms': compatibility['platforms'],
        'minimum_android_api': compatibility['minimum_android_api'],
        'runtime_available': compatibility['runtime_available'],
        'artifacts': distribution['artifacts'],
        'download_bytes': distribution['download_bytes'],
        if (manual) ...{
          'low': _isLow(entry as Map),
          'installable': distribution['installable'],
          'installation': entry['installation'],
          'readiness': entry['readiness'],
          'selection': entry['selection'],
        },
      });
    });
    final target = decoded['target'];
    final defaultValue = manual ? null : decoded['default_selection'];
    final session = defaultValue == null
        ? null
        : TtsSessionSelection.fromJson(
            Map<String, dynamic>.from(defaultValue as Map),
          );
    return TtsCatalog._(
      List.unmodifiable(models),
      List.unmodifiable(providers.map((value) => Map<String, dynamic>.from(value as Map))),
      decoded['android_api'] as int? ?? (target is Map ? target['android_api'] as int? : null),
      session == null ||
              isLowQualityPiperModel(session.provider, session.modelId)
          ? null
          : TtsSelection(
              engine: session.provider,
              modelId: session.modelId,
              voice: session.voice,
              session: session,
            ),
      manual,
    );
  }
  /// Capture new jobs only. Persisted requests keep their original wire identity.
  TtsPreferences captureNewPreferences(TtsPreferences preferences, {String? target}) {
    final choices = selections(target: target);
    TtsSelection capture(TtsSelection selected) {
      if (selected.session != null || selected.modelId == null) return selected;
      final matches = choices.where((choice) => choice.engine == selected.engine && choice.modelId == selected.modelId);
      if (matches.isEmpty) return selected;
      final resolved = matches.first.session!;
      return TtsSelection(engine: selected.engine, modelId: selected.modelId, voice: selected.voice,
        session: TtsSessionSelection(provider: resolved.provider, runtime: resolved.runtime,
          modelId: resolved.modelId, modelRevision: resolved.modelRevision, voice: selected.voice,
          options: resolved.options));
    }
    return TtsPreferences(primary: capture(preferences.primary),
      secondary: preferences.secondary == null ? null : capture(preferences.secondary!),
      allowOnlineFallback: preferences.allowOnlineFallback, policyVersion: preferences.policyVersion,
      footnoteNarration: preferences.footnoteNarration);
  }
  List<TtsSelection> selections({String? target, int? androidApi}) {
    return _selections(target: target, androidApi: androidApi, includeLow: false);
  }

  /// Models offered only by the separately requested manual catalog.
  List<TtsSessionSelection> manualModels({String? target, int? androidApi}) {
    if (!_manual) return const [];
    return _selections(target: target, androidApi: androidApi, includeLow: true)
        .map((selection) => selection.session!)
        .where((identity) =>
            identity.provider == 'piper' &&
            identity.runtime == 'piper' &&
            identity.modelRevision?.trim().isNotEmpty == true)
        .toList(growable: false);
  }

  List<Map<String, dynamic>> get lowDownloadModels {
    final supported = manualModels().map((identity) => identity.modelId).toSet();
    return models.where((entry) =>
        entry['low'] == true &&
        entry['installable'] == true &&
        supported.contains(entry['id'])).toList(growable: false);
  }

  List<TtsSessionSelection> installedLowModels() => manualModels().where((identity) {
    final entry = _manualEntry(identity);
    final installation = entry['installation'];
    return entry['low'] == true && installation is Map &&
        installation['state'] == 'installed' &&
        installation['verified_revision'] == identity.modelRevision;
  }).toList(growable: false);

  String manualModelLanguage(TtsSessionSelection identity) {
    final languages = _manualEntry(identity)['languages'];
    if (languages is List) {
      for (final language in languages) {
        if (language is String && language.trim().isNotEmpty) return language;
      }
    }
    throw StateError('The requested model has no routing language');
  }

  Map<String, dynamic> _manualEntry(TtsSessionSelection identity) => models.singleWhere((entry) =>
      entry['engine'] == identity.provider && entry['runtime'] == identity.runtime &&
      entry['id'] == identity.modelId && entry['revision'] == identity.modelRevision);

  /// This snapshot comes from probing the specific model chosen by the user.
  TtsSelection confirmedManualModel(TtsSessionSelection requested, {String? target, int? androidApi}) {
    final ids = manualModels(target: target, androidApi: androidApi).where((identity) =>
        identity.provider == requested.provider &&
        identity.runtime == requested.runtime &&
        identity.modelId == requested.modelId &&
        identity.modelRevision == requested.modelRevision);
    final entries = models.where((entry) =>
        entry['engine'] == requested.provider &&
        entry['runtime'] == requested.runtime &&
        entry['id'] == requested.modelId &&
        entry['revision'] == requested.modelRevision);
    if (ids.length != 1 || entries.length != 1) {
      throw StateError('The requested model identity is unavailable');
    }
    final entry = entries.single;
    final installation = entry['installation'];
    final readiness = entry['readiness'];
    final selection = entry['selection'];
    if (installation is! Map || installation['state'] != 'installed' ||
        installation['verified_revision'] != requested.modelRevision ||
        readiness is! Map || readiness['state'] != 'ready' ||
        selection is! Map || selection['selectable'] != true) {
      throw StateError('The requested model is not ready');
    }
    return TtsSelection(
      engine: requested.provider,
      modelId: requested.modelId,
      session: ids.single,
      manualModel: true,
    );
  }

  List<TtsSelection> _selections({String? target, int? androidApi, required bool includeLow}) {
    final platform = target ?? switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android', TargetPlatform.iOS => 'Ios',
      TargetPlatform.macOS => 'Macos', TargetPlatform.windows => 'Windows',
      TargetPlatform.linux => 'Linux', TargetPlatform.fuchsia => 'Fuchsia',
    };
    return [
    for (final model in models)
      if (includeLow || model['low'] != true)
      if (model['runtime'] is String && model['runtime_available'] == true)
        if (model['platforms'] is! List || (model['platforms'] as List).contains(platform))
          if (platform != 'Android' || model['minimum_android_api'] == null || (model['minimum_android_api'] as int) <= (androidApi ?? this.androidApi ?? 21))
            if (providers.any((provider) => provider['provider'] == model['engine'] && provider['runtime'] == model['runtime'] &&
              (provider['targets'] as List?)?.contains(platform.toLowerCase()) == true &&
              (provider['capabilities'] as Map?)?['audio_bytes'] == true))
        TtsSelection(engine: model['engine'] as String, modelId: model['id'] as String,
          session: TtsSessionSelection(provider: model['engine'] as String, runtime: model['runtime'] as String,
            modelId: model['id'] as String, modelRevision: model['revision'] as String?)),
  ]; }
}
