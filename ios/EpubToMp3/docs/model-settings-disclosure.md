# Model settings disclosure

Model management starts collapsed on iOS and macOS. Primary/secondary selection,
online consent and cellular policy remain accessible independently of the model
rows. The summary identifies the configured primary, its installation/readiness
state, and known active, failed or cancelled transfers. Expanding the section
exposes the existing per-model actions; it neither starts nor cancels an install.

`SpeechModelSettingsDisclosure` owns only presentation state and row mapping.
The client retains its snapshot and installation events across toggles and
catalog refreshes. Foreign-model events are ignored by the summary. The AppKit
disclosure button remains the same control during progress updates so progress
cannot replace a button while the user presses it. Selection, installation,
licence acceptance and removal keep their existing owners and confirmations.

Foundation tests cover default/collapse/expand, catalog replacement, empty
catalogs, readiness, transfer failure/cancellation and foreign event identity.
Native UIKit/AppKit tests exercise the actual disclosure without changing the
persisted narration selection; their execution is deferred to the final native
campaign. No model is downloaded or installed by these presentation tests.
