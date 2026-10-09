# Actual-book Simulator validation checkpoint

Continuing the full quality/performance goal, not redefining its acceptance.
Inputs are the original LOTR/Christie EPUBs, SHA256 respectively
`3e1c676b270dfa3fe555eba4d0cb993486e9f00facb7cc92eef250e64efb7c9e` and
`55417053355de78768a0823d3cd203fde5c80bd8026407ffb5766b3f730d11da`.
Both were copied into the isolated Simulator and imported through LibraryStore's
existing seed/import path. Original files, models and listening downloads preserved.
Both covers/titles and two-column Library layout visually verified.

Initial real-book XCTest/UI run `66FB4514-375D-4578-A645-8FC7B84E6B28`:
Christie passed pagination/chrome using test-only buttons; LOTR failed AX hittability.
Production horizontal swipes/coordinate drags subsequently failed to change page
on both books. No clipping was reported on their initial rendered pages; this
does not prove all-page reader correctness. Readiness/geometry instrumentation
showed navigationReady=1, no custom pan callbacks, visible viewport 375x447 inside
a 375x667 window. It did not establish a root cause.

Matching SDK/controller experiment compiled an isolated Xcode 16.4 UI runner,
using the existing app and same data, and reproduced failure (`72035EA7...`).
Pan-owner move (`ECCAEB51...`) and paginated simultaneity (`2B39CA70...`) failed
the same assertion and were reverted. Selection-disable run (`F9784EED...`)
hit the operation deadline and is inconclusive. All temporary production
instrumentation removed. Failing real-book regression tests remain uncommitted.

No conversion or autoplay was started. Conversion/benchmark remains limited to
LOTR 8–9 and Christie 6–7, inclusive zero-based, under the existing scoped native
benchmark contract. Physical-device historical numbers cannot be compared directly
to Simulator results. The broader goal and actual-book navigation remain incomplete.
