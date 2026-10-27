# Player overlay transitions

`PlayerOverlayTransition` owns visibility, animation completion and interactive
restoration for both player overlays. The mini player uses a fade synchronized
with reader chrome timing. The expanded player uses an interruptible vertical
presentation and fade. Root presentation requests visibility through the player
controller instead of assigning `isHidden` and `alpha` on every refresh.

Repeated requests for the same target are no-ops. They preserve the active
completion token, unlike the previous mini-player generation ordering. Reversing
the target invalidates older completions. Immediate hiding invalidates pending
animations before removing them. Metadata/playback updates cannot restart a
transition or reset a live drag.

The dismissal recognizer owns touch admission and drag measurements. Interactive
begin captures the current presentation position/opacity and invalidates the
opening animation. Cancellation restores the visible player; it never commits a
dismissal even after crossing a threshold. Committed dismissal leaves the dragged
transform in place until the presentation owner hides the view, then resets it
while hidden. This avoids the old offscreen-to-identity flash before root hiding.
A stale cancellation cannot reopen a player hidden by another command.

Reduce Motion uses a short fade with no sheet displacement or drag translation.
The expanded view remains an accessibility modal until hidden; the mini player
does not become one. This owner issues no playback, conversion or reader-layout
commands, and retains the same controller/cover/title state across transitions.

Fast Foundation tests cover completion identity, repeated targets, rapid reversal,
immediate hiding, cancellation, thresholds and invalid gesture input. A unit
baseline retaining the old generation order and gesture policy fails; the fixed
policies pass. UIKit tests cover actual view/gesture seams, while visible motion,
interactive reversals and playback continuity remain for the user's final native
campaign. No runtime visual or audible acceptance is implied by the policy tests.
Reader viewport/offset invariants and Simulator quarantine remain unchanged.

Apple references consulted on 2026-10-27:

- [Motion HIG](https://developer.apple.com/design/human-interface-guidelines/motion)
- [UIView animation options](https://developer.apple.com/documentation/uikit/uiview/animationoptions)

Motion should be brief, purposeful, consistent with the gesture and optional
for people who prefer reduced motion. The transition uses current-state
animation and permits interaction rather than locking controls during playback.
