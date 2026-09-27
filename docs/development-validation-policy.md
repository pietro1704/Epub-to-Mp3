# Development Validation Policy

This policy applies to feature work and bug fixes across the supported client surfaces.

## Device-first validation

When a change affects a device-capable client, validate the real user flow on a real device before finalizing the implementation:

- iOS/iPadOS: validate on a physical Apple device.
- Android: validate on a physical Android/Samsung device.
- macOS: validate in the native macOS app on the target Mac.

If a platform is affected, its device validation is required; do not treat another platform's result as a substitute. Record unavailable hardware or access as an explicit limitation rather than claiming validation.

## Android–iOS parity

Every mobile feature and bug fix must preserve behavioral parity between Android and iOS/iPadOS. Compare the user-visible flow, state transitions, error handling, and backend contract on both platforms. A platform-specific limitation or intentional difference must be documented and justified.

## Tests

After device validation, add or update only the tests relevant to the changed behavior and its regression risk. Do not add speculative or duplicate coverage. The complete test suite is a CI responsibility and must run in CI; do not run the full suite locally for this workflow.

## Delivery

After the relevant tests pass and the device checks are complete:

1. Review the focused diff and commit it with an English conventional commit message.
2. Push the commit to the project remote.
3. Monitor CI for the pushed commit and resolve failures before calling the work complete.

Documentation-only changes may omit tests and device validation when they do not alter runtime behavior.
