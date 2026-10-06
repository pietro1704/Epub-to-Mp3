import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/io.dart';

class EdgeWebTts {
  static const _endpoint =
      'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1';
  static const _token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const _format = 'audio-24khz-48kbitrate-mono-mp3';
  static const _origin =
      'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold';

  Future<Uint8List> synthesize(
    String text, {
    String voice = 'en-US-AvaMultilingualNeural',
  }) async {
    if (text.trim().isEmpty) throw StateError('Edge text is empty');
    final requestId = _requestId();
    final connectionId = _requestId();
    final secGec = secMsGec();
    final url = Uri.parse('$_endpoint?TrustedClientToken=$_token&ConnectionId=$connectionId'
        '&Sec-MS-GEC=$secGec&Sec-MS-GEC-Version=1-143.0.3650.75');
    final socket = IOWebSocketChannel.connect(
      url,
      headers: {
        'Origin': _origin,
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
        'Sec-MS-GEC': secGec,
        'Sec-MS-GEC-Version': '1-143.0.3650.75',
        'Sec-WebSocket-Version': '13',
        'Cookie': 'muid=${_requestId().substring(0, 32).toUpperCase()};',
        'Pragma': 'no-cache',
        'Cache-Control': 'no-cache',
        'Accept': '*/*',
        'Accept-Encoding': 'gzip, deflate, br, zstd',
        'Accept-Language': 'en-US,en;q=0.9',
        'Sec-CH-UA': '" Not;A Brand";v="99", "Microsoft Edge";v="143", "Chromium";v="143"',
        'Sec-Fetch-Site': 'none',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Dest': 'empty',
        'Sec-CH-UA-Mobile': '?0',
      },
      pingInterval: const Duration(seconds: 20),
    );
    final bytes = BytesBuilder();
    final done = Completer<void>();
    late final StreamSubscription<Object?> subscription;
    subscription = socket.stream.listen((event) {
      if (event is List<int>) {
        final data = Uint8List.fromList(event);
        if (data.length >= 2) {
          final header = (data[0] << 8) | data[1];
          if (header <= data.length - 2) bytes.add(data.sublist(2 + header));
        }
      } else if (event is String && event.contains('Path:turn.end')) {
        if (!done.isCompleted) done.complete();
      }
    }, onError: (Object error, StackTrace stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    });
    try {
      final timestamp = _edgeTimestamp();
      socket.sink.add('X-Timestamp:$timestamp\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"$_format"}}}}\r\n');
      final language = voice.split('-').take(2).join('-');
      final ssml = '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="$language"><voice name="$voice">${_escape(text)}</voice></speak>';
      socket.sink.add('X-RequestId:$requestId\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:$timestamp\r\nPath:ssml\r\n\r\n$ssml');
      await done.future.timeout(const Duration(seconds: 45));
      final result = bytes.takeBytes();
      if (result.isEmpty) throw StateError('Edge returned no audio');
      return Uint8List.fromList(result);
    } finally {
      await subscription.cancel();
      await socket.sink.close();
    }
  }

  String _requestId() {
    final random = Random.secure();
    final values = List<int>.generate(16, (_) => random.nextInt(256));
    return values.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  }

  String _escape(String value) => const HtmlEscape(HtmlEscapeMode.element).convert(value);

  String _edgeTimestamp() {
    final now = DateTime.now().toUtc();
    final weekday = const <String>[
      'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'
    ][now.weekday - 1];
    const months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    String two(int value) => value.toString().padLeft(2, '0');
    return '$weekday ${months[now.month - 1]} ${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)} GMT+0000 '
        '(Coordinated Universal Time)';
  }

  String secMsGec() {
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rounded = seconds + 11644473600 - (seconds + 11644473600) % 300;
    final payload = '${rounded * 10000000}$_token';
    return sha256.convert(utf8.encode(payload)).toString().toUpperCase();
  }
}
