import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../services/manual_conversion_output.dart';
import '../services/platform_voice_notice.dart';
import '../services/embedded_converter.dart';
import '../services/desktop_embedded_converter.dart';
import 'library_screen.dart' show libraryStoreProvider;

import '../state/providers.dart';
import '../l10n/app_localizations.dart';
import '../models/tts_preferences.dart';

class ConversionRequest {
  const ConversionRequest({
    required this.filePath,
    required this.engine,
    required this.voice,
    required this.language,
    this.ttsPreferences = const TtsPreferences.appDefaults(),
    this.chapterStart,
    this.chapterEnd,
    this.includeCover = true,
    this.normalizeAudio = true,
  });

  final TtsPreferences ttsPreferences;
  final String filePath;
  final String engine;
  final String voice;
  final String language;
  final int? chapterStart;
  final int? chapterEnd;
  final bool includeCover;
  final bool normalizeAudio;
}

typedef ConversionStarter = Future<String> Function(ConversionRequest request);

class ConvertScreen extends ConsumerStatefulWidget {
  const ConvertScreen({super.key, this.initialFilePath, this.startConversion});

  final String? initialFilePath;
  final ConversionStarter? startConversion;

  @override
  ConsumerState<ConvertScreen> createState() => _ConvertScreenState();
}

class _ConvertScreenState extends ConsumerState<ConvertScreen> {
  late String? _filePath = widget.initialFilePath;
  List<TtsSelection> _usedSelections = const [];
  String _engine = 'preferences';
  bool _allowSecondary = false;
  String _voice = 'pt-BR-AntonioNeural';
  String _language = 'pt';
  final _startController = TextEditingController();
  final _endController = TextEditingController();
  bool _includeCover = true;
  bool _normalizeAudio = true;
  bool _submitting = false;
  String? _jobId;
  String? _error;
  String? _historyError;
  final _voiceSession = PlatformVoiceNoticeSession();
  StreamSubscription<dynamic>? _voiceSubscription;
  AndroidEmbeddedConverter? _activeAndroidConverter;
  DesktopEmbeddedConverter? _activeDesktopConverter;
  String? _activeNativeOutputPath;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.android) {
      _voiceSubscription = _voiceSession.listen(() {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              platformVoiceNotice(Localizations.localeOf(context).languageCode),
            ),
          ),
        );
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final requested = ref.read(manualDownloadRequestProvider);
      if (!mounted || requested == null) return;
      ref.read(manualDownloadRequestProvider.notifier).state = null;
      setState(() {
        _filePath = requested;
        _error = null;
        _jobId = null;
      });
      _submit();
    });
  }

  @override
  void dispose() {
    final converter = _activeAndroidConverter;
    final output = _activeNativeOutputPath;
    if (_submitting && output != null && converter != null) {
      unawaited(converter.cancelConversion(outputPath: output));
    }
    if (_submitting && output != null && _activeDesktopConverter != null) {
      unawaited(_activeDesktopConverter!.cancelConversion(outputPath: output));
    }
    _voiceSession.end();
    _voiceSubscription?.cancel();
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ConvertScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialFilePath != oldWidget.initialFilePath &&
        widget.initialFilePath != null) {
      _filePath = widget.initialFilePath;
    }
  }

  Future<void> _pickFile() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        const channel = MethodChannel('epub_to_mp3/incoming_documents');
        final path = await channel.invokeMethod<String>('pickDocument');
        if (!mounted || path == null || path.isEmpty) return;
        setState(() {
          _filePath = path;
          _error = null;
          _jobId = null;
        });
      } on PlatformException catch (error) {
        if (mounted) setState(() => _error = error.message ?? error.code);
      }
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['epub', 'pdf'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (!mounted) return;
    if (path == null || path.isEmpty) {
      setState(
        () => _error = 'The selected file is not accessible on this device.',
      );
      return;
    }
    setState(() {
      _filePath = path;
      _error = null;
      _jobId = null;
    });
  }

  Future<void> _submit() async {
    final path = _filePath;
    if (path == null || path.isEmpty || _submitting) return;
    final startedAt = DateTime.now().toUtc();
    final jobStore = ref.read(localConversionJobStoreProvider);
    final matchingBooks = ref
        .read(libraryStoreProvider)
        .books
        .where((book) => book.filePath == path);
    final bookId = matchingBooks.isEmpty ? path : matchingBooks.first.id;
    setState(() {
      _submitting = true;
      _error = null;
      _historyError = null;
      _jobId = null;
      _usedSelections = const [];
    });
    try {
      final saved = ref.read(settingsProvider).ttsPreferences;
      final manualPrimary = _engine == 'piper'
          ? TtsSelection.faber
          : TtsSelection(engine: 'edge', voice: _voice);
      final selected = _engine == 'preferences'
          ? saved
          : TtsPreferences(
              primary: manualPrimary,
              secondary:
                  _allowSecondary &&
                      jsonEncode(saved.secondary?.toJson()) !=
                          jsonEncode(manualPrimary.toJson())
                  ? saved.secondary
                  : null,
              allowOnlineFallback: _allowSecondary && saved.allowOnlineFallback,
              policyVersion: saved.policyVersion,
            );
      final request = ConversionRequest(
        filePath: path,
        ttsPreferences: selected,
        engine: selected.primary.engine,
        voice: selected.primary.voice ?? selected.primary.modelId ?? '',
        language: _language,
        chapterStart: int.tryParse(_startController.text),
        chapterEnd: int.tryParse(_endController.text),
        includeCover: _includeCover,
        normalizeAudio: _normalizeAudio,
      );
      final starter =
          widget.startConversion ??
          (request) async {
            if (!kIsWeb &&
                (defaultTargetPlatform == TargetPlatform.android ||
                    defaultTargetPlatform == TargetPlatform.linux ||
                    defaultTargetPlatform == TargetPlatform.windows)) {
              final root = await getApplicationDocumentsDirectory();
              final output =
                  '${root.path}/audiobooks/${DateTime.now().millisecondsSinceEpoch}';
              _activeNativeOutputPath = output;
              final converter = ref.read(embeddedConverterProvider);
              if (converter is AndroidEmbeddedConverter) {
                _activeAndroidConverter = converter;
              }
              if (converter is DesktopEmbeddedConverter) {
                _activeDesktopConverter = converter;
              }
              final support = await getApplicationSupportDirectory();
              return converter.convert(
                optionsJson: request.ttsPreferences.optionsJson(
                  modelsRoot: '${support.path}/tts-models',
                  language: request.language,
                ),
                inputPath: request.filePath,
                outputPath: output,
                chapterStart: request.chapterStart,
                chapterEnd: request.chapterEnd,
              );
            }
            throw EmbeddedConverterUnavailable(
              'No local Rust conversion adapter is registered for this platform.',
            );
          };
      _voiceSession.begin(request.filePath);
      final result = await starter(request);
      var jobId = result;
      var actual = <TtsSelection>[];
      var nativeFallbackUsed = false;
      String? historyError;
      try {
        var raw = result;
        final manifestFile = File(raw);
        if (raw.endsWith('.json') && manifestFile.isAbsolute) {
          raw = await manifestFile.readAsString();
        }
        Map<String, dynamic>? completedManifest;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            completedManifest = Map<String, dynamic>.from(
              decoded['manifest'] is Map ? decoded['manifest'] as Map : decoded,
            );
          }
        } on FormatException {
          // An injected legacy ID does not establish a manifest or history.
          if (raw.trimLeft().startsWith('{') || raw != result) rethrow;
        }
        if (completedManifest != null) {
          if (completedManifest['jobId'] is String) {
            jobId = completedManifest['jobId'] as String;
          }
          nativeFallbackUsed = completedManifest['fallbackUsed'] == true;
          actual = (completedManifest['usedSelections'] as List? ?? const [])
              .whereType<Map>()
              .map(
                (value) =>
                    TtsSelection.fromJson(Map<String, dynamic>.from(value)),
              )
              .toList();
          await jobStore.saveCompletedManifest(
            manifest: completedManifest,
            bookId: bookId,
            startedAt: startedAt,
            outputDirectory: manualConversionOutputDirectory(
              requestOutputDirectory: _activeNativeOutputPath,
              jobId: jobId,
              android: _activeAndroidConverter != null,
            ),
            conversionOptionsJson: request.ttsPreferences.optionsJson(
              language: request.language,
            ),
          );
          if (mounted) {
            ref.invalidate(localConversionHistoryProvider);
          }
        }
      } catch (error) {
        // The native operation already completed; a history failure is not
        // a conversion failure and must not invite another synthesis attempt.
        historyError = error.toString();
      }
      if (!mounted) return;
      if (nativeFallbackUsed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.ttsSecondaryUsedNotice),
          ),
        );
      }
      setState(() {
        _jobId = jobId;
        _usedSelections = actual;
        _historyError = historyError;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _submitting = false;
      });
    } finally {
      _voiceSession.end();
      _activeNativeOutputPath = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final jobId = _jobId;
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: const Text('Convert')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          OutlinedButton.icon(
            onPressed: _pickFile,
            icon: const Icon(Icons.attach_file),
            label: Text(_filePath == null ? 'Choose EPUB or PDF' : _filePath!),
          ),
          if (_usedSelections.isNotEmpty)
            Text(
              t.ttsActualVoices(
                _usedSelections
                    .map((selection) => selection.displayName)
                    .join(', '),
              ),
            ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _engine,
            decoration: const InputDecoration(labelText: 'Engine'),
            items: [
              DropdownMenuItem(
                value: 'preferences',
                child: Text(t.ttsUsePreferences),
              ),
              DropdownMenuItem(value: 'piper', child: Text(t.ttsFaberOffline)),
              DropdownMenuItem(value: 'edge', child: Text(t.ttsEdgeOnline)),
            ],
            onChanged: (v) => setState(() => _engine = v ?? _engine),
          ),
          if (_engine != 'preferences')
            SwitchListTile(
              title: Text(t.ttsAllowJobSecondary),
              value: _allowSecondary,
              onChanged: (v) => setState(() => _allowSecondary = v),
            ),
          if (_engine == 'edge')
            DropdownButtonFormField<String>(
              initialValue: _voice,
              decoration: const InputDecoration(labelText: 'Voice'),
              items: const [
                DropdownMenuItem(
                  value: 'pt-BR-AntonioNeural',
                  child: Text('Antonio (pt-BR)'),
                ),
                DropdownMenuItem(
                  value: 'en-US-GuyNeural',
                  child: Text('Guy (en-US)'),
                ),
                DropdownMenuItem(
                  value: 'es-MX-JorgeNeural',
                  child: Text('Jorge (es-MX)'),
                ),
              ],
              onChanged: (v) => setState(() => _voice = v ?? _voice),
            ),
          DropdownButtonFormField<String>(
            initialValue: _language,
            decoration: const InputDecoration(labelText: 'Language'),
            items: const [
              DropdownMenuItem(value: 'pt', child: Text('Portuguese')),
              DropdownMenuItem(value: 'en', child: Text('English')),
              DropdownMenuItem(value: 'es', child: Text('Spanish')),
            ],
            onChanged: (v) => setState(() => _language = v ?? _language),
          ),
          const SizedBox(height: 12),
          const Text(
            'Chapter range',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _startController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'From'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _endController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'To'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text('Options', style: TextStyle(fontWeight: FontWeight.bold)),
          SwitchListTile(
            title: const Text('Include cover'),
            value: _includeCover,
            onChanged: (v) => setState(() => _includeCover = v),
          ),
          SwitchListTile(
            title: const Text('Normalize audio'),
            value: _normalizeAudio,
            onChanged: (v) => setState(() => _normalizeAudio = v),
          ),
          if (_submitting) const LinearProgressIndicator(),
          if (jobId != null) ...[
            const SizedBox(height: 12),
            Text(jobId, key: const Key('conversion-job-id')),
          ],
          if (_historyError != null)
            ListTile(
              leading: const Icon(Icons.warning_amber_outlined),
              title: Text(t.conversionHistorySaveWarning(_historyError!)),
            ),
          if (_error != null) ...[
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            TextButton(onPressed: _submit, child: const Text('Retry')),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _filePath == null || _submitting ? null : _submit,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start conversion'),
          ),
        ],
      ),
    );
  }
}
