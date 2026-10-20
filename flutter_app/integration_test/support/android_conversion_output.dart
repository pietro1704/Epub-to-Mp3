import 'dart:convert';
import 'dart:io';

class AndroidConversionOutput {
  AndroidConversionOutput(this.directory, this.manifest);

  final Directory directory;
  final Map<String, dynamic> manifest;

  Future<File> audioFile(String filename) async {
    final root = await directory.resolveSymbolicLinks();
    final resolved = await File(
      '${directory.path}/$filename',
    ).resolveSymbolicLinks();
    if (!resolved.startsWith('$root/')) {
      throw StateError('Conversion audio escaped its job directory');
    }
    return File(resolved);
  }
}

Future<AndroidConversionOutput> readAndroidConversionOutput(
  Directory requestedOutput,
  Map<String, dynamic> returnedManifest,
) async {
  final jobId = returnedManifest['jobId'];
  if (jobId is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$').hasMatch(jobId)) {
    throw const FormatException('Conversion returned an invalid job identity');
  }
  final root = await requestedOutput.resolveSymbolicLinks();
  final resolved = await Directory('$root/$jobId').resolveSymbolicLinks();
  if (!resolved.startsWith('$root/')) {
    throw StateError('Conversion job escaped its requested output directory');
  }
  final directory = Directory(resolved);
  final persisted =
      jsonDecode(await File('${directory.path}/manifest.json').readAsString())
          as Map<String, dynamic>;
  return AndroidConversionOutput(directory, persisted);
}
