part of 'library_screen.dart';

class LibraryFilterControls extends StatelessWidget {
  const LibraryFilterControls({
    super.key,
    required this.searchQuery,
    required this.selectedTag,
    required this.allTags,
    required this.onSearchChanged,
    required this.onTagChanged,
  });

  final String searchQuery;
  final String? selectedTag;
  final Iterable<String> allTags;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String?> onTagChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          child: SearchBar(
            hintText: t.searchLibrary,
            leading: const Icon(Icons.search),
            trailing: searchQuery.isNotEmpty
                ? [
                    IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () =>
                          onSearchChanged(''),
                    ),
                  ]
                : null,
            onChanged: (v) => onSearchChanged(v),
          ),
        ),
        // Tag filter chips
        if (allTags.isNotEmpty)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(t.allFilter),
                    selected: selectedTag == null,
                    onSelected: (_) =>
                        onTagChanged(null),
                  ),
                ),
                for (final tag in allTags)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(tag),
                      selected: selectedTag == tag,
                      onSelected: (_) => onTagChanged(selectedTag == tag ? null : tag),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
