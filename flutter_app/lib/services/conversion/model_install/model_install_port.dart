import 'model_install_models.dart';

/// One live installation owned by the shared converter. Calls are synchronous
/// (the converter does no network work); the downloads happen in Dart between
/// them. Every operation must end in [dispose].
abstract interface class ModelInstallOperation {
  ModelInstallPlan plan();
  ModelInstallEvent event();

  /// Reports how many bytes of artifact [index] are on disk.
  void recordProgress(int index, int downloadedBytes);

  /// Hands a downloaded file to the converter, which verifies size and SHA-256.
  void accept(int index, String downloadedPath);

  /// Publishes the verified artifacts and returns the model directory.
  String publish();
  void fail(String kind, String message);
  void cancel();
  void dispose();
}

/// Starts installations. Desktop uses the C ABI; Android will use JNI.
abstract interface class ModelInstallOperations {
  /// Starts a fresh installation. Throws when one is already running for the
  /// same model and storage root.
  ModelInstallOperation begin({
    required String modelId,
    required String root,
    required int availableBytes,
  });

  /// Resumes an interrupted installation, or returns null when none exists.
  ModelInstallOperation? recover({
    required String modelId,
    required String root,
    required int availableBytes,
  });
}
