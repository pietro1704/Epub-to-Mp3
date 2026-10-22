# Collaboration operations

Use this short path for channel diagnostics, transport-only revalidation and
configuration delivery. Product ownership and request/result acceptance remain
in [the collaboration contract](mac-arch-collaboration.md).

## Routine checks

Node LTS and the project Codex CLI use the root `mise.toml` definitions, including
inside the Apple project. Its nested configuration adds XcodeGen only. Use
`mise exec` for those project tools; a standalone Codex app or another tool's
Node on the ambient `PATH` has separate provenance. Inspect `mise ls --current`
and `mise which` before diagnosing a version mismatch; do not update a global
installation to make its version match the project.

```sh
mise run agents:collaboration:doctor -- --role mac
mise run agents:collaboration:test
# Only when queue-fixture mutations are authorized by the current task:
mise run agents:collaboration:revalidate -- --role mac --allow-queue-fixtures
```

On Arch, use `--role arch`. Doctor is read-only: versions, no-TTY SSH, capabilities,
bounded mailbox reads and exact project UUIDs. With installed Arch3.0, project
listing omits UUIDs; doctor verifies the same loopback server's reported database
through SQLite `-readonly`. Missing tools/schema/identity fail closed. Diagnostics
omit auth data, paths and message bodies. They do not repair routing automatically.

The deterministic check uses both mailbox roles as fixtures over the caller's
transport. It verifies duplicate refusal, claim-once, correlated return and exact
cancellation. It is not another agent's acknowledgement or app/device acceptance.
It starts no Codex/model and executes no message body. Fixture task IDs are printed
to stderr before writes, then receipts as they arrive. On interruption/uncertain
delivery, reconcile those exact scopes/IDs before another run. Cleanup only
cancels this run's pending fixtures; unavailable or capped cleanup stays unverified.

Normal preflight and the CI host gate execute the Node collaboration regressions
alongside Ruby guards. They use fixtures and never contact Arch or ai-memory.
Use actual-agent handshakes for initial integration or changed interpretation;
routine transport revalidation uses the deterministic path above.

## Reviewed configuration installation

Use the static `scripts/install_agent_collaboration.mjs`; configuration arrives as
JSON stdin, never as generated JavaScript or shell interpolation:

```json
{
  "version": 1,
  "mode": "plan",
  "root": "/absolute/checkout",
  "aliases": [{"path": "AGENTS.md", "target": "CLAUDE.md"}],
  "backup_dir": "/existing/backup/directory/outside/checkout",
  "files": [{"path": ".agents/collaboration.json", "expected_sha256": null, "content": "reviewed UTF-8 bytes\n"}]
}
```

Use a SHA-256 of each actual existing target; `null` means absent. Prepare complete
reviewed content preserving unrelated bytes. `plan` is read-only. Review its paths
and hashes, then change only `mode` to `apply`. Pass the spec through
`mise run agents:collaboration:install < spec.json`. For Arch, copy the reviewed
installer and JSON as separate files, then run that same static installer there
with the JSON redirected to stdin. Keep SSH noninteractive with `-T` and batch
authentication. Retain the spec and plan/apply receipts outside Git.

The installer allowlists collaboration files, checks all baselines/aliases before
publishing, backs up original bytes outside the checkout, and atomically replaces
each changed file. Reapplying identical content leaves bytes/mtime unchanged.
The root lock serializes cooperating installers; ordinary external edits are
rechecked. This is not a hostile-filesystem transaction or multi-file rollback:
unexpected I/O failure can leave an explicitly reported partial deployment.

For native result collection use `mise run native:xcresult -- BUNDLE -- xcrun
xcresulttool ... --path BUNDLE`. Each canonical bundle has its own lease; independent
bundles can run concurrently. The command's real exit/signal status is retained.
Never parallelize direct xcresulttool reads against the same bundle: reads may
create SQLite files. The Mac checkout's `docs/agent-workflow.md` owns Apple
runtime verification; the Arch checkout may be on an older revision.
