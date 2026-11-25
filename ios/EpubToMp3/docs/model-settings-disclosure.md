# Models settings row

iOS Settings shows a single Models row that pushes the Models screen; model rows
never appear inline. The row summary identifies the configured primary, its
installation/readiness state, and known active, failed or cancelled transfers.

`SpeechModelSettingsSummary` owns only that text. Foreign-model events are
ignored. Install progress reconfigures the existing cell, so it never replaces a
row while the user presses it. Selection, installation, licence acceptance and
removal keep their existing owners and confirmations in the Models screen.

Foundation tests cover readiness, transfer failure/cancellation and foreign event
identity. No model is downloaded or installed by these presentation tests.
