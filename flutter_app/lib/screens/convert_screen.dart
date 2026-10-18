import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import '../services/platform_voice_notice.dart';
import '../services/embedded_converter.dart';

import '../state/providers.dart';

class ConversionRequest {
  const ConversionRequest({
    required this.filePath,
    required this.engine,
    required this.voice,
    required this.language,
    this.chapterStart,
    this.chapterEnd,
    this.includeCover = true,
    this.normalizeAudio = true,
  });

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
  String _engine = 'edge';
  String _voice = 'pt-BR-AntonioNeural';
  String _language = 'pt';
  final _startController = TextEditingController();
  final _endController = TextEditingController();
  bool _includeCover = true;
  bool _normalizeAudio = true;
  bool _submitting = false;
  String? _jobId;
  String? _error;
  final _voiceSession = PlatformVoiceNoticeSession();
  StreamSubscription<dynamic>? _voiceSubscription;
  AndroidEmbeddedConverter? _activeAndroidConverter;
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
    final startText = _startController.text.trim();
    final endText = _endController.text.trim();
    final start = int.tryParse(startText);
    final end = int.tryParse(endText);
    bool validPosition(String text, int? position) =>
        text.isEmpty ||
        (RegExp(r'^[0-9]+$').hasMatch(text) &&
            position != null &&
            position <= 2147483647);
    String? rangeError;
    if (!validPosition(startText, start) || !validPosition(endText, end)) {
      rangeError =
          'Chapter positions must be non-negative integers up to 2147483647.';
    } else if (start == null && end != null) {
      rangeError = 'Enter From when specifying To.';
    } else if (start != null && end != null && end < start) {
      rangeError = 'To must be greater than or equal to From.';
    }
    if (rangeError != null) {
      setState(() {
        _error = rangeError;
        _jobId = null;
      });
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _jobId = null;
    });
    try {
      final request = ConversionRequest(
        filePath: path,
        engine: 'edge',
        voice: _voice,
        language: _language,
        chapterStart: start,
        chapterEnd: end,
        includeCover: _includeCover,
        normalizeAudio: _normalizeAudio,
      );
      final starter =
          widget.startConversion ??
          (request) async {
            if (defaultTargetPlatform == TargetPlatform.android) {
              final root = await getApplicationDocumentsDirectory();
              final output =
                  '${root.path}/audiobooks/${DateTime.now().millisecondsSinceEpoch}';
              _activeNativeOutputPath = output;
              final converter = ref.read(embeddedConverterProvider);
              if (converter is AndroidEmbeddedConverter) {
                _activeAndroidConverter = converter;
              }
              return converter.convert(
                inputPath: request.filePath,
                outputPath: output,
                chapterStart: request.chapterStart,
                chapterEnd: request.chapterEnd,
              );
            }
            return ref
                .read(apiClientProvider)
                .uploadAndConvert(
                  request.filePath,
                  engine: request.engine,
                  voice: request.voice,
                  language: request.language,
                  chapterStart: request.chapterStart,
                  chapterEnd: request.chapterEnd,
                  includeCover: request.includeCover,
                  normalizeAudio: request.normalizeAudio,
                );
          };
      _voiceSession.begin(request.filePath);
      final jobId = await starter(request);
      if (!mounted) return;
      setState(() {
        _jobId = jobId;
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
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _engine,
            decoration: const InputDecoration(labelText: 'Engine'),
            items: [
              const DropdownMenuItem(value: 'edge', child: Text('Edge TTS')),
            ],
            onChanged: (v) => setState(() => _engine = v ?? _engine),
          ),
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
            if (defaultTargetPlatform != TargetPlatform.android)
              StreamBuilder(
                stream: ref.read(apiClientProvider).jobStream(jobId),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Text('Progress error: ${snapshot.error}');
                  }
                  final value = snapshot.data;
                  final progress = value?.progressPercent;
                  return Column(
                    children: [
                      LinearProgressIndicator(
                        value: progress == null ? null : progress / 100,
                      ),
                      if (value != null)
                        Text(
                          '${value.state} ${progress?.toStringAsFixed(0) ?? ''}%',
                        ),
                    ],
                  );
                },
              ),
          ],
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
