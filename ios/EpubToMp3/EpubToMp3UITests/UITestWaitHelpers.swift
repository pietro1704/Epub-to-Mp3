import XCTest

/// Polls `condition` every `pollInterval` seconds until it returns `true`, or
/// until `timeout` elapses, whichever comes first — replacing a fixed
/// `usleep` after a UI action whose effect is observable through an
/// accessibility label/element (e.g. `reader.pageIndicator`,
/// `flicker.probe.chapter`, `flicker.probe.summary`).
///
/// The common case (the label updates almost immediately after a tap/gesture)
/// returns in a few polls instead of paying the full fixed delay. The
/// `timeout` is a generous ceiling so a real hang still surfaces as a normal
/// assertion failure afterwards, not an infinite wait.
///
/// This deliberately polls for the caller's actual expected end-state (e.g.
/// "chapter index became N+1"), not merely "the value changed from before" —
/// if the timeout is hit, execution proceeds anyway and the caller's own
/// `XCTAssertEqual`/`XCTAssertTrue` reports the real (unsettled) value
/// instead of the helper silently swallowing a timeout.
///
/// Do NOT use this for deliberate timing probes (e.g. a rapid double-tap
/// meant to land inside an in-flight swap window) or for bursts that
/// intentionally sample state *during* an ongoing transition/animation —
/// those need the transition to still be in flight, so a fixed `usleep`
/// stays correct there. This helper is only for "the action already
/// happened, wait for its (near-instant, observable) effect before moving on".
@discardableResult
func waitUntil(
    timeout: TimeInterval = 2.0,
    pollInterval: TimeInterval = 0.03,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(useconds_t(pollInterval * 1_000_000))
    }
    return condition()
}
