# Apple Playback and CI Stabilization — 2026-08-07

## Scope

This record captures the Apple playback validation and CI reliability repairs
made after commits `362da680` and `7dcd4ed9`.

## Apple simulator baseline

- Validation device: iPhone XR running iOS 17.5.
- XCTest classes must use method-level main-actor isolation with the local
  Swift/Xcode toolchain; class-level isolation produced Swift 6 inheritance
  diagnostics.
- APIs introduced after the installed SDK must be compiler-gated.
- Simulator validation proves the reader/player control flow and command
  dispatch. It does not prove background audio, Lock Screen rendering, or
  Control Center behavior on physical hardware.

## Mini-player constraint contract

- A mini-player has one active bottom owner: root content or tab bar, never
  both at the same time.
- Keep the safe-area fill hidden unless a system accessory specifically needs
  it; otherwise it creates a visible strip beneath the mini-player.
- The host minimum height follows its intrinsic content height so safe-area
  constraints cannot compress the player controls.
- Reproduce layout failures with an LLDB breakpoint on
  `UIViewAlertForUnsatisfiableConstraints`, then exercise reader, player, and
  tab navigation.

## Playback transport contract

- Forward and backward seek defaults are 15 seconds.
- Supported values are 15, 30, 45, and 60 seconds and persist independently.
- The selected intervals are supplied by `AudioPlayer` to the expanded and
  mini players, widget, Control Center, and Lock Screen commands.

## CI incidents and durable controls

| Incident | Evidence | Control |
| --- | --- | --- |
| TestFlight could not download XcodeGen | Run `31188966559`: mise had no recognized GitHub token and reached the unauthenticated API limit. | Pass `MISE_GITHUB_TOKEN` and pin XcodeGen `2.46.0`. |
| TestFlight ran without signing credentials | Run `31198985302` passed the XcodeGen install but found five absent App Store/certificate secrets. | Check credentials before the macOS archive job and skip the signed archive when they are absent. |
| Swift CodeQL could not install XcodeGen | Runs `31187846643`, `31188534458`, and `31189078892`: CodeQL tracing made Homebrew run under Rosetta. | Install with `arch -arm64` before CodeQL initialization and use the authenticated Homebrew API token. |
| Main CI read an obsolete Apple project contract from Python | Run `31189078928`: `test_injection_next_project_config.py` expected removed InjectionNext text. | Remove the cross-boundary test; Apple behavior belongs in XCTest. |
| Scheduled remediation ran without a Codex credential | Runs `31191096485` and `31196095686` failed because `OPENAI_API_KEY` was absent. | Detect the optional credential first and skip remediation when unavailable. |
| Repeated unauthenticated mise bootstrap | `ci.yml` used `curl https://mise.run` in every job. | Use the pinned `jdx/mise-action@v4.2.4` and authenticate mise downloads. |

## Operating procedure

1. Before a push, fetch `origin` and integrate `origin/master`; never
   force-push `master`.
2. After a push, list the new runs and inspect every failure with
   `gh run view <run-id> --log-failed`.
3. Separate product failures from missing optional credentials and external
   tool-resolution failures.
4. Fix the root cause, push the focused change, and wait for all required
   workflows to become green.
