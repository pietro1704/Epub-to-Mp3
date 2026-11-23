/// JSON shapes of the shared `converter_tts_model_install_operation_*` protocol.
/// The Rust operation owns the state machine, the checksums and the storage
/// layout; clients only download the artifacts it asks for and report progress.
enum ModelInstallStage {
  preflight,
  downloading,
  verifying,
  publishing,
  completed,
  cancelled,
  failed;

  static ModelInstallStage parse(String? value) => ModelInstallStage.values
      .firstWhere((stage) => stage.name == value, orElse: () => preflight);

  bool get terminal =>
      this == completed || this == cancelled || this == failed;
}

class ModelInstallFailure {
  const ModelInstallFailure({
    required this.kind,
    required this.message,
    this.requiredBytes,
    this.availableBytes,
  });

  factory ModelInstallFailure.fromJson(Map<String, dynamic> json) =>
      ModelInstallFailure(
        kind: json['kind'] as String? ?? 'unknown',
        message: json['message'] as String? ?? '',
        requiredBytes: (json['required_bytes'] as num?)?.toInt(),
        availableBytes: (json['available_bytes'] as num?)?.toInt(),
      );

  final String kind;
  final String message;
  final int? requiredBytes;
  final int? availableBytes;
}

/// One progress step of an installation, as the Rust operation reports it.
class ModelInstallEvent {
  const ModelInstallEvent({
    required this.sequence,
    required this.modelId,
    required this.stage,
    required this.bytesCompleted,
    required this.bytesTotal,
    this.operationId = '',
    this.artifactIndex,
    this.failure,
  });

  factory ModelInstallEvent.fromJson(Map<String, dynamic> json) =>
      ModelInstallEvent(
        sequence: (json['sequence'] as num?)?.toInt() ?? 0,
        operationId: json['operation_id'] as String? ?? '',
        modelId: json['model_id'] as String? ?? '',
        stage: ModelInstallStage.parse(json['stage'] as String?),
        artifactIndex: (json['artifact_index'] as num?)?.toInt(),
        bytesCompleted: (json['bytes_completed'] as num?)?.toInt() ?? 0,
        bytesTotal: (json['bytes_total'] as num?)?.toInt() ?? 0,
        failure: json['failure'] is Map
            ? ModelInstallFailure.fromJson(
                Map<String, dynamic>.from(json['failure'] as Map),
              )
            : null,
      );

  final int sequence;
  final String operationId;
  final String modelId;
  final ModelInstallStage stage;
  final int? artifactIndex;
  final int bytesCompleted;
  final int bytesTotal;
  final ModelInstallFailure? failure;

  /// 0..1 over the whole model, or null when the total is not known yet.
  double? get fraction =>
      bytesTotal > 0 ? (bytesCompleted / bytesTotal).clamp(0.0, 1.0) : null;
}

class ModelInstallArtifact {
  const ModelInstallArtifact({
    required this.index,
    required this.name,
    required this.url,
    required this.sha256,
    required this.expectedBytes,
    required this.inboxPath,
    required this.accepted,
  });

  factory ModelInstallArtifact.fromJson(Map<String, dynamic> json) =>
      ModelInstallArtifact(
        index: (json['index'] as num).toInt(),
        name: json['name'] as String,
        url: json['url'] as String,
        sha256: json['sha256'] as String? ?? '',
        expectedBytes: (json['expected_bytes'] as num?)?.toInt() ?? 0,
        inboxPath: json['inbox_path'] as String,
        accepted: json['accepted'] == true,
      );

  final int index;
  final String name;
  final String url;
  final String sha256;
  final int expectedBytes;

  /// Where the client must leave the downloaded file for `accept_download`.
  final String inboxPath;
  final bool accepted;
}

class ModelInstallPlan {
  const ModelInstallPlan({
    required this.operationId,
    required this.modelId,
    required this.requiredBytes,
    required this.availableBytes,
    required this.ready,
    required this.artifacts,
    required this.event,
    this.revision,
  });

  factory ModelInstallPlan.fromJson(Map<String, dynamic> json) =>
      ModelInstallPlan(
        operationId: json['operation_id'] as String? ?? '',
        modelId: json['model_id'] as String? ?? '',
        revision: json['revision'] as String?,
        requiredBytes: (json['required_bytes'] as num?)?.toInt() ?? 0,
        availableBytes: (json['available_bytes'] as num?)?.toInt() ?? 0,
        ready: json['ready'] == true,
        artifacts: [
          for (final artifact in json['artifacts'] as List? ?? const [])
            ModelInstallArtifact.fromJson(
              Map<String, dynamic>.from(artifact as Map),
            ),
        ],
        event: ModelInstallEvent.fromJson(
          Map<String, dynamic>.from(json['event'] as Map? ?? const {}),
        ),
      );

  final String operationId;
  final String modelId;
  final String? revision;
  final int requiredBytes;
  final int availableBytes;

  /// False when preflight refused the installation (for example not enough
  /// free space); the plan's event then carries the failure.
  final bool ready;
  final List<ModelInstallArtifact> artifacts;
  final ModelInstallEvent event;
}
