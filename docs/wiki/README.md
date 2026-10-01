# Project Wiki

This folder contains a local, versioned wiki for the project in:

- [Português do Brasil](./pt-BR/Home.md)
- [English](./en/Home.md)

Publishing model:

1. Use the files in `docs/wiki/` as the source of truth.
2. Run `bash scripts/github-ci-wiki-wizard.sh` from the repository root to publish them safely to the GitHub Wiki. It asks for confirmation before overwriting wiki content and stages only the TestFlight workflow, `docs/wiki/`, and the wizard itself when committing. TestFlight remains manual-only until an active Apple Developer Program membership and its signing credentials are available.
3. Keep product and architecture changes documented here in the same PR as the code change.

Recommended page order:

1. Home
2. Getting Started
3. CLI and Web Usage
4. Desktop, Mobile, and Releases
5. Architecture
6. Configuration and Performance
7. Deployment and Hugging Face Spaces
8. Troubleshooting
9. Contributing and Security
