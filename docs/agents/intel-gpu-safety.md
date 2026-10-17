# Intel GPU safety and GitHub-only validation

Execution override2026-10-16: all tests/CI are GitHub-only. Local inspection
and implementation may continue; the native build procedure below describes
guards and future authorized execution, not permission to run local tests now.
Read GitHub results periodically and repair actionable failures; merge only
exact-head-green PRs, then remove confirmed-merged branches, leaving master.

### Highest-priority recurrent GPU panic: Intel Simulator quarantine

The user supplied recurrent2026-10-15/16 `IGGuC.cpp:2913` workqueue41 panics
in `AppleIntelKBLGraphics` and `SimMetalHost` for iPhone SE1 on MacBookPro15,2,
macOS24H32. Compressor/swap were OK. The excerpt identifies a graphics-driver
failure path, not general RAM/disk exhaustion or proven build concurrency.
Build/Simulator phase separation alone did not establish prevention.

1. Keep Intel Simulator execution quarantined. `native_job.rb simulator`
   refuses before any child, including inherited leases. Direct `simctl boot`,
   GUI launch, existing artifacts, environment flags or another target cannot
   bypass this policy. Re-enabling requires a new explicit user safety decision
   and specialist review; prior campaign authorization is not a safety reset.
2. Close the tested app, shut down already-active devices and quit Simulator.app.
   Confirm all devices Shutdown and both Simulator.app/SimMetalHost absent.
   Preserve books, models, progress and devices; shutdown is not erasure.
3. Continue independent read-only/host work. For authorized native compilation,
   use `native_job.rb build`: the shared lease is acquired before checking all
   device states and both GPU/UI processes. Inspection failure blocks the child.
   Guard the first Swift interpreter/bootstrap as well as the final compiler.
   Use one job. Edit/Stop hooks only notify; they start no native compilation.
4. Keep the required SE1/iOS15.5 acceptance visibly blocked; a host test, physical
   device or different runtime cannot satisfy it. Preserve screenshots/reports
   from earlier runs as historical evidence. Never claim GPU stability from
   host guard tests. Native macOS runtime/physical-device actions retain their
   own task authorization and data-preservation rules.
5. Before any future approved Simulator execution, design a bounded session
   whose owned-app/device cleanup runs on success, failure and cancellation,
   while the shared lease remains held; confirm shutdown and renderer exit.
   Build-for-testing must precede boot, then test-without-building against
   matching artifacts, Xcode16.4 and the exact SE1/iOS15.5 destination.

These are cooperative harness controls, not OS-wide interception or a verified
GPU driver fix. External tools can bypass repository wrappers; agents must not
use those paths. Do not reproduce the panic, stress the GPU, change renderer or
driver defaults, erase devices, restart services or install runtimes as an
implicit workaround. If safety inspection is inconclusive, preserve evidence
and continue independent work rather than retrying native graphics execution.

### Codex tool hook (registered; trust and interception unverified)

`scripts/native_codex_tool_guard.rb` reads a Codex PreToolUse JSON event and
emits an explicit JSON denial for recognized local native commands. It starts
no native child and prints no command arguments or event content. Invalid input
is denied. A read-only Git common-directory query scopes the hook to this
repository and its worktrees, including an explicit tool working-directory.
It does not trust `GITHUB_ACTIONS` or another environment permission flag.
Recognition runs before Git inspection, so ordinary reads outside a Git checkout
remain available. A recognized native command is scoped using both the session
directory and an explicit tool working-directory; changing only the latter cannot
escape a project session. Inconclusive scope inspection denies recognized risk.
Both documented Bash `command` and direct `exec_command` `cmd` fields are accepted;
conflicting values are denied rather than choosing one.

The recognizer covers known `xcodebuild`, `simctl`, Simulator/app launch, Swift,
Apple Cargo targets, native mise tasks and Flutter execution signatures.
Simple inspection and `simctl shutdown`/`terminate` remain available; combining
cleanup with boot is denied. TTY allocation and recognizable interactive shells
are denied because later `write_stdin` calls do not repeat PreToolUse.
`Shellwords` is only a lexical recognizer: aliases, opaque scripts, encoded or
indirect invocation, pre-existing terminal sessions and unsupported tool paths
can escape. It is neither a complete shell parser nor a sandbox. Conservative
matching can also deny complex inspection commands; use simple read-only calls.
A small quote/escape scan distinguishes literal single-quoted documentation from
known active command compositions and substitutions; it does not implement shell
expansion or claim to recognize every equivalent spelling of a native command.

Activation must preserve every existing ai-memory and RTK hook. Copy the
reviewed script to a stable, user-owned location outside branch checkouts, with
its actual reviewed SHA-256 in the filename; keep that copy immutable by normal
workflow. Review the exact copy, registration and repository scope before adding
this separate entry to the existing user-level `PreToolUse` array:

```json
{
  "matcher": "^Bash$|^exec_command$",
  "hooks": [{
    "type": "command",
    "command": "ruby '/Users/pips/.codex/native-safety/native_codex_tool_guard-<reviewed-sha256>.rb' '/Users/pips/Developer/epubtomp3/.git'",
    "timeout": 5
  }]
}
```

This example is not an installation command. Non-managed hooks require the
user's exact review and trust through `/hooks`; never edit trust state, label
the hook managed, or reuse a trusted memory/RTK hook to bypass that review.
Switching branches must not replace or remove the reviewed executable copy.
On 2026-10-16, the reviewed script with SHA-256
`8406df3c5c5d57612c4b44b4bcc727ca019f8f6fda164cbf68fc8aa908dd34ad`
was copied to that stable location and registered separately in user-level
`hooks.json`. Existing entries were preserved, with a private backup retained.
Registration and copied content were read back; no trust state was modified.
GitHub Native safety run38876434290 passed on Ubuntu and macOS Intel for the
reviewed source. Installed interception has not been exercised locally, and
registration alone does not prove activation. The user's `/hooks` review remains
required; do not describe this hook as active until that gate is satisfied.

The [official Codex hooks documentation](https://learn.chatgpt.com/docs/hooks)
defines `exec_command`'s Bash alias, `tool_input.command` and supported denial
JSON. Nested code-mode tool calls honor denial, but existing stdin sessions
are outside this interception. Matching hooks run concurrently; this guard
cannot prevent another hook from starting work. Hook errors, timeouts and
malformed responses can fail without blocking the tool, so only an actual
supported deny is evidence of interception. GitHub tests exercise the hook
process, temporary Git worktrees and pure recognition; actual installed Codex
interception remains unverified until explicit trust and safe acceptance.
