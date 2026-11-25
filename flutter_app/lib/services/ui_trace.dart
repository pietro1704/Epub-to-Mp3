import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Verification-only record of what the app shows (`EPUB2MP3_UI_TRACE=<file>`).
///
/// The packaged Windows journey reads this instead of scraping the Flutter
/// accessibility tree, which cannot expose long reader text. Disabled (and free)
/// unless the variable names a file; it appends one JSON object per line and
/// never throws into the app.
class UiTrace {
  UiTrace(this.path);

  /// The trace file, or null when tracing is off.
  final String? path;

  bool get enabled => path != null && path!.isNotEmpty;

  /// Longest text a field may carry: enough to identify a passage, never a book.
  static const maxText = 200;

  static UiTrace? _override;
  static final UiTrace _fromEnvironment = UiTrace(
    kIsWeb ? null : Platform.environment['EPUB2MP3_UI_TRACE'],
  );

  static UiTrace get instance => _override ?? _fromEnvironment;

  /// Tests substitute the trace; null restores the environment one.
  @visibleForTesting
  static void override(UiTrace? trace) => _override = trace;

  /// Flutter builds the accessibility tree only once an assistive client asks, which
  /// races with the journey's first lookup; while tracing it is simply kept on.
  SemanticsHandle? keepSemanticsOn() =>
      enabled ? SemanticsBinding.instance.ensureSemantics() : null;

  String? _lastSnapshot;

  /// After every frame, records what is on screen from Flutter's own semantics tree: each labelled
  /// node with its place (logical pixels from the window origin) and whether it is a button. The
  /// packaged Windows journey clicks and reads from this instead of the native accessibility tree,
  /// which Windows exposes empty on some runners. Only changes are written.
  void startSemanticsSnapshots() {
    if (!enabled) return;
    void capture(Duration _) {
      try {
        // Each view's render tree owns its semantics; the first view is the app window.
        final views = RendererBinding.instance.renderViews;
        final root = views.isEmpty
            ? RendererBinding.instance.rootPipelineOwner.semanticsOwner?.rootSemanticsNode
            : views.first.owner?.semanticsOwner?.rootSemanticsNode;
        if (root != null) {
          final nodes = <Map<String, Object?>>[];
          void walk(SemanticsNode node, Matrix4 parent) {
            final transform = node.transform == null ? parent : parent.multiplied(node.transform!);
            final data = node.getSemanticsData();
            // Icon buttons (Back, More) carry their name as a tooltip, not a label.
            final text = [data.label, data.value, if (data.label.isEmpty) data.tooltip]
                .where((part) => part.isNotEmpty)
                .join(' ')
                .trim();
            if (text.isNotEmpty && !node.isInvisible) {
              final rect = MatrixUtils.transformRect(transform, node.rect);
              nodes.add({
                'label': text.length > maxText ? text.substring(0, maxText) : text,
                'button': data.flagsCollection.isButton,
                'left': rect.left.round(),
                'top': rect.top.round(),
                'width': rect.width.round(),
                'height': rect.height.round(),
              });
            }
            node.visitChildren((child) {
              walk(child, transform);
              return true;
            });
          }

          walk(root, Matrix4.identity());
          final dpr = PlatformDispatcher.instance.views.isEmpty
              ? 1.0
              : PlatformDispatcher.instance.views.first.devicePixelRatio;
          final snapshot = jsonEncode(nodes);
          if (snapshot != _lastSnapshot) {
            _lastSnapshot = snapshot;
            emit('ui.semantics', {'dpr': dpr, 'nodes': nodes});
          }
        }
      } catch (_) {
        // Tracing must never affect the app.
      }
      SchedulerBinding.instance.addPostFrameCallback(capture);
    }

    SchedulerBinding.instance.addPostFrameCallback(capture);
    SchedulerBinding.instance.scheduleFrame();
  }

  void emit(String event, [Map<String, Object?> fields = const {}]) {
    if (!enabled) return;
    try {
      final line = jsonEncode({
        't': DateTime.now().millisecondsSinceEpoch,
        'event': event,
        for (final entry in fields.entries) entry.key: _bounded(entry.value),
      });
      File(path!).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Tracing must never affect the app.
    }
  }

  static Object? _bounded(Object? value) =>
      value is String && value.length > maxText ? value.substring(0, maxText) : value;
}
