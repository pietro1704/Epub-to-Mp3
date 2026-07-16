import 'package:flutter/material.dart';

import '../models/session_record.dart';

/// Honest detail surface for legacy session records. The sessions endpoint
/// does not expose a backend job id, logs, or telemetry, so this screen never
/// invents those values or makes an invalid job request.
class JobDetailScreen extends StatelessWidget {
  const JobDetailScreen({super.key, required this.session});

  final SessionRecord session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(session.bookTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section(title: 'Job', children: [
            _Value('Started', session.timestamp),
            _Value('Engine', session.engine),
            _Value('Mode', session.mode),
            _Value('Outcome', session.outcome),
          ]),
          _Section(title: 'Telemetry', children: [
            _Value('Chapters converted', session.chaptersConverted?.toString()),
            _Value('Duration', session.durationSeconds == null ? null : '${session.durationSeconds}s'),
          ]),
          _Section(title: 'Logs', children: [
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.info_outline),
              title: Text('Detailed logs are not available for this session.'),
              subtitle: Text('The sessions API exposes summary records only.'),
            ),
          ]),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      );
}

class _Value extends StatelessWidget {
  const _Value(this.label, this.value);
  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        trailing: Text(value ?? 'Not available'),
      );
}
