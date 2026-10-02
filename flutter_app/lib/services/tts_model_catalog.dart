import 'dart:io';

/// Describes a downloadable local speech model and its platform constraints.
class TtsModelDescriptor {
  const TtsModelDescriptor({
    required this.id,
    required this.engine,
    required this.languages,
    required this.platforms,
    required this.downloadBytes,
    required this.qualityRank,
    required this.speedRank,
    required this.defaultRank,
    required this.runtimeAvailable,
    this.downloadUrl,
    this.sha256,
    this.minimumAndroidApi,
  });

  final String id;
  final String engine;
  final Set<String> languages;
  final Set<String> platforms;
  final int downloadBytes;
  final int qualityRank;
  final int speedRank;
  final int defaultRank;
  final bool runtimeAvailable;
  final String? downloadUrl;
  final String? sha256;
  final int? minimumAndroidApi;

  bool supports({
    required String language,
    required String platform,
    int? androidApi,
  }) {
    if (!platforms.contains(platform)) return false;
    if (!languages.contains(language.split('-').first.toLowerCase()))
      return false;
    return platform != 'android' ||
        minimumAndroidApi == null ||
        (androidApi ?? 0) >= minimumAndroidApi!;
  }
}

/// Built-in policy for local conversion. Remote Edge remains selected before
/// this policy when network use is enabled by the caller.
class TtsModelCatalog {
  static const descriptors = <TtsModelDescriptor>[
    TtsModelDescriptor(
      id: 'kokoro-82m',
      engine: 'kokoro',
      languages: {'en'},
      platforms: {'android', 'ios', 'macos', 'linux', 'windows'},
      downloadBytes: 92_889_596,
      qualityRank: 4,
      speedRank: 4,
      defaultRank: 1,
      runtimeAvailable: false,
      minimumAndroidApi: 29,
    ),
    TtsModelDescriptor(
      id: 'piper-default',
      engine: 'piper',
      languages: {'de', 'en', 'es', 'fr', 'it', 'pt'},
      platforms: {'android', 'ios', 'macos', 'linux', 'windows'},
      downloadBytes: 25 * 1024 * 1024,
      qualityRank: 3,
      speedRank: 5,
      defaultRank: 2,
      runtimeAvailable: true,
      minimumAndroidApi: 29,
    ),
    TtsModelDescriptor(
      id: 'melotts',
      engine: 'melotts',
      languages: {'en', 'es', 'fr', 'zh', 'ja', 'ko'},
      platforms: {'macos', 'linux', 'windows'},
      downloadBytes: 150 * 1024 * 1024,
      qualityRank: 4,
      speedRank: 3,
      defaultRank: 3,
      runtimeAvailable: false,
    ),
    TtsModelDescriptor(
      id: 'qwen3-tts-0.6b',
      engine: 'qwen3',
      languages: {'de', 'en', 'es', 'fr', 'it', 'ja', 'ko', 'pt', 'ru', 'zh'},
      platforms: {'macos', 'linux', 'windows'},
      downloadBytes: 700 * 1024 * 1024,
      qualityRank: 5,
      speedRank: 2,
      defaultRank: 4,
      runtimeAvailable: false,
    ),
  ];

  static String platformName({String? override}) {
    if (override != null) return override;
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    return 'unknown';
  }

  static List<TtsModelDescriptor> candidates({
    required String language,
    String? platform,
    int? androidApi,
  }) {
    final selectedPlatform = platformName(override: platform);
    final result =
        descriptors
            .where(
              (model) =>
                  model.runtimeAvailable &&
                  model.supports(
                    language: language,
                    platform: selectedPlatform,
                    androidApi: androidApi,
                  ),
            )
            .toList()
          ..sort((a, b) => a.defaultRank.compareTo(b.defaultRank));
    return result;
  }

  static String defaultEngine({
    required String language,
    String? platform,
    int? androidApi,
  }) =>
      candidates(
        language: language,
        platform: platform,
        androidApi: androidApi,
      ).firstOrNull?.engine ??
      'piper';
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
