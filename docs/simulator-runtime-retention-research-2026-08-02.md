# Simulator Runtime Retention and Re-download Research

Date: 2026-08-02

## What a runtime is

An iOS Simulator runtime is an OS package. Multiple simulated device types can
share one runtime, so deleting a simulated iPhone does not remove its runtime.
Apple documents separate workflows for removing devices and removing runtimes.
[Apple: Adding additional simulators](https://developer.apple.com/documentation/safari-developer-tools/adding-additional-simulators)

## Retention: expected, not recreation

Xcode treats simulator runtimes as optional components. They remain installed
until removed in **Xcode > Settings > Components**; selecting a runtime and
using Delete is the supported removal path and is intended to recover its
storage. Therefore, an old runtime that remains after device deletion was
retained, not recreated.
[Apple: Downloading and installing additional Xcode components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)

## Documented ways a runtime can be downloaded again

Apple documents these explicit triggers:

1. A user selects **Get** in Components or chooses a released version through
   **Add Platforms > Download & Install**.
2. A project with no runtime for its platform displays **Get** at the run
   destination or canvas; clicking it downloads the latest runtime.
3. A command or automation invokes `xcodebuild -downloadPlatform`,
   `xcodebuild -downloadAllPlatforms`, or imports a downloaded runtime.
4. A command invokes `xcodebuild -runFirstLaunch -checkForNewerComponents`.
   Apple states that this checks for newer components, saves their packages in
   `~/Library/Developer/Packages/`, and installs them for the selected Xcode.

These are install/update actions. They differ from passive retention: a
runtime only reappearing after one of them is a re-download or re-install.
[Apple: Downloading and installing additional Xcode components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)

## What Apple does not document

The Apple documentation reviewed does not describe a general background policy
where CoreSimulator silently recreates every runtime that the user deleted.
Consequently, repeated reappearance should be investigated as a concrete
download/install trigger (Xcode UI interaction, an Xcode setup/update command,
or automation), rather than assumed to be routine CoreSimulator retention.

An OS update can also make an already-installed runtime unavailable. Apple DTS
documents that case and tells the developer to reboot and use **Get** again if
the runtime is missing. That is a recovery download prompted by the user, not
evidence of an automatic recreation policy.
[Apple DTS: Resolving a “Simulator runtime is not available” error](https://developer.apple.com/forums/thread/751135)

## Disk-image state is a separate failure mode

Apple documents that manually detaching a runtime disk image can leave Xcode
and Simulator unable to determine whether the runtime is installed. In that
state, a re-download attempt can fail with a duplicate-runtime error; restart
remounts the image. This is a registration/mount-state issue, not proof that a
runtime was newly downloaded.
[Apple: Xcode 14 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-14-release-notes)

## Practical conclusion

Use Components to delete unused runtimes, and independently delete unneeded
simulated devices. If iOS 18.3 or 18.6 returns, identify the action immediately
before it returns: a Components/Run Destination **Get** click, an Xcode setup
or update command, or automation calling one of the documented `xcodebuild`
download commands. The cited Apple materials do not support attributing that
behavior to a universal CoreSimulator background re-creation mechanism.

## Official Apple sources

- [Downloading and installing additional Xcode components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)
- [Adding additional simulators](https://developer.apple.com/documentation/safari-developer-tools/adding-additional-simulators)
- [Xcode 14 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-14-release-notes)
- [Apple DTS: Resolving a “Simulator runtime is not available” error](https://developer.apple.com/forums/thread/751135)
