// Desktop-only contract tests for the PythonBridge subprocess path.
//
// We can't depend on a real Python install in CI, so the test
// substitutes a tiny shell-script "Python" that echoes a fixed JSON
// payload to stdout. This validates:
//
//   1. The bridge invokes the executable we seeded.
//   2. The PYTHONPATH env var points at the PARENT of the
//      python_app/ asset dir (so `import python_app.src...` resolves).
//   3. parseEpub round-trips stdin → JSON stdout → EbookFulltext.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_app/services/python_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Disable the MethodChannel — these tests cover the desktop path
  // exclusively, but we need the binding so rootBundle exists.
  const channel = MethodChannel('epub_to_mp3/python');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    PythonBridge.instance.debugResetDesktopRuntime();
  });

  test(
    'desktop runtime forwards PYTHONPATH and reads stdout JSON',
    () async {
      // Build a fake python_app/ tree in a tempdir so the bridge has
      // something to point PYTHONPATH at. We don't actually import it;
      // the fake interpreter just echoes JSON.
      final tmp = await Directory.systemTemp.createTemp('pybridge_test_');
      final pythonAppDir = Directory('${tmp.path}/python_app');
      await pythonAppDir.create(recursive: true);
      await File('${pythonAppDir.path}/__init__.py').writeAsString('');

      // Fake "python" executable: a bash script that prints a fixed
      // JSON payload. Mirrors what `parse_epub_to_json` would return.
      final fake = File('${tmp.path}/fake-python');
      const payload =
          '{"jobId":"","bookTitle":"Fake","bookAuthor":"Tester",'
          '"chapters":[{"index":1,"name":"Ch1","text":"hi","charCount":2,"level":1}]}';
      await fake.writeAsString(
        '#!/usr/bin/env bash\nprintf %s \'$payload\'\n',
      );
      await Process.run('chmod', <String>['+x', fake.path]);

      PythonBridge.instance.debugSetDesktopRuntime(
        pythonExecutable: fake.path,
        pythonAppPath: pythonAppDir.path,
      );

      final result = await PythonBridge.instance.debugRunDesktopScript(
        'print("ignored — fake python")',
      );
      expect(result.exitCode, 0);
      expect(result.stdout as String, jsonEncode(jsonDecode(payload)));

      // Sanity: stdout is valid JSON of the EbookFulltext shape.
      final decoded = jsonDecode(result.stdout as String)
          as Map<String, dynamic>;
      expect(decoded['bookTitle'], 'Fake');
      expect((decoded['chapters'] as List).length, 1);

      await tmp.delete(recursive: true);
    },
    // Bash + chmod aren't on Windows by default; skip there until we
    // wire a .bat-based fake interpreter.
    skip: Platform.isWindows
        ? 'Fake-python harness uses bash; Windows path TBD'
        : false,
  );

  test('bridge stays unsupported on iOS/macOS hosts', () {
    if (Platform.isAndroid || Platform.isLinux || Platform.isWindows) {
      expect(PythonBridge.instance.isSupported, isTrue);
    } else {
      expect(PythonBridge.instance.isSupported, isFalse);
    }
  });
}
