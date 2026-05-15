import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/ebook_fulltext.dart';
import '../models/job_snapshot.dart';
import '../models/session_record.dart';

/// Thin wrapper over `dio` for the FastAPI backend.
class ApiClient {
  ApiClient(this.baseUrl)
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 30),
        )),
        _streamDio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 10),
          // SSE streams are long-lived — no receive timeout.
        ));

  final String baseUrl;
  final Dio _dio;
  final Dio _streamDio;

  Future<List<SessionRecord>> fetchSessions({int last = 50}) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/api/sessions',
      queryParameters: {'last': last},
    );
    final data = r.data ?? const {};
    return SessionsResponse.fromJson(data).sessions;
  }

  Future<JobSnapshot> fetchJob(String jobId) async {
    final r = await _dio.get<Map<String, dynamic>>('/api/jobs/$jobId');
    return JobSnapshot.fromJson(r.data ?? const {});
  }

  /// Reader text contract per memory `project_reader_fulltext.md`.
  /// 503 -> transient (caller retries); 404/422 -> terminal.
  Future<EbookFulltext> fetchFulltext(String jobId) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/api/jobs/$jobId/fulltext',
      options: Options(validateStatus: (s) => s != null && s < 500),
    );
    if (r.statusCode == 503) {
      throw const FulltextTransient();
    }
    if (r.statusCode == 404) {
      throw const FulltextGone();
    }
    if (r.statusCode == 422) {
      throw const FulltextEmpty();
    }
    return EbookFulltext.fromJson(r.data ?? const {});
  }

  /// Upload an EPUB file and start conversion. Returns the job ID.
  ///
  /// Two-step: POST multipart `/api/uploads` then POST form `/api/convert`.
  Future<String> uploadAndConvert(String filePath) async {
    final fileName = filePath.split('/').last;
    final uploadForm = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, filename: fileName),
    });
    final uploadResp = await _dio.post<Map<String, dynamic>>(
      '/api/uploads',
      data: uploadForm,
    );
    final uploadId = uploadResp.data?['uploadId'] as String;

    final convertForm = FormData.fromMap({
      'upload_id': uploadId,
      'engine': 'edge',
    });
    final convertResp = await _dio.post<Map<String, dynamic>>(
      '/api/convert',
      data: convertForm,
    );
    return convertResp.data?['jobId'] as String;
  }

  /// SSE stream parser. Each backend `data:` line is JSON-decodable.
  /// Uses a dedicated Dio instance with no receive timeout since SSE
  /// connections are long-lived.
  Stream<JobSnapshot> jobStream(String jobId) async* {
    final response = await _streamDio.get<ResponseBody>(
      '/api/jobs/$jobId/stream',
      options: Options(
        responseType: ResponseType.stream,
        headers: {'Accept': 'text/event-stream'},
      ),
    );
    final body = response.data;
    if (body == null) return;
    final lines = body.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      try {
        final json = jsonDecode(payload) as Map<String, dynamic>;
        yield JobSnapshot.fromJson(json);
      } catch (_) {
        // Ignore malformed frames — keep stream alive.
      }
    }
  }
}

class FulltextTransient implements Exception {
  const FulltextTransient();
}

class FulltextGone implements Exception {
  const FulltextGone();
}

class FulltextEmpty implements Exception {
  const FulltextEmpty();
}
