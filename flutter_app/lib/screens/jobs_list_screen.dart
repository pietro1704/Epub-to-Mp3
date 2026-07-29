import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../state/providers.dart';
import 'job_detail_screen.dart';
import 'settings_screen.dart';

class JobsListScreen extends ConsumerWidget {
  const JobsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final sessions = ref.watch(sessionsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.jobsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(sessionsProvider.future),
        child: sessions.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [ListTile(title: Text(t.errorWithMessage('$e')))],
          ),
          data: (list) {
            if (list.isEmpty) {
              return ListView(children: [ListTile(title: Text(t.noJobs))]);
            }
            return ListView.separated(
              itemCount: list.length,
              // ignore: unnecessary_underscores
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final s = list[i];
                return ListTile(
                  title: Text(s.bookTitle),
                  subtitle: Text(
                    '${s.engine ?? '-'} • ${s.outcome ?? '-'} • ${s.timestamp}',
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => JobDetailScreen(session: s),
                      ),
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}
