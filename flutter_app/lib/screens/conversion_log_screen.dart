import 'package:flutter/material.dart';

import '../services/conversion_log_source.dart';

class ConversionLogScreen extends StatefulWidget {
  const ConversionLogScreen({super.key, required this.jobId});
  final String jobId;

  @override
  State<ConversionLogScreen> createState() => _ConversionLogScreenState();
}

class _ConversionLogScreenState extends State<ConversionLogScreen> {
  late Future<List<String>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<String>> _load() async {
    try {
      return await EmbeddedConversionLogSource().read(widget.jobId);
    } catch (error) {
      return ['Rust conversion log unavailable: $error'];
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Conversion log'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => setState(() => _future = _load()),
            ),
          ],
        ),
        body: FutureBuilder<List<String>>(
          future: _future,
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            final lines = snapshot.data!;
            if (lines.isEmpty) return const Center(child: Text('No Rust log entries yet.'));
            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: lines.length,
              itemBuilder: (_, index) => SelectableText(lines[index]),
            );
          },
        ),
      );
}
