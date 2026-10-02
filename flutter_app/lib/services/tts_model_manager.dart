import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'tts_model_catalog.dart';

class TtsModelManager {
  TtsModelManager({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<Directory> _root() async {
    final base = await getApplicationSupportDirectory();
    final directory = Directory('${base.path}/tts-models');
    await directory.create(recursive: true);
    return directory;
  }

  Future<File?> installed(TtsModelDescriptor model) async {
    final root = await _root();
    final file = File('${root.path}/${model.id}/model.bin');
    if (!await file.exists()) return null;
    if (model.sha256 != null && await _sha256(file) != model.sha256) {
      await file.delete();
      return null;
    }
    return file;
  }

  Future<File> download(
    TtsModelDescriptor model, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final url = model.downloadUrl;
    if (url == null || url.isEmpty) {
      throw StateError('Model ${model.id} has no download URL');
    }
    final root = await _root();
    final directory = Directory('${root.path}/${model.id}');
    await directory.create(recursive: true);
    final temporary = File('${directory.path}/model.bin.part');
    final target = File('${directory.path}/model.bin');
    try {
      await _dio.download(
        url,
        temporary.path,
        deleteOnError: false,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
        options: Options(responseType: ResponseType.bytes),
      );
      if (model.sha256 != null && await _sha256(temporary) != model.sha256) {
        throw StateError('Checksum mismatch for ${model.id}');
      }
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
      final metadata = File('${directory.path}/metadata.json');
      await metadata.writeAsString(
        jsonEncode({
          'id': model.id,
          'engine': model.engine,
          'sha256': await _sha256(target),
        }),
      );
      return target;
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> remove(TtsModelDescriptor model) async {
    final root = await _root();
    final directory = Directory('${root.path}/${model.id}');
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<String> _sha256(File file) async =>
      sha256.convert(await file.readAsBytes()).toString();
}
