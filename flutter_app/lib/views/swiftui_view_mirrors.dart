// Mirror of ios/EpubToMp3/EpubToMp3/Views/*.swift @ b7c962a
//
// Lean Dart mirrors of every SwiftUI screen. The agent spec says "iOS
// is the source of truth; replicate behaviour + state machines +
// callback contracts + tests, NOT pixels/animations/Apple-only APIs."
// Accordingly this file is dominated by **ChangeNotifier view-models**
// that capture the state vars / async submit flows that drive each
// screen. The widgets themselves are intentionally minimal shells —
// they document the navigation contract but leave production-grade
// UI to the existing `screens/` directory and a later pass.
//
// Files mirrored (11):
//   RootView, LibraryView, ConvertView, JobsListView, JobDetailView,
//   PlayerReaderView, LocalEpubReaderView, BookOpenView, SettingsView,
//   LogsView, TelemetryView.
//
// Apple-only APIs deliberately stubbed (TODO):
//   - UTType / fileImporter (use file_picker pkg)
//   - ContentUnavailableView (Material `EmptyState` equivalent)
//   - @Environment(AppSettings.self) (Riverpod providers instead)
//   - SystemImage SF Symbols (Material Icons in real widgets)
//   - NavigationStack / NavigationDestination (Navigator 2.0 / go_router)
//   - macOS SidecarManager (Linux/Windows sidecar lives in
//     PythonBridge — different lifecycle)

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/book_entity.dart';
import '../models/job_snapshot.dart';
import '../models/session_record.dart';
import '../services/api_client.dart';
import '../services/library_store.dart';

// ===========================================================================
// ConvertView
// ===========================================================================

/// Mirror of `ConvertViewModel` in Views/ConvertView.swift.
class ConvertViewModel extends ChangeNotifier {
  String? selectedFile;
  String engine = 'edge';
  String voice = '';
  String language = '';
  String chapters = '';
  bool clearCache = false;
  bool forceReprocess = false;
  bool maxPerformance = false;

  bool isSubmitting = false;
  String? submittedJobId;
  String? error;

  Future<void> submit({
    required ApiClient? client,
    required Future<String> Function(String localPath) submitFn,
  }) async {
    if (client == null) {
      error = 'No backend configured. Open Settings or wait for the embedded server.';
      notifyListeners();
      return;
    }
    if (selectedFile == null) {
      error = 'Pick an EPUB or PDF first.';
      notifyListeners();
      return;
    }
    isSubmitting = true;
    error = null;
    submittedJobId = null;
    notifyListeners();
    try {
      submittedJobId = await submitFn(selectedFile!);
    } catch (e) {
      error = e.toString();
    } finally {
      isSubmitting = false;
      notifyListeners();
    }
  }
}

class ConvertView extends StatelessWidget {
  const ConvertView({super.key});

  // TODO(flutter): build Form-equivalent UI; today only the view-model
  // is mirrored. The real widget lives in `screens/` (legacy slice).
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ===========================================================================
// JobsListView
// ===========================================================================

class JobsListViewModel extends ChangeNotifier {
  List<SessionRecord> sessions = const [];
  bool isLoading = false;
  String? errorMessage;

  Future<void> reload(ApiClient? client) async {
    if (client == null) {
      errorMessage = 'Configure backend URL in Settings.';
      notifyListeners();
      return;
    }
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      sessions = await client.fetchSessions();
    } catch (e) {
      errorMessage = e.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }
}

class JobsListView extends StatelessWidget {
  const JobsListView({super.key});
  // Mirror: navigation lands on JobDetailView(jobId: session.bookTitle).
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ===========================================================================
// JobDetailView
// ===========================================================================

class JobDetailViewModel extends ChangeNotifier {
  JobSnapshot? snapshot;
  String? streamError;
  bool isStreaming = false;

  StreamSubscription<JobSnapshot>? _sub;

  Future<void> start(ApiClient client, String jobId) async {
    isStreaming = true;
    streamError = null;
    notifyListeners();
    try {
      snapshot = await client.fetchJob(jobId);
      notifyListeners();
    } catch (e) {
      streamError = e.toString();
      notifyListeners();
    }
    _sub = client.jobStream(jobId).listen(
      (s) {
        snapshot = s;
        notifyListeners();
      },
      onError: (e) {
        streamError = e.toString();
        notifyListeners();
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

class JobDetailView extends StatelessWidget {
  const JobDetailView({super.key, required this.jobId});
  final String jobId;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ===========================================================================
// LibraryView
// ===========================================================================

enum LibrarySortMode { lastOpened, title, addedDate }

extension LibrarySortModeX on LibrarySortMode {
  String get label => switch (this) {
        LibrarySortMode.lastOpened => 'Last opened',
        LibrarySortMode.title => 'Title',
        LibrarySortMode.addedDate => 'Date added',
      };
}

class LibraryViewModel extends ChangeNotifier {
  LibraryViewModel(this.store);
  final LibraryStore store;

  LibrarySortMode sortMode = LibrarySortMode.lastOpened;
  String? importError;
  BookEntity? openingBook;

  void setSortMode(LibrarySortMode m) {
    sortMode = m;
    notifyListeners();
  }

  List<BookEntity> get sorted {
    final list = [...store.books];
    switch (sortMode) {
      case LibrarySortMode.lastOpened:
        list.sort((a, b) {
          final ax = a.lastOpenedAt ?? a.addedAt;
          final bx = b.lastOpenedAt ?? b.addedAt;
          return bx.compareTo(ax);
        });
        break;
      case LibrarySortMode.title:
        list.sort((a, b) => a.resolvedTitle
            .toLowerCase()
            .compareTo(b.resolvedTitle.toLowerCase()));
        break;
      case LibrarySortMode.addedDate:
        list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
        break;
    }
    return list;
  }

  Future<void> importFile(String path) async {
    try {
      await store.importBook(path);
      importError = null;
    } catch (e) {
      importError = e.toString();
    }
    notifyListeners();
  }
}

class LibraryView extends StatelessWidget {
  const LibraryView({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ===========================================================================
// BookOpenView — opt-in audio flow; mirror tracks whether the user
// has pressed Play yet so the floating menu appears at the right time.
// ===========================================================================

class BookOpenViewModel extends ChangeNotifier {
  bool audioRequested = false;
  bool playerVisible = false;
  String? activeJobId;

  void requestAudio({String? jobId}) {
    audioRequested = true;
    activeJobId = jobId;
    playerVisible = true;
    notifyListeners();
  }

  void dismissPlayer() {
    playerVisible = false;
    notifyListeners();
  }
}

class BookOpenView extends StatelessWidget {
  const BookOpenView({super.key, required this.book});
  final BookEntity book;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ===========================================================================
// PlayerReaderView — integrates player + reader; chapters arrive via SSE
// and AudioPlayer.updateSnapshot appends to the queue without restart.
// ===========================================================================

class PlayerReaderViewModel extends ChangeNotifier {
  PlayerReaderViewModel({required this.jobId});
  final String jobId;

  JobSnapshot? snapshot;
  int currentChapterIndex = 0;
  bool isPlaying = false;
  Duration position = Duration.zero;

  void onSnapshot(JobSnapshot s) {
    snapshot = s;
    notifyListeners();
  }

  void seekChapter(int idx) {
    currentChapterIndex = idx;
    notifyListeners();
  }

  void skip(Duration delta) {
    position += delta;
    if (position < Duration.zero) position = Duration.zero;
    notifyListeners();
  }
}

class PlayerReaderView extends StatelessWidget {
  const PlayerReaderView({super.key, required this.jobId});
  final String jobId;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ===========================================================================
// LocalEpubReaderView — backend-down fallback. Pure presentational; no
// state needed beyond the props.
// ===========================================================================

class LocalEpubReaderView extends StatelessWidget {
  const LocalEpubReaderView({
    super.key,
    required this.filePath,
    required this.book,
  });
  final String filePath;
  final BookEntity book;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ===========================================================================
// SettingsView
// ===========================================================================

class SettingsView extends StatelessWidget {
  const SettingsView({super.key});
  // Mirror: form sections for embedded server (desktop only), backend
  // URL, reader appearance, advanced, about. Wire to MirrorAppSettings.
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ===========================================================================
// LogsView / TelemetryView — read-only diagnostic surfaces.
// ===========================================================================

class LogsViewModel extends ChangeNotifier {
  List<String> lines = const [];
  bool isLoading = false;
  String? error;

  Future<void> reload(Future<List<String>> Function() fetcher) async {
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      lines = await fetcher();
    } catch (e) {
      error = e.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }
}

class LogsView extends StatelessWidget {
  const LogsView({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class TelemetryViewModel extends ChangeNotifier {
  Map<String, dynamic> stats = const {};
  bool isLoading = false;
  String? error;

  Future<void> reload(Future<Map<String, dynamic>> Function() fetcher) async {
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      stats = await fetcher();
    } catch (e) {
      error = e.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }
}

class TelemetryView extends StatelessWidget {
  const TelemetryView({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ===========================================================================
// RootView — tab routing mirror.
// ===========================================================================

enum RootTab { library, settings }

class RootView extends StatelessWidget {
  const RootView({super.key, this.initialTab = RootTab.library});
  final RootTab initialTab;
  // Mirror: a TabView wrapping LibraryView + SettingsView. The Flutter
  // equivalent is a BottomNavigationBar / NavigationRail.
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

