# just_audio_media_kit 2.1.0

Source: [just_audio_media_kit 2.1.0](https://pub.dev/packages/just_audio_media_kit/versions/2.1.0), distributed under the accompanying Unlicense.

The local patch adds an optional libmpv network timeout and applies it after
player initialization, before the adapter returns the player to `just_audio`.
Windows uses this setting to tolerate gaps in locally synthesized MP3 streams.
Return to the hosted package when it exposes equivalent configuration.
