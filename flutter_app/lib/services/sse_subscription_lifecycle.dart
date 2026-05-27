import 'dart:async';

/// Wraps `Stream.listen` so that `onError` and `onDone` cancel the
/// subscription before forwarding the callback.
///
/// Pre-slice-35 `book_open_screen._startConversion`'s SSE wiring
/// only cancelled the subscription on a *terminal* snapshot
/// (`snapshot.isTerminal`). If the stream errored out (HTTP 5xx, a
/// transient disconnect that the EventSource client re-reported as
/// an error rather than recovering, etc.) the subscription stayed
/// attached. Any subsequent event still landed in `_handleSnapshot`
/// and silently wrote chapters into the player queue and `_playableChapters`
/// even though the UI was already showing the failed state.
class SseSubscriptionLifecycle {
  static StreamSubscription<T> listen<T>(
    Stream<T> stream, {
    required void Function(T) onData,
    required void Function(Object) onError,
    required void Function() onDone,
  }) {
    late StreamSubscription<T> sub;
    sub = stream.listen(
      onData,
      onError: (Object e, StackTrace _) {
        // Cancel BEFORE forwarding so any synchronously-buffered
        // events the stream has queued are dropped.
        sub.cancel();
        onError(e);
      },
      onDone: () {
        sub.cancel();
        onDone();
      },
    );
    return sub;
  }
}
