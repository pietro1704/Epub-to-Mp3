import 'dart:async';
import 'dart:io';

import 'android_speech_fallback.dart';

/// Languages (any tag form, lower case, `-` separated) that the platform's own
/// speech engine can read, for the language model resolver. Each client
/// enumerates its own: Android TextToSpeech voices, eSpeak NG on Linux, SAPI on
/// Windows. Any failure means "none": system speech is then not offered.
Future<List<String>> enumerateSystemVoiceLanguages({
  Future<List<SpeechVoice>> Function()? androidVoices,
  Future<ProcessResult> Function(String executable, List<String> arguments)? run,
  bool? isAndroid,
  bool? isLinux,
  bool? isWindows,
}) async {
  final android = isAndroid ?? Platform.isAndroid;
  final linux = isLinux ?? Platform.isLinux;
  final windows = isWindows ?? Platform.isWindows;
  final runner = run ?? ((exe, args) => Process.run(exe, args));
  try {
    if (android) {
      final voices = await (androidVoices ?? AndroidSpeechFallback().listVoices)();
      return _unique(voices.map((voice) => voice.locale));
    }
    if (linux) {
      final result = await runner('espeak-ng', ['--voices']).timeout(const Duration(seconds: 5));
      return result.exitCode == 0 ? parseEspeakVoiceLanguages('${result.stdout}') : const [];
    }
    if (windows) {
      final result = await runner('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        _sapiScript,
      ]).timeout(const Duration(seconds: 10));
      return result.exitCode == 0 ? parseSapiLanguages('${result.stdout}') : const [];
    }
  } on Object {
    // Missing engine, no PowerShell, timeout: system speech is unavailable.
  }
  return const [];
}

// Installed SAPI voices expose their language as hexadecimal LCIDs ("409;9").
const _sapiScript =
    r"$v=New-Object -ComObject SAPI.SpVoice;"
    r"foreach($t in $v.GetVoices()){foreach($l in $t.GetAttribute('Language').Split(';')){"
    r"try{[System.Globalization.CultureInfo]::GetCultureInfo([Convert]::ToInt32($l,16)).Name}catch{}}}";

/// `espeak-ng --voices`: the language is the second column of each row; the
/// extra languages in parentheses at the end are ignored.
List<String> parseEspeakVoiceLanguages(String output) {
  final languages = <String>[];
  for (final line in output.split('\n').skip(1)) {
    final columns = line.trim().split(RegExp(r'\s+'));
    if (columns.length < 2) continue;
    languages.add(columns[1]);
  }
  return _unique(languages);
}

List<String> parseSapiLanguages(String output) =>
    _unique(output.split(RegExp(r'[\r\n]+')));

List<String> _unique(Iterable<String> tags) => {
  for (final tag in tags)
    if (tag.trim().isNotEmpty) tag.trim().replaceAll('_', '-').toLowerCase(),
}.toList();
