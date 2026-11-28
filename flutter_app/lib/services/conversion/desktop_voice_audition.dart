part of 'desktop_embedded_converter.dart';

typedef _AuditionNative = ffi.Bool Function(
  ffi.Pointer<Utf8>,
  ffi.Pointer<Utf8>,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Void>,
);
typedef _AuditionDart = bool Function(
  ffi.Pointer<Utf8>,
  ffi.Pointer<Utf8>,
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.Void>,
);

/// Renders one voice sample through `converter_voice_audition_v1` on a worker isolate. The
/// sample owns an independent cancellation control, shared with the worker only by address.
AuditionRender desktopVoiceAuditionRender({String? libraryPath}) {
  return (optionsJson, text, output, cancel) async {
    final path = libraryPath ?? DesktopEmbeddedConverter._resolveLibraryPath();
    final lib = ffi.DynamicLibrary.open(path);
    final control = lib
        .lookupFunction<_ControlCreateNative, _ControlCreateDart>(
          'converter_job_control_create',
        )();
    if (control == ffi.nullptr) {
      throw EmbeddedConversionFailure(
        'CONTROL_UNAVAILABLE',
        'The sample control could not be created',
      );
    }
    final cancelControl = lib
        .lookupFunction<_ControlActionNative, _ControlActionDart>(
          'converter_job_control_cancel',
        );
    cancel.onCancel = () => cancelControl(control);
    if (cancel.isCancelled) cancelControl(control);
    final address = control.address;
    try {
      final failure = await Isolate.run<String?>(() {
        final worker = ffi.DynamicLibrary.open(path);
        final audition = worker.lookupFunction<_AuditionNative, _AuditionDart>(
          'converter_voice_audition_v1',
        );
        final lastError = worker
            .lookupFunction<_LastErrorNative, _LastErrorDart>(
              'converter_last_error',
            );
        final free = worker.lookupFunction<_StringNative, _StringDart>(
          'converter_string_free',
        );
        return using((arena) {
          final accepted = audition(
            optionsJson.toNativeUtf8(allocator: arena),
            text.toNativeUtf8(allocator: arena),
            output.toNativeUtf8(allocator: arena),
            ffi.Pointer.fromAddress(address),
          );
          if (accepted) return null;
          final error = lastError();
          if (error == ffi.nullptr) return 'Voice audition failed';
          try {
            return error.toDartString();
          } finally {
            free(error);
          }
        });
      });
      if (failure != null && !cancel.isCancelled) {
        throw EmbeddedConversionFailure('AUDITION_FAILED', failure);
      }
    } finally {
      cancel.onCancel = null;
      lib.lookupFunction<_ControlActionNative, _ControlActionDart>(
        'converter_job_control_free',
      )(control);
    }
  };
}
