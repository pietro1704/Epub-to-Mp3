import 'dart:io';

/// Android JNI nests jobs beneath the requested root; desktop FFI uses it directly.
String? manualConversionOutputDirectory({
  required String? requestOutputDirectory,
  required String jobId,
  required bool android,
}) {
  final root = requestOutputDirectory;
  if (root == null || !Directory(root).isAbsolute) return null;
  if (!android) return root;
  if (jobId.isEmpty ||
      jobId == '.' ||
      jobId == '..' ||
      jobId.contains('/') ||
      jobId.contains(r'\') ||
      jobId.contains(':') ||
      jobId.contains('\u0000')) {
    throw const FormatException('Unsafe Android conversion job ID');
  }
  return Uri.directory(
    root,
  ).resolveUri(Uri(pathSegments: [jobId, ''])).toFilePath();
}
