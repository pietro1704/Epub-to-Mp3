import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android playback widget is registered with a player deep link', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final provider = File('android/app/src/main/kotlin/com/pietrocode/epubtomp3/flutter_app/PlaybackWidgetProvider.kt').readAsStringSync();
    final info = File('android/app/src/main/res/xml/playback_widget_info.xml').readAsStringSync();
    expect(manifest, contains('.PlaybackWidgetProvider'));
    expect(manifest, contains('@xml/playback_widget_info'));
    expect(provider, contains('epubtomp3://player'));
    expect(provider, contains('widget.playback_snapshot.v1'));
    expect(info, contains('@layout/playback_widget'));
  });
}
