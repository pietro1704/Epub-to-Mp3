import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/services/edge_chapter_conversion.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeEdgeConverter extends UnavailableEmbeddedConverter {
  final List<String> requests = [];

  @override
  Future<Uint8List> edgeProbe(String text, {String? locale}) async {
    requests.add(text);
    return Uint8List.fromList(const [0x49, 0x44, 0x33, 0x01]);
  }
}

class FallbackConverter extends UnavailableEmbeddedConverter {
  final List<String> edgeRequests = [];
  final List<String> fallbackRequests = [];

  @override
  Future<Uint8List> edgeProbe(String text, {String? locale}) async {
    edgeRequests.add(text);
    throw EmbeddedConversionFailure('EDGE_FAILED', 'simulated Edge rejection');
  }

  @override
  Future<String> synthesizeFallback(
    String text, {
    required String locale,
    required String path,
  }) async {
    fallbackRequests.add(text);
    await File(path).writeAsBytes(const [0x49, 0x44, 0x33, 0x02]);
    return path;
  }
}

void main() {
  test('converts selected chapters sequentially and persists manifest', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final converter = FakeEdgeConverter();
    final coordinator = ConversionJobCoordinator(LocalConversionJobStore(prefs));
    final service = EdgeChapterConversionService(
      converter: converter,
      coordinator: coordinator,
    );
    final directory = await Directory.systemTemp.createTemp('edge-chapter-conversion-');

    try {
      final job = await service.convert(
        bookId: 'book-1',
        jobId: 'job-1',
        outputDirectory: directory.path,
        selectedIndices: {4},
        chapters: [
          const FulltextChapter(index: 3, name: 'Skipped', text: 'not selected'),
          const FulltextChapter(index: 4, name: 'The Old Forest', text: 'selected text'),
        ],
      );

      expect(converter.requests, ['selected text']);
      expect(job.status, LocalConversionJobStatus.completed);
      expect(job.completedOutputs, hasLength(1));
      final output = File(job.completedOutputs.single);
      expect(await output.exists(), isTrue);
      expect(await output.readAsBytes(), [0x49, 0x44, 0x33, 0x01]);

      final manifest = await File('${directory.path}/manifest.json').readAsString();
      expect(manifest, contains('The Old Forest'));
      expect(manifest, contains('"status":"completed"'));
      expect(manifest, isNot(contains('Skipped')));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('persists synthesized fallback audio when Edge fails', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final converter = FallbackConverter();
    final coordinator = ConversionJobCoordinator(LocalConversionJobStore(prefs));
    final service = EdgeChapterConversionService(
      converter: converter,
      coordinator: coordinator,
    );
    final directory = await Directory.systemTemp.createTemp('edge-fallback-');

    try {
      final job = await service.convert(
        bookId: 'book-fallback',
        jobId: 'job-fallback',
        outputDirectory: directory.path,
        chapters: const [
          FulltextChapter(index: 0, name: 'Fallback', text: 'fallback text'),
        ],
      );

      expect(converter.edgeRequests, ['fallback text']);
      expect(converter.fallbackRequests, ['fallback text']);
      expect(job.status, LocalConversionJobStatus.completed);
      final output = File(job.completedOutputs.single);
      expect(await output.readAsBytes(), [0x49, 0x44, 0x33, 0x02]);
      expect(await File('${output.path}.tts').exists(), isFalse);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
