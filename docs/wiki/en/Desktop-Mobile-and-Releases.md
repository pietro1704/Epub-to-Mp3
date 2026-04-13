# Desktop, Mobile, and Releases

## Desktop

The desktop app uses:

- `Tauri` as the native shell
- the React frontend in `web/`
- a packaged Python sidecar for the backend

## Main tasks

Desktop local server:

```bash
mise run desktop:server
```

Build the sidecar:

```bash
mise run desktop:sidecar
```

Build the desktop frontend:

```bash
mise run desktop:web
```

Build the desktop app:

```bash
mise run desktop:build
```

Dev mode:

```bash
mise run desktop:dev
```

## Mobile

The repository also produces mobile artifacts in CI.

Mobile web bundle:

```bash
mise run mobile:build
```

Native packages are built by release workflows.

## Releases

The pipeline publishes:

- nightly builds from the main branch
- versioned releases from tags

Common artifacts:

- macOS `.dmg`
- Windows `.exe` / `.msi`
- Linux `.flatpak`, `.snap`, `.AppImage`, `.deb`
- Android `.apk`
- iOS `.ipa`
