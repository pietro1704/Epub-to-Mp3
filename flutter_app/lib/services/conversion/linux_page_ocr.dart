import 'dart:io';

typedef OcrCommandRun = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Reads one PDF page with Tesseract, only when `tesseract` and `pdftoppm` are already
/// installed (nothing is installed or downloaded). Languages: every installed one but `osd`.
class LinuxPageOcr {
  LinuxPageOcr({OcrCommandRun? run}) : _run = run ?? Process.run;

  final OcrCommandRun _run;
  String? _languages;

  Future<bool> isAvailable() async {
    try {
      return (await _languageList()).isNotEmpty &&
          (await _run('pdftoppm', ['-v'])).exitCode >= 0;
    } on Object {
      return false;
    }
  }

  Future<String> _languageList() async {
    final cached = _languages;
    if (cached != null) return cached;
    final result = await _run('tesseract', ['--list-langs']);
    final langs = '${result.stdout}'
        .split('\n')
        .map((line) => line.trim())
        .where(
          (line) => line.isNotEmpty && !line.contains(' ') && line != 'osd',
        )
        .toList();
    return _languages = langs.join('+');
  }

  Future<String?> recognize(String path, int page) async {
    Directory? dir;
    try {
      final languages = await _languageList();
      if (languages.isEmpty) return null;
      dir = Directory.systemTemp.createTempSync('pdf-ocr');
      final image = '${dir.path}/page';
      final render = await _run('pdftoppm', [
        '-f',
        '$page',
        '-l',
        '$page',
        '-r',
        '200',
        '-png',
        '-singlefile',
        path,
        image,
      ]);
      if (render.exitCode != 0) return null;
      final read = await _run('tesseract', [
        '$image.png',
        'stdout',
        '-l',
        languages,
      ]);
      if (read.exitCode != 0) return null;
      final text = '${read.stdout}'.trim();
      return text.isEmpty ? null : text;
    } on Object {
      return null;
    } finally {
      try {
        dir?.deleteSync(recursive: true);
      } on Object {
        // best effort
      }
    }
  }
}
