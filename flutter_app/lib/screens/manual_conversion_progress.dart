part of 'convert_screen.dart';

class ManualConversionProgress extends StatelessWidget {
  const ManualConversionProgress({
    super.key,
    required this.submitting,
    required this.jobId,
    required this.historyError,
    required this.error,
    required this.onRetry,
  });

  final bool submitting;
  final String? jobId;
  final String? historyError;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (submitting) const LinearProgressIndicator(),
        if (jobId != null) ...[
          const SizedBox(height: 12),
          Text(jobId!, key: const Key('conversion-job-id')),
        ],
        if (historyError != null)
          ListTile(
            leading: const Icon(Icons.warning_amber_outlined),
            title: Text(t.conversionHistorySaveWarning(historyError!)),
          ),
        if (error != null) ...[
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ],
    );
  }
}
