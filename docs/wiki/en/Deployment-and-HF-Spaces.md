# Deployment and Hugging Face Spaces

The current `Dockerfile` builds React/Vite and the Rust `converter-server`, then
runs that binary in a minimal Debian image. `hf_app.py` remains legacy material,
not the production container entry point. Inspect the exact deployed revision,
selected client mode and workflow before diagnosing a hosted service.

The container declares `PORT=7860`, `HOST=0.0.0.0` and
`PERSISTENT_ROOT=/data/epub-to-mp3`, and probes `/api/health`. These are source
configuration values, not proof of a reachable deployment or persistent storage.
Survival across restarts requires an actual persistent mount and correct paths/
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
