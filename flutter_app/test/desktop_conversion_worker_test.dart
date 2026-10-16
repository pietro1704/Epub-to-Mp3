import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/services/desktop_embedded_converter.dart';
import 'package:flutter_app/services/embedded_converter.dart';

// This tiny ABI fixture blocks inside native conversion, proving the UI isolate
// remains responsive and can cancel without transferring native sessions.
const _fixture = r'''
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>
static int wait_for_ui_heartbeat(const char* root) {
 char started[4096], release[4096];
 snprintf(started, sizeof(started), "%s.started", root);
 snprintf(release, sizeof(release), "%s.release", root);
 FILE* file = fopen(started, "wb");
 if (!file) return 0;
 fclose(file);
 struct timespec beginning, now;
 clock_gettime(CLOCK_MONOTONIC, &beginning);
 for (;;) {
  if (access(release, F_OK) == 0) return 1;
  clock_gettime(CLOCK_MONOTONIC, &now);
  if (now.tv_sec - beginning.tv_sec >= 5) return 0;
  usleep(1000);
 }
}
typedef struct { atomic_int cancelled; atomic_int queued; char* chunk_path; } FixtureControl;
void* converter_session_open(const char* path) { return strdup(path); }
void converter_session_free(void* session) { free(session); }
char* converter_session_metadata_json(void* session) { if (!wait_for_ui_heartbeat((const char*)session)) return NULL; return strdup("{\"bookTitle\":\"Native fixture\",\"chapters\":[{\"index\":0,\"name\":\"Native chapter\",\"text\":\"Metadata text\"}]}"); }
void converter_string_free(char* value) { free(value); }
char* converter_last_error() { return strdup("Fixture cancelled or invalid provider options"); }
void* converter_job_control_create() { return calloc(1, sizeof(FixtureControl)); }
void converter_job_control_cancel(atomic_int* control) { atomic_store(control, 1); }
void converter_job_control_free(FixtureControl* control) { free(control->chunk_path); free(control); }

_Bool converter_job_control_enable_audio_chunks(FixtureControl* control) { return 1; }
char* converter_job_control_take_audio_chunk_json(FixtureControl* control) {
 if (!atomic_exchange(&control->queued, 0)) return NULL;
 char json[4096];
 snprintf(json, sizeof(json), "{\"chapterIndex\":0,\"chunkIndex\":0,\"path\":\"%s\"}", control->chunk_path);
 return strdup(json);
}
char* converter_session_convert_streaming_job_options_json_v1(void* session,
 const char* output, const char* job, const char* options, int start, int end,
 void* progress, void* chapter, void* chunk, void* context, FixtureControl* control) {
 mkdir(output, 0700);
 char path[2048];
 snprintf(path, sizeof(path), "%s/chunk-0.mp3", output);
 FILE* file = fopen(path, "wb");
 if (!file) return NULL;
 fwrite("ID3fixture", 1, 10, file); fclose(file);
 control->chunk_path = strdup(path);
 atomic_store(&control->queued, 1);
 for (int i=0; i<300; i++) { if (atomic_load(&control->cancelled)) return NULL; usleep(2000); }
 char marker[2048]; snprintf(marker, sizeof(marker), "%s/native-finished", output);
 file = fopen(marker, "wb"); fclose(file);
 char result[8192];
 snprintf(result, sizeof(result), "{\"audioPath\":\"%s\",\"manifest\":{\"chapters\":[{\"sourceIndex\":0,\"title\":\"Native stream\"}],\"usedSelections\":[{\"engine\":\"piper\",\"model_id\":\"pt_BR-faber-medium\",\"voice\":null}],\"ttsPolicyState\":{\"opaque\":\"native-state\"}}}", path);
 return strdup(result);
}
char* converter_tts_models_json() { return strdup("[]"); }
char* converter_tts_model_install_catalog_manifest(const char* model, const char* root) {
 if (strcmp(model, "pt_BR-faber-medium") != 0 || !root || !*root) return NULL;
 if (!wait_for_ui_heartbeat(root)) return NULL;
 return strdup("{\"id\":\"pt_BR-faber-medium\"}");
}
_Bool converter_tts_model_remove(const char* model, const char* root) { return 1; }
char* converter_tts_model_metadata(const char* model, const char* root) { return NULL; }
char* converter_tts_installed_ready_engine(const char* language, const char* platform, unsigned int api, const char* installed, const char* ready) { return NULL; }
char* converter_job_log_json(const char* id) { return strdup("[]"); }

char* converter_session_convert_controlled_job_options_json_v1(void* session,
 const char* output, const char* job, const char* options, int start, int end,
 void* progress, void* chapter, void* context, atomic_int* control) {
 if (!strstr(options, "pt_BR-faber-medium") || start != 2 || end != 3) return NULL;
 for (int i=0; i<100; i++) {
   if (atomic_load(control)) return NULL;
   usleep(2000);
 }
 return strdup("{\"manifest\":{\"chapters\":[]}}");
}
''';

// The native operation cannot finish successfully until this isolate handles
// an event-loop heartbeat after observing that native work has started.
Future<T> _whileNativeBlocked<T>(String root, Future<T> Function() operation) async {
  var completed = false;
  final pending = operation().whenComplete(() { completed = true; });
  // Attach an error listener before waiting for the native handshake.
  final observed = pending.then<Object?>((_) => null, onError: (Object error) => error);
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!await File('$root.started').exists()) {
      if (DateTime.now().isAfter(deadline)) fail('Native operation did not enter its blocking fixture');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(completed, false, reason: 'Native work completed before the UI heartbeat');
    final heartbeat = Completer<void>();
    Timer.run(() => heartbeat.complete());
    await heartbeat.future.timeout(const Duration(seconds: 1));
    expect(completed, false, reason: 'UI heartbeat must run while native work is blocked');
    await File('$root.release').writeAsString('heartbeat');
    return await pending;
  } finally {
    await File('$root.release').writeAsString('cleanup');
    await observed;
  }
}

void main() {
  if (!Platform.isMacOS && !Platform.isLinux) return;
  late Directory directory;
  late String library;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'desktop-conversion-abi-',
    );
    final source = File('${directory.path}/fixture.c');
    await source.writeAsString(_fixture);
    library = '${directory.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
    final result = await Process.run('cc', [
      '-std=c11',
      '-D_DEFAULT_SOURCE',
      '-shared',
      '-fPIC',
      source.path,
      '-o',
      library,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
  tearDownAll(() async => directory.delete(recursive: true));

  test(
    'native streaming publishes playable bytes before chapter conversion finishes',
    () async {
      final converter = DesktopEmbeddedConverter(libraryPath: library);
      final output = '${directory.path}/stream';
      final first = Completer<void>();
      final pending = converter.streamChapter(
        inputPath: '/book.epub',
        outputPath: output,
        chapterIndex: 0,
        optionsJson: const TtsPreferences().optionsJson(),
        onFirstAudio: (source) async {
          expect(File('$output/native-finished').existsSync(), false);
          expect(source.isComplete, false);
          final response = await source.request();
          expect(await response.stream.first, 'ID3fixture'.codeUnits);
          first.complete();
        },
      );
      await first.future.timeout(const Duration(seconds: 2));
      final result = await pending;
      expect(result.usedSelections.single.modelId, 'pt_BR-faber-medium');
      expect(result.ttsPolicyState, {'opaque': 'native-state'});
      expect(File('$output/native-finished').existsSync(), true);
    },
  );

  test(
    'duplicate stream cannot steal the active source or cancellation control',
    () async {
      final converter = DesktopEmbeddedConverter(libraryPath: library);
      final output = '${directory.path}/owned-stream';
      final first = Completer<void>();
      Future<void> Function()? checkFailure;
      final pending = converter.streamChapter(
        inputPath: '/book.epub',
        outputPath: output,
        chapterIndex: 0,
        onFirstAudio: (source) async {
          checkFailure = () => source.waitForSeek();
          first.complete();
        },
      );
      final cancelled = expectLater(
        pending,
        throwsA(
          isA<EmbeddedConversionFailure>().having(
            (error) => error.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );
      await first.future.timeout(const Duration(seconds: 2));
      await expectLater(
        converter.streamChapter(
          inputPath: '/book.epub',
          outputPath: output,
          chapterIndex: 0,
          onFirstAudio: (_) async {},
        ),
        throwsA(
          isA<EmbeddedConversionFailure>().having(
            (error) => error.code,
            'code',
            'CONVERSION_BUSY',
          ),
        ),
      );
      await converter.cancelStreamingChapter(output);
      await cancelled;
      await expectLater(checkFailure!(), throwsA(isA<StateError>()));
    },
  );
  test(
    'EPUB parsing stays outside UI isolate including native metadata decoding',
    () async {
      final converter = DesktopEmbeddedConverter(libraryPath: library);
      final root = '${directory.path}/parse-handshake';
      final book = await _whileNativeBlocked(root, () => converter.parse(
        inputPath: root,
        jobId: 'book-id',
      ));
      expect(book.bookTitle, 'Native fixture');
      expect(book.jobId, 'book-id');
      expect(book.chapters.single.text, 'Metadata text');
    },
  );

  test(
    'native model installation keeps the UI event loop responsive',
    () async {
      final converter = DesktopEmbeddedConverter(libraryPath: library);
      final root = '${directory.path}/install-handshake';
      final manifest = await _whileNativeBlocked(root, () => converter.installTtsModelFromCatalog(
        modelId: 'pt_BR-faber-medium',
        root: root,
      ));
      expect(manifest, '{"id":"pt_BR-faber-medium"}');
    },
  );
  test(
    'native conversion runs outside the UI isolate with captured policy',
    () async {
      final converter = DesktopEmbeddedConverter(libraryPath: library);
      var heartbeats = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => heartbeats++,
      );
      try {
        final manifest = await converter.convert(
          inputPath: '/book.epub',
          outputPath: '/output',
          chapterStart: 2,
          chapterEnd: 3,
          optionsJson: const TtsPreferences().optionsJson(),
        );
        expect(manifest, '{"chapters":[]}');
        expect(heartbeats, greaterThan(5));
      } finally {
        timer.cancel();
      }
    },
  );

  test(
    'UI cancellation reaches the worker control and releases output ownership',
    () async {
      final converter = DesktopEmbeddedConverter(libraryPath: library);
      final pending = converter.convert(
        inputPath: '/book.epub',
        outputPath: '/cancel',
        chapterStart: 2,
        chapterEnd: 3,
        optionsJson: const TtsPreferences().optionsJson(),
      );
      final assertion = expectLater(
        pending,
        throwsA(
          isA<EmbeddedConversionFailure>().having(
            (error) => error.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await converter.cancelConversion(outputPath: '/cancel');
      await assertion;
      // The freed control cannot be reused by cancellation after worker completion.
      await converter.cancelConversion(outputPath: '/cancel');
      expect(
        await converter.convert(
          inputPath: '/book.epub',
          outputPath: '/cancel',
          chapterStart: 2,
          chapterEnd: 3,
        ),
        '{"chapters":[]}',
      );
    },
  );
}
