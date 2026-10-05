import 'dart:convert';

import 'package:flutter/services.dart';

import 'desktop_tts_model_adapter.dart';

/// Thin platform adapter for the shared Rust coordinator's durable job record.
/// It never talks to Python, HTTP, or a remote backend.
abstract interface class ConversionLogSource {
  Future<List<String>> read(String jobId);
}

class EmbeddedConversionLogSource implements ConversionLogSource {
  EmbeddedConversionLogSource({DesktopTtsModelAdapter? desktop, MethodChannel? channel})
      : _desktop = desktop,
        _channel = channel ?? const MethodChannel('epub_to_mp3/embedded_converter');

  final DesktopTtsModelAdapter? _desktop;
  final MethodChannel _channel;

  @override
  Future<List<String>> read(String jobId) async {
    final raw = _desktop != null
        ? _desktop.jobLog(jobId: jobId)
        : await _channel.invokeMethod<String>('jobLog', {'jobId': jobId});
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) return decoded.map((value) => value.toString()).toList();
    if (decoded is Map) return [const JsonEncoder.withIndent('  ').convert(decoded)];
    return [raw];
  }
}
