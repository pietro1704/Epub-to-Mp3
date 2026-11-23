import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/language_model_choices.dart';
import '../../models/language_model_resolution.dart';
import '../../models/tts_preferences.dart';
import '../conversion/embedded_converter.dart';

/// What the job should do about the narration, given the book language.
sealed class PlaybackNarration {
  const PlaybackNarration();
}

/// No per-language choice applies: the job uses today's preferences untouched.
final class UnchangedNarration extends PlaybackNarration {
  const UnchangedNarration();
}

/// Rust picked the narration for this language (a model, or the system voice).
final class ResolvedNarration extends PlaybackNarration {
  const ResolvedNarration(this.preferences, this.resolution);
  final TtsPreferences preferences;
  final LanguageModelResolution resolution;
}

/// Nothing usable for this language: the user is sent to the Models screen.
final class MissingNarration extends PlaybackNarration {
  const MissingNarration(this.language, this.suggested);
  final String language;
  final List<SuggestedModel> suggested;
}

/// Language analysis per book, kept in memory and in preferences so the book is
/// parsed once. An entry is reused only while the file is the same size and
/// was last modified at the same time.
class BookLanguageCache {
  BookLanguageCache(this._prefs);

  static const storageKey = 'bookLanguageAnalysis.v1';

  final SharedPreferences _prefs;
  final Map<String, ({String stamp, BookLanguageAnalysis analysis})> _memory = {};

  Future<BookLanguageAnalysis> analysis({
    required EmbeddedConverter converter,
    required String bookId,
    required String path,
  }) async {
    final stamp = _stamp(path);
    final cached = _memory[bookId] ?? _stored(bookId);
    if (cached != null && cached.stamp == stamp) {
      _memory[bookId] = cached;
      return cached.analysis;
    }
    final analysis = await converter.bookLanguage(path);
    _memory[bookId] = (stamp: stamp, analysis: analysis);
    await _store(bookId, stamp, analysis);
    return analysis;
  }

  String _stamp(String path) {
    final stat = File(path).statSync();
    return '${stat.size}-${stat.modified.millisecondsSinceEpoch}';
  }

  Map<String, dynamic> _all() {
    try {
      final decoded = jsonDecode(_prefs.getString(storageKey) ?? '{}');
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on FormatException {
      return {};
    }
  }

  ({String stamp, BookLanguageAnalysis analysis})? _stored(String bookId) {
    final entry = _all()[bookId];
    if (entry is! Map) return null;
    try {
      return (
        stamp: entry['stamp'] as String,
        analysis: BookLanguageAnalysis.fromJson(
          Map<String, dynamic>.from(entry['analysis'] as Map),
        ),
      );
    } on Object {
      return null;
    }
  }

  Future<void> _store(String bookId, String stamp, BookLanguageAnalysis analysis) {
    final all = _all();
    all[bookId] = {'stamp': stamp, 'analysis': analysis.toJson()};
    return _prefs.setString(storageKey, jsonEncode(all));
  }
}

/// Decides the narration of a NEW playback job from the book's language.
///
/// The resolution is Rust's (`converter_tts_resolve_language_model_json_v1`) and
/// runs for every new job except one whose narration the user selected
/// explicitly ([explicitSelection]). The result is [UnchangedNarration], i.e.
/// exactly what a job did before, whenever the configured primary already
/// narrates this book language, and also when the language is not confirmed,
/// the analysis fails or the status is unknown. For a book in another language
/// Rust picks the best installed local model, then the system voice (when the
/// user's policy permits it and the platform has one), else the job is refused
/// with [MissingNarration]. Nothing here downloads anything.
Future<PlaybackNarration> resolvePlaybackNarration({
  required EmbeddedConverter converter,
  required BookLanguageCache cache,
  required String bookId,
  required String bookPath,
  required TtsPreferences configured,
  required LanguageModelChoices choices,
  required Future<Set<String>> Function() installedModelIds,
  required Future<List<String>> Function() systemVoices,
  required String platform,
  int? androidApi,
  bool explicitSelection = false,
}) async {
  if (explicitSelection) return const UnchangedNarration();
  try {
    final analysis = await cache.analysis(
      converter: converter,
      bookId: bookId,
      path: bookPath,
    );
    final language = analysis.confirmed;
    if (language == null) return const UnchangedNarration();
    final primary = configured.primary;
    final automaticPrimary = primary.representsSameRequest(TtsSelection.automaticPiper);
    final resolution = await converter.resolveLanguageModel(
      LanguageModelRequest(
        bookLanguage: language,
        platform: platform,
        androidApi: androidApi,
        perLanguageChoices: choices.byLanguage,
        // The automatic Piper entry is not a model id: Rust ranks installed ones.
        primary: automaticPrimary ? null : primary,
        allowOnlineFallback: configured.allowOnlineFallback,
        // Policy 2 is the one that lets the installed system voice stand in.
        allowAutomaticSystemVoiceFallback: configured.policyVersion == 2,
        installedModelIds: (await installedModelIds()).toList()..sort(),
        systemVoices: await systemVoices(),
      ),
    );
    final selection = resolution.selection;
    switch (resolution.status) {
      case LanguageModelStatus.selected:
        if (selection == null) return const UnchangedNarration();
        // The configured primary (or the automatic Piper entry, which ranks
        // installed models by language the same way) already narrates this
        // book: the job is exactly what it was.
        if (resolution.source == 'primary' ||
            (automaticPrimary && resolution.source == 'automatic') ||
            selection.representsSameRequest(primary)) {
          return const UnchangedNarration();
        }
        return ResolvedNarration(configured.withPrimary(selection), resolution);
      case LanguageModelStatus.systemFallback:
        if (selection == null) return const UnchangedNarration();
        return ResolvedNarration(configured.withPrimary(selection), resolution);
      case LanguageModelStatus.missingModel:
        return MissingNarration(
          resolution.missing?.language ?? LanguageModelChoices.baseLanguage(language),
          resolution.missing?.suggested ?? const [],
        );
      case LanguageModelStatus.unknown:
        return const UnchangedNarration();
    }
  } on Object catch (error) {
    // Language analysis is an enhancement: never block listening because it failed.
    debugPrint('Language model resolution skipped: $error');
    return const UnchangedNarration();
  }
}
