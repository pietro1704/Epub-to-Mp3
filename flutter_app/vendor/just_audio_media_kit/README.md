# just_audio_media_kit 2.1.0

Source: [just_audio_media_kit 2.1.0](https://pub.dev/packages/just_audio_media_kit/versions/2.1.0), distributed under the accompanying Unlicense.

The local patch adds an optional libmpv network timeout and applies it after
player initialization, before the adapter returns the player to `just_audio`.
Windows uses this setting to tolerate gaps in locally synthesized MP3 streams.
On Linux the adapter requests connection closure for just_audio's loopback
stream route, so libmpv sees EOF when the source ends an unbounded response.
Return to the hosted package when both behaviors are covered upstream.
