# Deployment and Hugging Face Spaces

The root `Dockerfile` builds the Rails web client: the Rust/WASM runtime tree
is compiled in a build stage, and the final Ruby image holds the gems, the
application, precompiled assets and the generated runtime (no Node, Rust
toolchain, `converter-server` or model weights). The Space is published from a
`scripts/hf_snapshot.rb` snapshot (`.hf-runtime` is `rails`). Inspect the exact
deployed revision and workflow before diagnosing a hosted service.

The image serves on port 7860 and answers `/api/health` (and `/health`) locally.
These are source configuration values, not proof of a reachable deployment.
The Rails interface needs no server state; any `PERSISTENT_ROOT` storage applies
only to the optional compatibility API. Survival across restarts requires an actual persistent mount and correct paths/
permissions on the service. Preserve cache, outputs, jobs and user data.

R2/object storage is optional and not established by this repository. See the
[conditional R2 reference](../../R2_SETUP.md) before proposing an integration;
old secret names, public URLs and local cleanup endpoints do not prove uploads,
TTL, scheduled deletion or a free service tier.

Inspect `.github/workflows/sync-hf.yml`, release workflows and the exact validated
integrated SHA when publication is explicitly requested. GitHub branch delivery
does not authorize a Hugging Face push, website publication, secret/configuration
change, reboot or rollback. Factory reboot is not a default troubleshooting step.
Use read-only logs/status when authorized and report unknown deployment state.
No service configuration, wiki publication or deployment is performed by editing
these local pages.
