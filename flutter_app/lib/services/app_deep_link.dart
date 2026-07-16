import 'dart:async';

/// A validated app-level URI action. Only links for books already in the
/// library should be acted on by the UI; the parser never creates a book.
class AppDeepLink {
  const AppDeepLink.open(this.bookId) : action = AppDeepLinkAction.open;
  const AppDeepLink.player(this.bookId) : action = AppDeepLinkAction.player;
  const AppDeepLink.jobs() : action = AppDeepLinkAction.jobs, bookId = null;

  final AppDeepLinkAction action;
  final String? bookId;

  static AppDeepLink? parse(Uri uri) {
    if (uri.scheme.toLowerCase() != 'epubtomp3') return null;
    final action = uri.host.toLowerCase();
    if (action == 'jobs') return const AppDeepLink.jobs();
    if (action != 'open' && action != 'player') return null;
    final id = uri.queryParameters['bookId']?.trim();
    if (id == null || id.isEmpty) return null;
    return action == 'open' ? AppDeepLink.open(id) : AppDeepLink.player(id);
  }

  @override
  bool operator ==(Object other) =>
      other is AppDeepLink && other.action == action && other.bookId == bookId;

  @override
  int get hashCode => Object.hash(action, bookId);
}

enum AppDeepLinkAction { open, player, jobs }

/// Converts native URI events into validated app actions. Injecting the URI
/// stream keeps this service deterministic and host-testable.
class AppDeepLinkService {
  AppDeepLinkService(Stream<Uri> source, {Uri? initialUri}) {
    final parsedInitial = initialUri == null
        ? null
        : AppDeepLink.parse(initialUri);
    if (parsedInitial != null) _controller.add(parsedInitial);
    _subscription = source.listen((uri) {
      final link = AppDeepLink.parse(uri);
      if (link != null) _controller.add(link);
    });
  }

  final _controller = StreamController<AppDeepLink>.broadcast();
  late final StreamSubscription<Uri> _subscription;

  Stream<AppDeepLink> get links => _controller.stream;

  Future<void> dispose() async {
    await _subscription.cancel();
    await _controller.close();
  }
}
