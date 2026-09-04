import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/latency_observation.dart';

typedef PdfViewerBuilder =
    Widget Function(
      BuildContext context,
      String path,
      int initialPage,
      ValueChanged<int> onPageChanged,
    );
typedef PdfDocumentLoader = Future<void> Function();

bool isPdfFilePath(String path) => path.toLowerCase().endsWith('.pdf');

class PdfPageStore {
  PdfPageStore(this._prefs);

  final SharedPreferences _prefs;
  static const _prefix = 'reader.pdf.page.';

  int loadPage(String bookId) => _prefs.getInt('$_prefix$bookId') ?? 1;

  Future<void> savePage(String bookId, int page) async {
    await _prefs.setInt('$_prefix$bookId', page.clamp(1, 1 << 30));
  }
}

class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({
    super.key,
    required this.bookId,
    required this.title,
    required this.filePath,
    required this.prefs,
    this.viewerBuilder,
    this.loadDocument,
  });

  final String bookId;
  final String title;
  final String filePath;
  final SharedPreferences prefs;
  final PdfViewerBuilder? viewerBuilder;
  final PdfDocumentLoader? loadDocument;

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  late final PdfPageStore _pages = PdfPageStore(widget.prefs);
  late final PdfViewerController _controller = PdfViewerController();
  late int _page = _pages.loadPage(widget.bookId);
  Object? _error;
  bool _loading = false;
  bool _chromeVisible = true;
  String? _readerJourneyId;

  @override
  void initState() {
    super.initState();
    _readerJourneyId = latencyObservations.begin(
      LatencyJourneyKind.readerOpen,
      LatencyTransition.interactionRequested,
    );
    if (widget.loadDocument == null && !File(widget.filePath).existsSync()) {
      _error = StateError('cannot open PDF: ${widget.filePath}');
      _cancelReaderJourney();
    } else {
      _loading = true;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    try {
      if (widget.loadDocument != null) {
        await widget.loadDocument!();
      } else if (!await File(widget.filePath).exists()) {
        throw StateError('cannot open PDF: ${widget.filePath}');
      }
      if (!mounted) return;
      setState(() => _loading = false);
      _completeReaderJourney();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
      _cancelReaderJourney();
    }
  }

  void _completeReaderJourney() {
    final id = _readerJourneyId;
    if (id == null) return;
    latencyObservations.record(id, LatencyTransition.readerUsable);
    latencyObservations.finish(id);
    _readerJourneyId = null;
  }

  void _cancelReaderJourney() {
    final id = _readerJourneyId;
    if (id == null) return;
    latencyObservations.cancel(id);
    _readerJourneyId = null;
  }

  void _pageChanged(int page) {
    if (page < 1) return;
    setState(() => _page = page);
    unawaited(_pages.savePage(widget.bookId, page));
  }

  Widget _viewer() {
    final builder = widget.viewerBuilder;
    if (builder != null) {
      return builder(context, widget.filePath, _page, _pageChanged);
    }
    return PdfViewer.file(
      widget.filePath,
      controller: _controller,
      initialPageNumber: _page,
      params: PdfViewerParams(
        onPageChanged: (page) {
          if (page != null) _pageChanged(page);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _chromeVisible
          ? AppBar(
              title: Text(widget.title),
              actions: [
                IconButton(
                  tooltip: 'Hide controls',
                  onPressed: () => setState(() => _chromeVisible = false),
                  icon: const Icon(Icons.fullscreen),
                ),
              ],
            )
          : null,
      body: Stack(
        children: [
          Positioned.fill(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      key: Key('pdf-reader-loading'),
                    ),
                  )
                : _error != null
                ? _errorView()
                : _viewer(),
          ),
          if (_chromeVisible && !_loading && _error == null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Card(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      tooltip: 'Previous page',
                      onPressed: _page > 1 ? () => _goToPage(_page - 1) : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Text('Page $_page'),
                    IconButton(
                      tooltip: 'Next page',
                      onPressed: () => _goToPage(_page + 1),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ),
            ),
          if (!_chromeVisible)
            Positioned(
              top: 12,
              right: 12,
              child: FloatingActionButton.small(
                tooltip: 'Show controls',
                onPressed: () => setState(() => _chromeVisible = true),
                child: const Icon(Icons.fullscreen_exit),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _goToPage(int page) async {
    if (page < 1) return;
    await _controller.goToPage(pageNumber: page);
  }

  Widget _errorView() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline),
        const SizedBox(height: 12),
        Text('PDF error: $_error', textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () {
            setState(() {
              _loading = true;
              _error = null;
            });
            unawaited(_load());
          },
          child: const Text('Retry'),
        ),
      ],
    ),
  );
}
