# Android device test farm

The Galaxy A8 and the Galaxy tablet (SM-X620) run tests; they never compile. One APK is built on
the Arch host and installed on both. `scripts/device_farm/device_farm.rb` (host Ruby, no
dependencies) runs a background loop whenever no agent is using adb.

```
ruby scripts/device_farm/device_farm.rb status                 # battery, temperature, lock state, verdict
ruby scripts/device_farm/device_farm.rb build                  # ONE debug APK (verification app id) from integration_test/farm_suite_test.dart
ruby scripts/device_farm/device_farm.rb install                # adb install -r on both devices (data kept)
ruby scripts/device_farm/device_farm.rb regression|monkey|soak # one phase on every healthy device, in parallel
ruby scripts/device_farm/device_farm.rb once                   # one round of everything + the report
ruby scripts/device_farm/device_farm.rb loop                   # forever; `touch $STATE/stop` ends it
ruby scripts/device_farm/device_farm.rb with-adb -- adb ...    # MANUAL adb use: take the lock first
scripts/device_farm/epub2mp3-device-farm.service               # systemd --user unit for the loop
ruby scripts/device_farm/device_farm_test.rb                   # host tests of the rules below
```

`$STATE` is `~/.cache/epub2mp3-device-farm` (override with `DEVICE_FARM_STATE`): the APK, failure
logs (`failures/`), `last-summary.md`, `UNLOCK_<serial>` notes and the `stop` file.

## Rules (enforced in code and tests)

- **Never destructive.** The farm never uninstalls the app, never clears its data and never deletes
  models, books or preferences: `adb` calls go through `safe!`, which refuses `uninstall`, `pm clear`,
  `rm -r`, `wipe`, factory resets and any `settings put` except the verifier toggle. The suite
  restores every preference it touches. The APK is installed with `install -r` (data kept).
- **No tool that removes the app.** `flutter drive` and `flutter test` on a device install the app
  and UNINSTALL it when they finish (found on the first A8 run: it dropped the verification app and
  its data). The regression therefore runs the suite APK directly: it writes the shard file with
  `run-as`, launches the app (whose entrypoint is the integration test) and reads the verdict the
  runner prints to logcat. A host test fails if `device_farm.rb` ever calls `flutter drive/test`.
- **One APK, two shards.** `integration_test/farm_suite_test.dart` reads `files/farm_shard`
  (`a` or `b`; the first serial runs `a`, the second `b`; none = everything). Journeys use icons and
  keys, not labels, so they work in any app language.
- **Health.** A device at or above 41 C, or below 30% battery without a charger, is paused; a
  device whose keyguard is showing is skipped and an `UNLOCK_<serial>` note is written (the owner
  writes `UNLOCK A8` / `UNLOCK TABLET` in the status file and unlocks it).
- **Lock.** The loop takes `/tmp/epub2mp3.adb.lock` for a round and yields to a pending manual
  request between phases. Manual adb use (agents) goes through `with-adb`, which announces itself
  (`<lock>.manual-wanted`) and waits for the farm to release.
- **After every round the app is force-stopped.**

## Phases

- `regression`: the sharded suite above (both devices in parallel).
- `monkey`: `adb shell monkey -p <verification app>` (1500 events, 250 ms throttle, no system keys,
  no app switches); a `FATAL EXCEPTION`, ANR or monkey CRASH is a failure with the logcat excerpt.
- `soak`: background survival: the app is opened, HOME, screen off for 10 minutes, wake; the process
  must be alive without crash or ANR. The long-playback soak (needs an installed model and a book
  fixture on the device) is the next step of the card.

## Reporting

`last-summary.md` is rewritten every round. A failure signature (numbers stripped) is sent ONCE to
epub-coord with `ai-memory message send`, plus a digest every 6 hours; epub-coord turns each new
failure into a red→green card. Failure logs are in `$STATE/failures/`.
