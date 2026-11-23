import 'dart:async';

import 'model_install_models.dart';

/// One live installation owned by the shared converter. The converter does no
/// network work; the downloads happen in Dart between calls. Calls are
/// synchronous over the C ABI and asynchronous over the Android channel, hence
/// `FutureOr`. Every operation must end in [dispose].
abstract interface class ModelInstallOperation {
  FutureOr<ModelInstallPlan> plan();
  FutureOr<ModelInstallEvent> event();

  /// Reports how many bytes of artifact [index] are on disk.
  FutureOr<void> recordProgress(int index, int downloadedBytes);

  /// Hands a downloaded file to the converter, which verifies size and SHA-256.
  FutureOr<void> accept(int index, String downloadedPath);

  /// Publishes the verified artifacts and returns the model directory.
  FutureOr<String> publish();
  FutureOr<void> fail(String kind, String message);
  FutureOr<void> cancel();
  FutureOr<void> dispose();
}

/// Starts installations. Desktop uses the C ABI; Android will use JNI.
abstract interface class ModelInstallOperations {
  /// Starts a fresh installation. Throws when one is already running for the
  /// same model and storage root.
  FutureOr<ModelInstallOperation> begin({
    required String modelId,
    required String root,
    required int availableBytes,
  });

  /// Resumes an interrupted installation, or returns null when none exists.
  FutureOr<ModelInstallOperation?> recover({
    required String modelId,
    required String root,
    required int availableBytes,
  });
}
