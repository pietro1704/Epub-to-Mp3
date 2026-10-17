import 'dart:io';

import 'package:flutter_app/services/manual_conversion_output.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Platform.isWindows ? r'C:\owned audio' : '/owned audio';
  final separator = Platform.pathSeparator;

  test(
    'Android uses exactly the returned job identity beneath its request root',
    () {
      expect(
        manualConversionOutputDirectory(
          requestOutputDirectory: root,
          jobId: 'embedded-4321',
          android: true,
        ),
        '$root${separator}embedded-4321$separator',
      );
    },
  );

  test(
    'desktop keeps its direct output directory without appending the job ID',
    () {
      expect(
        manualConversionOutputDirectory(
          requestOutputDirectory: root,
          jobId: 'different-job-id',
          android: false,
        ),
        root,
      );
    },
  );

  test('missing or relative request roots never establish output paths', () {
    for (final android in [false, true]) {
      for (final directory in <String?>[null, 'relative/audio']) {
        expect(
          manualConversionOutputDirectory(
            requestOutputDirectory: directory,
            jobId: 'embedded-4321',
            android: android,
          ),
          isNull,
        );
      }
    }
  });

  test('Android rejects job IDs that could change the established root', () {
    for (final jobId in [
      '',
      '.',
      '..',
      '../outside',
      r'..\outside',
      '/absolute',
      r'C:\outside',
      'drive:relative',
      'nul\u0000suffix',
    ]) {
      expect(
        () => manualConversionOutputDirectory(
          requestOutputDirectory: root,
          jobId: jobId,
          android: true,
        ),
        throwsFormatException,
        reason: 'Unsafe job identity: $jobId',
      );
    }
  });

  test('job identity percent and fragment characters remain literal', () {
    expect(
      manualConversionOutputDirectory(
        requestOutputDirectory: root,
        jobId: 'job%20#part',
        android: true,
      ),
      '$root${separator}job%20#part$separator',
    );
  });
}
