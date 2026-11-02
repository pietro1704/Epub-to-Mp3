# Optional native setup timing

Pass the literal launch argument `-measureStartup` to enable diagnostics, for
example in Xcode's Run scheme arguments. The option is off by default, is not a
saved preference and does not require a model, provider or network connection.
Look for `[StartupTiming]` JSON records in the debug console.

## What is measured

| Phase | Synchronous work covered |
| --- | --- |
| `macos.delegate_creation` | Mac delegate construction, including stored-property initialization |
| `app.library_store_creation` | Default delegate's library constructor |
| `library.decode_apply` | Read, decode and apply the persisted library index |
| `macos.window_setup` | Shipping Mac root/window construction and ordering the window front |
| `runtime.activation` | Existing synchronous activation work and scheduling |
| `runtime.widget_reload_request` | Submitting the widget reload request |
| `maintenance.bookmarks` | Existing bookmark cleanup call |
| `maintenance.fulltext` | Existing full-text cache cleanup call |

Window ordering is not proof that the first frame has appeared on the display.
These scopes do not measure time from process creation to first rendered frame,
asynchronous import/transfer completion, widget rendering or audible playback.
Shared library/activation scopes can appear again after launch. Mac-specific
delegate/window scopes do not describe UIKit scene creation.

## Reading a record

- `traceID` identifies one recorder; the production shared recorder lasts for the
  process. `spanID` distinguishes each invocation within that recorder.
- Start/end values use `DispatchTime.uptimeNanoseconds`, not the wall clock.
  `durationMilliseconds` is their difference divided by 1,000,000.
- `durationKind` is `inclusive_synchronous_scope`. Nested intervals overlap and
  must not be summed. Completion order can differ from span-ID allocation order.
- `outcome` describes returning normally, throwing, or throwing Swift
  `CancellationError`. It does not reinterpret domain results such as a decoded
  library error or wait for background operations.
- Phase identifiers are fixed. Book titles, filenames, operation results and
  error descriptions are not included in records.

Disabled recording does not read the clock or call the sink. Enabled recording
adds diagnostic overhead, including nested log emission. These records alone are
not a before/after benchmark or evidence of a startup speedup.

## Verification

Native XCTest covers exact-argument opt-in, the disabled path, monotonic units,
nested intervals, error/cancellation propagation, concurrent invocation identity,
structured output and actual isolated library decoding. Window ownership is
checked through the shipping `MacApplicationWindowSetup` seam rather than parsing
Swift source.

The opt-in Mac fixture uses `STARTUP_DIAGNOSTICS_ARGUMENT=-measureStartup` and
`EPUB_STARTUP_GUI_ACCEPTANCE=1` as Xcode build settings forwarded by the unit test
plan. It opens the real window setup with an isolated library/defaults, verifies
foreground ownership and retains a screenshot. Without those settings, the GUI
fixture skips and normal diagnostics stay disabled. iPhone runtime acceptance and
the broader combined-app journey remain separate work; Simulator is quarantined.
