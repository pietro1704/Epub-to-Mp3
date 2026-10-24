part of 'settings_screen.dart';

class InstalledNarrationModelsCard extends ConsumerStatefulWidget {
  const InstalledNarrationModelsCard({super.key});

  @override
  ConsumerState<InstalledNarrationModelsCard> createState() =>
      _InstalledNarrationModelsCardState();
}

class _InstalledNarrationModelsCardState extends ConsumerState<InstalledNarrationModelsCard> {
  Future<List<Map<String, dynamic>>>? _catalog;
  Map<String, String> _installedMetadata = const {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _catalog ??= _loadCatalog();
  }

  Future<List<Map<String, dynamic>>> _loadCatalog() async {
    final raw = await ref.read(embeddedConverterProvider).ttsModels();
    final models = TtsCatalog.decode(raw).models;
    final root = await _modelRoot();
    final metadata = <String, String>{};
    for (final model in models) {
      final id = model['id'];
      if (id is! String || id.isEmpty) continue;
      final value = await ref
          .read(embeddedConverterProvider)
          .ttsModelMetadata(modelId: id, root: root);
      if (value != null) metadata[id] = value;
    }
    if (mounted) _installedMetadata = metadata;
    return models;
  }

  Future<String> _modelRoot() async {
    final directory = await getApplicationSupportDirectory();
    return '${directory.path}/tts-models';
  }

  Future<void> _install(String modelId) async {
    try {
      await ref
          .read(embeddedConverterProvider)
          .installTtsModelFromCatalog(
            modelId: modelId,
            root: await _modelRoot(),
          );
      if (mounted) setState(() => _catalog = _loadCatalog());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Card(
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _catalog,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const ListTile(leading: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ListTile(
              leading: const Icon(Icons.memory_outlined),
              title: Text(t.downloadAll),
              subtitle: Text(snapshot.error.toString()),
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: t.refresh,
                onPressed: () => setState(() => _catalog = _loadCatalog()),
              ),
            );
          }
          final models = snapshot.data ?? const [];
          return Column(
            children: [
              ListTile(
                leading: const Icon(Icons.memory_outlined),
                title: Text(t.downloadAll),
                subtitle: Text(t.useBuiltInEngineDesc),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: t.refresh,
                  onPressed: () => setState(() => _catalog = _loadCatalog()),
                ),
              ),
              for (final model in models)
                ListTile(
                  title: Text('${model['id'] ?? ''}'),
                  subtitle: Text(
                    _installedMetadata.containsKey(model['id'])
                        ? t.downloadComplete
                        : '${model['languages'] ?? ''}',
                  ),
                  trailing: IconButton(
                    icon: Icon(
                      _installedMetadata.containsKey(model['id'])
                          ? Icons.delete_outline
                          : Icons.download_outlined,
                    ),
                    tooltip: _installedMetadata.containsKey(model['id'])
                        ? t.remove
                        : t.downloadAll,
                    onPressed: () => _installedMetadata.containsKey(model['id'])
                        ? _remove('${model['id']}')
                        : _install('${model['id']}'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _remove(String modelId) async {
    try {
      await ref
          .read(embeddedConverterProvider)
          .removeTtsModel(modelId: modelId, root: await _modelRoot());
      if (mounted) setState(() => _catalog = _loadCatalog());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }
}
