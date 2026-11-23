part of 'settings_screen.dart';

typedef _NarrationModelRow = (Map<String, dynamic> model, bool installed);

class InstalledNarrationModelsCard extends ConsumerStatefulWidget {
  const InstalledNarrationModelsCard({super.key});

  @override
  ConsumerState<InstalledNarrationModelsCard> createState() =>
      _InstalledNarrationModelsCardState();
}

class _InstalledNarrationModelsCardState
    extends ConsumerState<InstalledNarrationModelsCard> {
  Future<List<_NarrationModelRow>>? _catalog;
  final Set<String> _changingModels = {};
  final Map<String, ModelInstallEvent> _progress = {};
  final Map<String, ModelInstallCancellation> _cancellations = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _catalog ??= _loadCatalog();
  }

  Future<List<_NarrationModelRow>> _loadCatalog() async {
    final converter = ref.read(embeddedConverterProvider);
    final raw = await converter.ttsModels();
    final models = TtsCatalog.decode(raw).models;
    if (!mounted || models.isEmpty) return const [];
    final root = await ref.read(ttsModelRootProvider.future);
    final rows = <_NarrationModelRow>[];
    for (final model in models) {
      final id = model['id'];
      if (id is! String || id.isEmpty) continue;
      final metadata = await converter.ttsModelMetadata(
        modelId: id,
        root: root,
      );
      rows.add((model, metadata != null));
    }
    return rows;
  }

  void _refresh() {
    ref.invalidate(manualLowCatalogProvider);
    // An install or removal changes what the reader menu and playback see.
    ref.invalidate(installedNarrationModelIdsProvider);
    final catalog = _loadCatalog();
    setState(() {
      _catalog = catalog;
    });
  }

  Future<void> _changeInstallation(
    String modelId, {
    required bool installed,
  }) async {
    if (_changingModels.contains(modelId)) return;
    setState(() => _changingModels.add(modelId));
    try {
      final converter = ref.read(embeddedConverterProvider);
      final root = await ref.read(ttsModelRootProvider.future);
      if (installed) {
        await converter.removeTtsModel(modelId: modelId, root: root);
      } else {
        final cancellation = ModelInstallCancellation();
        // The row shows its progress bar and Cancel from the moment it starts.
        if (mounted) setState(() => _cancellations[modelId] = cancellation);
        ModelInstallEvent? last;
        await for (final event in converter.installTtsModelWithProgress(
          modelId: modelId,
          root: root,
          cancellation: cancellation,
        )) {
          last = event;
          if (mounted && !event.stage.terminal) {
            setState(() => _progress[modelId] = event);
          }
        }
        final failure = last?.failure;
        if (last?.stage == ModelInstallStage.failed && mounted) {
          throw StateError(
            failure == null || failure.message.isEmpty
                ? AppLocalizations.of(context)!.ttsManualModelUnavailable
                : failure.message,
          );
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      _cancellations.remove(modelId);
      if (mounted) {
        _progress.remove(modelId);
        _changingModels.remove(modelId);
        _refresh();
      }
    }
  }

  Widget _modelTile(
    Map<String, dynamic> model, {
    required bool installed,
    required AppLocalizations t,
  }) {
    final modelId = model['id'] as String;
    final progress = _progress[modelId];
    final installing = _cancellations.containsKey(modelId);
    return Column(
      children: [
        ListTile(
          title: Text(modelId),
          subtitle: Text(
            installed ? t.downloadComplete : '${model['languages'] ?? ''}',
          ),
          trailing: installing
              ? IconButton(
                  key: ValueKey('cancel-install-$modelId'),
                  icon: const Icon(Icons.close),
                  tooltip: MaterialLocalizations.of(context).cancelButtonLabel,
                  onPressed: () => _cancellations[modelId]?.cancel(),
                )
              : IconButton(
                  icon: Icon(
                    installed ? Icons.delete_outline : Icons.download_outlined,
                  ),
                  tooltip: installed ? t.remove : t.downloadAll,
                  onPressed: _changingModels.contains(modelId)
                      ? null
                      : () => _changeInstallation(modelId, installed: installed),
                ),
        ),
        if (installing)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: LinearProgressIndicator(
              key: ValueKey('install-progress-$modelId'),
              value: progress?.fraction,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final showLowQuality = ref.watch(showLowQualityModelsProvider);
    final manualCatalog = showLowQuality
        ? ref.watch(manualLowCatalogProvider)
        : null;
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.memory_outlined),
            title: Text(t.downloadAll),
            subtitle: Text(t.useBuiltInEngineDesc),
            trailing: IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: t.refresh,
              onPressed: _refresh,
            ),
          ),
          SwitchListTile(
            title: Text(t.ttsShowLowQuality),
            value: showLowQuality,
            onChanged: (value) =>
                ref.read(showLowQualityModelsProvider.notifier).state = value,
          ),
          if (manualCatalog != null)
            manualCatalog.when(
              skipLoadingOnRefresh: false,
              loading: () =>
                  const ListTile(leading: CircularProgressIndicator()),
              error: (_, _) =>
                  ListTile(subtitle: Text(t.ttsManualModelUnavailable)),
              data: (catalog) => catalog == null
                  ? ListTile(subtitle: Text(t.ttsManualModelUnavailable))
                  : Column(
                      children: [
                        for (final model in catalog.lowDownloadModels)
                          _modelTile(
                            model,
                            installed: _isVerifiedInstallation(model),
                            t: t,
                          ),
                      ],
                    ),
            ),
          FutureBuilder<List<_NarrationModelRow>>(
            future: _catalog,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const ListTile(leading: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return ListTile(subtitle: Text(snapshot.error.toString()));
              }
              return Column(
                children: [
                  for (final (model, installed)
                      in snapshot.data ?? const <_NarrationModelRow>[])
                    _modelTile(model, installed: installed, t: t),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  bool _isVerifiedInstallation(Map<String, dynamic> model) {
    final installation = model['installation'];
    return installation is Map &&
        installation['state'] == 'installed' &&
        model['revision'] != null &&
        installation['verified_revision'] == model['revision'];
  }
}
