import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform, Process, ProcessResult;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/ebook_fulltext.dart';

/// Bridges Dart to the Python pipeline (`python_app/src/...`).
///
/// Three runtime modes, picked at call time:
///
/// * **Android** — embedded CPython via Chaquopy. The Kotlin side
///   (`MainActivity.kt`) handles `Python.getInstance()` and invokes the
///   functions in `python_app.src.android_entrypoints`. Talks to Dart
///   over the `epub_to_mp3/python` MethodChannel. (See
///   `flutter_app/PYTHON-EMBED-ANDROID.md`.)
/// * **Linux / Windows desktop** — system Python 3.10+. The Flutter
///   bundle ships `python_app/src/` as an asset; on first call we extract
///   it to a temp dir, then invoke `python3 -c '...'` (or `python` on
///   Windows) as a subprocess and parse JSON off stdout. No native
///   plugin / FFI — see `feat/desktop-python-embed`.
/// * **iOS / macOS** — the Flutter app does not target Apple platforms;
///   the SwiftUI app (`ios/EpubToMp3/`) owns that surface and embeds
///   Python via PythonKit. `isSupported` reports `false` and all calls
///   throw [UnsupportedError].
class PythonBridge {
  PythonBridge._();
  static final PythonBridge instance = PythonBridge._();
  factory PythonBridge() => instance;

  static const MethodChannel _channel = MethodChannel('epub_to_mp3/python');

  // Lazily-resolved desktop state. Populated on first desktop call.
  String? _desktopPythonAppPath;
  String? _desktopPythonExe;

  // ---------------------------------------------------------------- helpers

  bool get _isDesktop {
    if (kIsWeb) return false;
    try {
      return Platform.isLinux || Platform.isWindows;
    } catch (_) {
      return false;
    }
  }

  bool get _isAndroid {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// True only where this bridge can actually execute Python. On
  /// unsupported platforms (iOS, macOS, web) callers should fall back to
  /// the remote FastAPI backend.
  bool get isSupported => _isAndroid || _isDesktop;

  // ---------------------------------------------------------------- public

  /// Boots the Python runtime and confirms it responds. Returns the
  /// Python `sys.version` string on success.
  Future<String> bootstrap() async {
    if (_isDesktop) {
      await _ensureDesktopPython();
      final result = await _runDesktopScript(
        'import sys; '
        'sys.path.insert(0, __import__("os").environ["PYTHONPATH"]); '
        'from python_app.src.android_entrypoints import bootstrap; '
        'import json; print(json.dumps({"version": bootstrap()}))',
      );
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      return decoded['version'] as String;
    }
    // Android path (and any host where the MethodChannel is mocked,
    // e.g. unit tests on macOS) — Chaquopy answers on Android, the
    // mock answers in tests.
    final result = await _channel.invokeMethod<String>('bootstrap');
    if (result == null || result.isEmpty) {
      throw StateError('PythonBridge.bootstrap returned empty payload');
    }
    return result;
  }

  /// Parses an EPUB / PDF located at [filePath] off the main isolate
  /// and decodes the resulting JSON payload into an [EbookFulltext].
  Future<EbookFulltext> parseEpub(String filePath, {String jobId = ''}) async {
    if (_isDesktop) {
      await _ensureDesktopPython();
      // Pass the file path via stdin (NUL-terminated) so we don't have
      // to shell-escape paths with spaces, quotes, or non-ASCII chars.
      final raw = await _runDesktopScript(
        'import sys, os; '
        'sys.path.insert(0, os.environ["PYTHONPATH"]); '
        'path = sys.stdin.read(); '
        'from python_app.src.android_entrypoints import parse_epub_to_json; '
        'sys.stdout.write(parse_epub_to_json(path))',
        stdinPayload: filePath,
      );
      return _decodeFulltext(raw, jobId);
    }
    // Android (or test host) — MethodChannel path.
    final raw = await _channel.invokeMethod<String>(
      'parseEpub',
      <String, dynamic>{'path': filePath},
    );
    return _decodeFulltext(raw, jobId);
  }

  // ---------------------------------------------------------------- decode

  EbookFulltext _decodeFulltext(String? raw, String jobId) {
    if (raw == null || raw.isEmpty) {
      throw StateError('PythonBridge.parseEpub returned empty payload');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'PythonBridge.parseEpub: expected JSON object, got ${decoded.runtimeType}',
      );
    }
    if (jobId.isNotEmpty) {
      decoded['jobId'] = jobId;
    }
    return EbookFulltext.fromJson(decoded);
  }

  // ---------------------------------------------------------------- desktop

  /// Resolves the path to the extracted `python_app/` asset directory.
  /// Override in tests via [debugSetDesktopPythonAppPath]; otherwise we
  /// copy the bundled assets to the OS temp dir on first use.
  Future<String> _ensureDesktopPython() async {
    if (_desktopPythonAppPath != null && _desktopPythonExe != null) {
      return _desktopPythonAppPath!;
    }

    _desktopPythonExe ??= await _resolvePythonExecutable();
    _desktopPythonAppPath ??= await _extractAssets();
    return _desktopPythonAppPath!;
  }

  /// Probes `python3 --version` (or `python --version` on Windows) and
  /// returns the executable name. Throws a clear [StateError] if Python
  /// is missing or older than 3.10.
  Future<String> _resolvePythonExecutable() async {
    final candidates = Platform.isWindows
        ? <String>['python', 'python3', 'py']
        : <String>['python3', 'python'];
    for (final exe in candidates) {
      try {
        final probe = await Process.run(exe, <String>['--version']);
        if (probe.exitCode != 0) continue;
        final out = (probe.stdout as String).trim().isEmpty
            ? (probe.stderr as String).trim()
            : (probe.stdout as String).trim();
        final match = RegExp(r'Python (\d+)\.(\d+)').firstMatch(out);
        if (match == null) continue;
        final major = int.parse(match.group(1)!);
        final minor = int.parse(match.group(2)!);
        if (major < 3 || (major == 3 && minor < 10)) continue;
        return exe;
      } catch (_) {
        continue;
      }
    }
    throw StateError(
      'Python 3.10+ not found on PATH. Install it from '
      'https://www.python.org/downloads/ or your distribution package '
      'manager (apt install python3, winget install Python.Python.3.13, '
      'etc.) and restart the app.',
    );
  }

  /// Copies the bundled `assets/python_app/` tree to a stable cache
  /// directory under the app's support dir. Re-runs only if the
  /// destination is missing — assets are baked into the bundle so they
  /// can't change at runtime.
  Future<String> _extractAssets() async {
    final supportDir = await getApplicationSupportDirectory();
    final dest = Directory('${supportDir.path}/python_app');
    final marker = File('${dest.path}/.bootstrapped');
    if (await marker.exists()) {
      return dest.path;
    }
    if (await dest.exists()) {
      await dest.delete(recursive: true);
    }
    await dest.create(recursive: true);

    final manifestRaw = await rootBundle.loadString('AssetManifest.json');
    final manifest = jsonDecode(manifestRaw) as Map<String, dynamic>;
    const prefix = 'assets/python_app/';
    final assets = manifest.keys.where((k) => k.startsWith(prefix));
    if (assets.isEmpty) {
      throw StateError(
        'No assets/python_app/ resources bundled. Run '
        '`mise run desktop:bootstrap-python` before building.',
      );
    }
    for (final assetKey in assets) {
      final rel = assetKey.substring(prefix.length); // e.g. src/foo.py
      final file = File('${dest.path}/$rel');
      await file.parent.create(recursive: true);
      final bytes = await rootBundle.load(assetKey);
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    }
    // Ensure both python_app and python_app.src expose __init__.py — the
    // bootstrap script writes them, but assets/path traversal may strip
    // empty files; guard regardless.
    await File('${dest.path}/__init__.py').writeAsString('');
    final srcDir = Directory('${dest.path}/src');
    if (await srcDir.exists()) {
      await File('${srcDir.path}/__init__.py').writeAsString('');
    }
    await marker.writeAsString(DateTime.now().toIso8601String());
    return dest.path;
  }

  /// Runs a one-shot Python script. The extracted `python_app/` lives
  /// directly under [_desktopPythonAppPath]; PYTHONPATH is set to the
  /// PARENT directory so `from python_app.src... import ...` works.
  Future<String> _runDesktopScript(
    String script, {
    String? stdinPayload,
  }) async {
    final exe = _desktopPythonExe!;
    final pythonAppDir = Directory(_desktopPythonAppPath!);
    final pythonPath = pythonAppDir.parent.path;

    final proc = await Process.start(
      exe,
      <String>['-c', script],
      environment: <String, String>{
        ...Platform.environment,
        'PYTHONPATH': pythonPath,
        'PYTHONUNBUFFERED': '1',
        'PYTHONIOENCODING': 'utf-8',
      },
      runInShell: false,
    );

    if (stdinPayload != null) {
      proc.stdin.write(stdinPayload);
    }
    await proc.stdin.close();

    final stdoutFut = proc.stdout.transform(utf8.decoder).join();
    final stderrFut = proc.stderr.transform(utf8.decoder).join();
    final exitCode = await proc.exitCode;
    final stdoutStr = await stdoutFut;
    final stderrStr = await stderrFut;

    if (exitCode != 0) {
      throw StateError(
        'Python subprocess failed (exit $exitCode): '
        '${stderrStr.trim().isEmpty ? stdoutStr.trim() : stderrStr.trim()}',
      );
    }
    return stdoutStr;
  }

  // ---------------------------------------------------------------- debug

  /// Test hook — pre-seeds the desktop state so tests can stub the
  /// subprocess invocation via a fake `python` executable on PATH.
  @visibleForTesting
  void debugSetDesktopRuntime({
    required String pythonExecutable,
    required String pythonAppPath,
  }) {
    _desktopPythonExe = pythonExecutable;
    _desktopPythonAppPath = pythonAppPath;
  }

  /// Test hook — clears cached desktop state.
  @visibleForTesting
  void debugResetDesktopRuntime() {
    _desktopPythonExe = null;
    _desktopPythonAppPath = null;
  }

  /// Test hook — exposes the resolved executable for assertions. Returns
  /// `null` if [_ensureDesktopPython] hasn't run yet.
  @visibleForTesting
  String? get debugDesktopPythonExe => _desktopPythonExe;

  /// Test hook — exposes the resolved app path for assertions.
  @visibleForTesting
  String? get debugDesktopPythonAppPath => _desktopPythonAppPath;

  /// Test hook — runs a Python one-liner using the seeded desktop state.
  /// Lets the unit test exercise the exact invocation contract that
  /// `parseEpub` uses, without depending on a real Python install.
  @visibleForTesting
  Future<ProcessResult> debugRunDesktopScript(
    String script, {
    String? stdinPayload,
  }) async {
    final exe = _desktopPythonExe!;
    final pythonPath = Directory(_desktopPythonAppPath!).parent.path;
    return Process.run(
      exe,
      <String>['-c', script],
      environment: <String, String>{
        ...Platform.environment,
        'PYTHONPATH': pythonPath,
        'PYTHONUNBUFFERED': '1',
        'PYTHONIOENCODING': 'utf-8',
      },
    );
  }
}
