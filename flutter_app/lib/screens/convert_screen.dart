import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['epub', 'pdf'],
    );
    final path = result?.files.single.path;
    if (path != null) setState(() => _filePath = path);
  }

  Future<void> _submit() async {
    final path = _filePath;
    if (path == null || path.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
      _jobId = null;
    });
    try {
      final request = ConversionRequest(
        filePath: path,
        engine: _engine,
        voice: _voice,
        language: _language,
        chapterStart: int.tryParse(_startController.text),
        chapterEnd: int.tryParse(_endController.text),
        includeCover: _includeCover,
        normalizeAudio: _normalizeAudio,
      );
      final starter =
          widget.startConversion ??
          (request) => ref
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
            items: const [
              DropdownMenuItem(value: 'edge', child: Text('Edge TTS')),
              DropdownMenuItem(value: 'piper', child: Text('Piper')),
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
