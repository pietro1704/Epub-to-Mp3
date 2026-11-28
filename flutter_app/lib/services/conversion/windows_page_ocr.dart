import 'dart:io';

import 'linux_page_ocr.dart' show OcrCommandRun;

// Renders one PDF page with Windows.Data.Pdf and reads it with Windows.Media.Ocr, using the
// OCR languages already installed for the user profile. Args: PDF path, 1-based page.
const _script = r'''
param([string]$Path, [int]$Page)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [Type]$type) {
  $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
  $task.Wait(-1) | Out-Null
  $task.Result
}
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $engine) { exit 2 }
$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
$doc = Await ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file)) ([Windows.Data.Pdf.PdfDocument])
$pdfPage = $doc.GetPage($Page - 1)
$stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
$options = New-Object Windows.Data.Pdf.PdfPageRenderOptions
$options.DestinationWidth = 1600
$pdfPage.RenderToStreamAsync($stream, $options).AsTask().Wait(-1) | Out-Null
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Output $result.Text
''';

/// Reads one PDF page with the Windows OCR engine; nothing is installed or downloaded.
class WindowsPageOcr {
  WindowsPageOcr({OcrCommandRun? run}) : _run = run ?? Process.run;

  final OcrCommandRun _run;

  Future<String?> _invoke(String path, int page) async {
    Directory? dir;
    try {
      dir = Directory.systemTemp.createTempSync('pdf-ocr');
      final script = File('${dir.path}/ocr.ps1')..writeAsStringSync(_script);
      final result = await _run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        path,
        '$page',
      ]);
      if (result.exitCode != 0) return null;
      final text = '${result.stdout}'.trim();
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

  /// True when the engine exists for the profile languages (a probe of page 1 of nothing).
  Future<bool> isAvailable() async {
    try {
      final result = await _run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'''$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]; if ($null -eq [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()) { exit 2 }''',
      ]);
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }

  Future<String?> recognize(String path, int page) => _invoke(path, page);
}
