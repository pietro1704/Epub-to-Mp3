part of 'desktop_embedded_converter.dart';

final class _NativeSession extends ffi.Opaque {}

typedef _OpenNative = ffi.Pointer<_NativeSession> Function(ffi.Pointer<Utf8>);
typedef _OpenDart = ffi.Pointer<_NativeSession> Function(ffi.Pointer<Utf8>);
typedef _MetadataNative =
    ffi.Pointer<Utf8> Function(ffi.Pointer<_NativeSession>);
typedef _MetadataDart = ffi.Pointer<Utf8> Function(ffi.Pointer<_NativeSession>);
typedef _ConvertNative =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<_NativeSession>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _ConvertDart =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<_NativeSession>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      int,
      int,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _FreeSessionNative = ffi.Void Function(ffi.Pointer<_NativeSession>);
typedef _FreeSessionDart = void Function(ffi.Pointer<_NativeSession>);
typedef _StringNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _StringDart = void Function(ffi.Pointer<Utf8>);
typedef _LastErrorNative = ffi.Pointer<Utf8> Function();
typedef _LastErrorDart = ffi.Pointer<Utf8> Function();
typedef _OptionsValidateNative = ffi.Bool Function(ffi.Pointer<Utf8>);
typedef _OptionsValidateDart = bool Function(ffi.Pointer<Utf8>);

typedef _ControlCreateNative = ffi.Pointer<ffi.Void> Function();
typedef _ControlCreateDart = ffi.Pointer<ffi.Void> Function();
typedef _ControlActionNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _ControlActionDart = void Function(ffi.Pointer<ffi.Void>);

typedef _ControlChunkEnableNative = ffi.Bool Function(ffi.Pointer<ffi.Void>);
typedef _ControlChunkEnableDart = bool Function(ffi.Pointer<ffi.Void>);
typedef _ControlChunkTakeNative =
    ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>);
typedef _ControlChunkTakeDart =
    ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>);
typedef _StreamingConvertNative =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<_NativeSession>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _StreamingConvertDart =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<_NativeSession>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      int,
      int,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
