# EpubToMp3 — native UIKit/AppKit Apple app

The application uses UIKit on iOS/iPadOS and AppKit on macOS, with embedded
`converter-core`/`converter-ffi`. Shared Rust owns conversion, provider/model
selection, progress, cancellation and artifacts. Apple conversion does not
require the historical HTTP sidecar or a configured remote backend.

Start in `EpubToMp3/App/` for native composition roots and
`EpubToMp3/Features/` for library, reader, playback, conversion and settings.
`Features/Conversion/Services/RustConversionCoordinator.swift` and
`ConverterFFIAdapter.swift` are the embedded conversion seam. See
[runtime navigation](../../docs/agents/runtime-navigation.md) and
[FFI integration](docs/converter-ffi-ios.md).

## Build and validation

Read [execution policy](../../docs/agents/execution-policy.md) and
[macOS validation](../../docs/agents/macos-validation.md) first. Use the smallest
`mac:validate` mode against an explicitly identified existing DerivedData tree;
inspection, packaging, guarded incremental compilation and GUI validation are
separate modes. `mac:build` is the full app task and depends on the host
`converter-ffi:build`, not `sidecar:build`. Inspect current task prerequisites
before starting a dependency rebuild.

`project.yml` defines the generated Xcode project, targets, deployments,
entitlements and platform-specific embedding. `xcode:generate` regenerates and
opens that project; do not create a replacement scaffold or edit generated
`.xcodeproj` structure as the source of truth. All Mac compilation uses guarded
tasks with one compiler job and the shared storage budget. Build output paths
and receipts come from the selected task, not a fixed `.build/Release` guess.

Simulator execution is quarantined. For reader/pagination/chrome/player work,
follow [AGENTS.md](AGENTS.md), `CONTEXT.md`, relevant ADRs and the native reader
skill. Required SE1/iOS 15.5 acceptance stays pending; source wiring or compilation
alone is not evidence that reader, conversion or playback acceptance passed.

## Voice and playback policy

Piper `pt_BR-faber-medium` is primary. Installed system TTS is the default
fallback, preferring Luciana for Brazilian Portuguese when available. Report the
actual voice, retain Piper as primary and retry only at bounded recovery points;
explicit job choices remain authoritative. Edge fallback needs explicit consent.
Install models only through an explicit user action and preserve existing models.
Playback requires an explicit user gesture.

## Shared Apple resources

App Group `group.com.pietrocode.epubtomp3` connects main-app and widget state.
`EpubToMp3/Models/ConversionActivityAttributes.swift` is shared with the widget;
ActivityKit Codable identity and target membership must stay consistent when
changing it. Inspect `project.yml` and current widget sources for platform
availability rather than inferring that all application UI uses the widget's UI
framework or supports the same deployment target.

Entitlements and signing differ by configuration/platform. Verify the current
entitlement files, bundled FFI/ONNX artifacts, platform identity and signatures
at the packaging seam. A source exclusion or retained vendor directory alone
does not establish the contents of an installed app.
