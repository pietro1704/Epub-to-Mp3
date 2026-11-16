import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show TextRange;

import '../reader/reader_document_geometry.dart';

/// The measured mapping already carried by converter-core's MP3 artifacts.
class MeasuredSpeechAlignment {
  MeasuredSpeechAlignment(this.passages);
  String? _resolvedSource;
  List<_MeasuredWord> _timeline = const [];
  final List<Map<String, dynamic>> passages;
  static const maxTagBytes = 8 * 1024 * 1024;
  static const owner = 'epubtomp3.speech-alignment';

  static Future<MeasuredSpeechAlignment> read(Uri uri) async {
    if (uri.scheme != 'file') return MeasuredSpeechAlignment([]);
    RandomAccessFile? file;
    try {
      file = await File.fromUri(uri).open();
      final header = await file.read(10);
      if (header.length != 10 ||
          ascii.decode(header.take(3).toList(), allowInvalid: true) != 'ID3') {
        return MeasuredSpeechAlignment([]);
      }
      final length = _size(header, 6, syncsafe: true);
      if (length < 0 || length > maxTagBytes) {
        return MeasuredSpeechAlignment([]);
      }
      return parse(Uint8List.fromList([...header, ...await file.read(length)]));
    } on FileSystemException {
      return MeasuredSpeechAlignment([]);
    } finally {
      await file?.close();
    }
  }

  static int _size(List<int> bytes, int offset, {required bool syncsafe}) {
    if (offset + 4 > bytes.length) return -1;
    var result = 0;
    for (var i = 0; i < 4; i++) {
      final byte = bytes[offset + i];
      if (syncsafe && byte > 127) return -1;
      result = (result << (syncsafe ? 7 : 8)) | byte;
    }
    return result;
  }

  static MeasuredSpeechAlignment parse(Uint8List bytes) {
    final empty = MeasuredSpeechAlignment([]);
    if (bytes.length < 10 ||
        ascii.decode(bytes.sublist(0, 3), allowInvalid: true) != 'ID3' ||
        ![3, 4].contains(bytes[3])) {
      return empty;
    }
    final length = _size(bytes, 6, syncsafe: true);
    if (length < 0 ||
        length > maxTagBytes ||
        bytes.length < length + 10 ||
        bytes[5] != 0) {
      return empty;
    }
    var offset = 10;
    while (offset + 10 <= length + 10) {
      final name = ascii.decode(
        bytes.sublist(offset, offset + 4),
        allowInvalid: true,
      );
      final frameLength = _size(bytes, offset + 4, syncsafe: bytes[3] == 4);
      final flags = bytes[offset + 8] | bytes[offset + 9];
      offset += 10;
      if (frameLength <= 0 || offset + frameLength > length + 10) return empty;
      if (name == 'PRIV' && flags == 0) {
        final frame = bytes.sublist(offset, offset + frameLength);
        final separator = frame.indexOf(0);
        if (separator >= 0 &&
            ascii.decode(frame.sublist(0, separator), allowInvalid: true) ==
                owner) {
          if (frame.length - separator - 1 > 4 * 1024 * 1024) return empty;
          try {
            final value = jsonDecode(utf8.decode(frame.sublist(separator + 1)));
            if (value is! List || value.length > 20000) return empty;
            return MeasuredSpeechAlignment(
              value
                  .whereType<Map>()
                  .map((passage) => Map<String, dynamic>.from(passage))
                  .toList(),
            );
          } on FormatException {
            return empty;
          }
        }
      }
      offset += frameLength;
    }
    return empty;
  }

  TextRange? rangeAt(double seconds, String chapter) {
    if (!seconds.isFinite || seconds < 0 || passages.isEmpty) return null;
    if (_resolvedSource != chapter) {
      _timeline = _resolve(chapter)..sort((a, b) => a.start.compareTo(b.start));
      _resolvedSource = chapter;
    }
    var low = 0, high = _timeline.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_timeline[middle].start <= seconds) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low == 0) return null;
    final active = _timeline[low - 1];
    return seconds < active.end ? active.range : null;
  }

  List<_MeasuredWord> _resolve(String chapter) {
    final source = NormalizedReaderText(chapter);
    final timeline = <_MeasuredWord>[];
    for (final passage in passages) {
      if (passage['version'] != 1 ||
          passage['text'] is! String ||
          passage['words'] is! List) {
        continue;
      }
      final text = passage['text'] as String;
      final words = passage['words'] as List;
      final base = passage['audioStart'] ?? 0;
      if (base is! num ||
          !base.isFinite ||
          base < 0 ||
          words.isEmpty ||
          words.length > 20000) {
        continue;
      }
      final utterance = NormalizedReaderText(text);
      if (utterance.text.isEmpty) continue;
      int start;
      final scalar = passage['sourceOffset'];
      if (scalar is int && scalar >= 0 && scalar <= chapter.runes.length) {
        final raw = String.fromCharCodes(chapter.runes.take(scalar)).length;
        start = source.offsets.indexWhere((offset) => offset >= raw);
        if (start < 0 || !source.text.startsWith(utterance.text, start)) {
          continue;
        }
      } else if (scalar != null) {
        continue;
      } else {
        start = source.text.indexOf(utterance.text);
        if (start < 0 || source.text.indexOf(utterance.text, start + 1) >= 0) {
          continue;
        }
      }
      var previousEnd = 0.0;
      var previousLocation = 0;
      final resolved = <_MeasuredWord>[];
      var valid = true;
      bool boundary(int offset) =>
          offset >= 0 &&
          offset <= text.length &&
          (offset == text.length ||
              text.codeUnitAt(offset) < 0xdc00 ||
              text.codeUnitAt(offset) > 0xdfff);
      for (final word in words) {
        if (word is! Map) {
          valid = false;
          break;
        }
        final location = word['location'],
            count = word['length'],
            begin = word['start'],
            end = word['end'];
        if (location is! int ||
            count is! int ||
            count <= 0 ||
            !boundary(location) ||
            !boundary(location + count) ||
            begin is! num ||
            end is! num ||
            !begin.isFinite ||
            !end.isFinite ||
            begin < previousEnd - .001 ||
            end <= begin ||
            location < previousLocation) {
          valid = false;
          break;
        }
        previousEnd = end.toDouble();
        previousLocation = location + count;
        final first = utterance.offsets.indexWhere(
          (offset) => offset >= location,
        );
        final last = utterance.offsets.indexWhere(
          (offset) => offset >= location + count,
        );
        if (first >= 0 && last > first && start + last <= source.text.length) {
          resolved.add(
            _MeasuredWord(
              (base + begin).toDouble(),
              (base + end).toDouble(),
              TextRange(
                start: source.offsets[start + first],
                end: source.offsets[start + last],
              ),
            ),
          );
        }
      }
      if (valid) timeline.addAll(resolved);
    }
    return timeline;
  }
}

class _MeasuredWord {
  _MeasuredWord(this.start, this.end, this.range);
  final double start, end;
  final TextRange range;
}
