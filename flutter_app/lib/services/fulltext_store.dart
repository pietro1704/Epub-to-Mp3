import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/ebook_fulltext.dart';
import 'api_client.dart';

/// Fetches `/api/jobs/{id}/fulltext` with retry ladder
/// [800, 1500, 3000, 6000, 12000] ms on transient (503) errors and
/// caches the result on disk for offline reads.
class FulltextStore {
  FulltextStore(this._client);
  final ApiClient _client;

  static const _retryMs = [800, 1500, 3000, 6000, 12000];

  Future<EbookFulltext> fetch(String jobId) async {
    // Try in-memory/disk cache first.
    final cached = await _readCache(jobId);
    if (cached != null) return cached;

    Object? lastError;
    for (var attempt = 0; attempt <= _retryMs.length; attempt++) {
      try {
        final result = await _client.fetchFulltext(jobId);
        await _writeCache(jobId, result);
        return result;
      } on FulltextTransient catch (e) {
        lastError = e;
        if (attempt >= _retryMs.length) break;
        await Future.delayed(Duration(milliseconds: _retryMs[attempt]));
      } on FulltextGone {
        rethrow;
      } on FulltextEmpty {
        rethrow;
      } catch (e) {
        lastError = e;
        if (attempt >= _retryMs.length) break;
        await Future.delayed(Duration(milliseconds: _retryMs[attempt]));
      }
    }
    throw lastError ?? const FulltextTransient();
  }

  Future<File> _cacheFile(String jobId) async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/fulltext');
    if (!await folder.exists()) await folder.create(recursive: true);
    return File('${folder.path}/$jobId.json');
  }

  Future<EbookFulltext?> _readCache(String jobId) async {
    try {
      final f = await _cacheFile(jobId);
      if (!await f.exists()) return null;
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return EbookFulltext.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(String jobId, EbookFulltext data) async {
    try {
      final f = await _cacheFile(jobId);
      await f.writeAsString(jsonEncode(_encode(data)));
    } catch (_) {}
  }

  Map<String, dynamic> _encode(EbookFulltext data) => {
        'jobId': data.jobId,
        'bookTitle': data.bookTitle,
        'bookAuthor': data.bookAuthor,
        'chapters': data.chapters
            .map((c) => {
                  'index': c.index,
                  'name': c.name,
                  'text': c.text,
                  'html': c.html,
                  'css': c.css,
                  'charCount': c.charCount,
                  'segments': c.segments
                      ?.map((s) => {
                            'id': s.id,
                            'text': s.text,
                            'startMs': s.startMs,
                            'endMs': s.endMs,
                          })
                      .toList(),
                })
            .toList(),
      };
}
