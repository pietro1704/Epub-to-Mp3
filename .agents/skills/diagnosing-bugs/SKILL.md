---
name: diagnosing-bugs
description: Diagnose a reported failure or performance regression using a real reproduction, a focused fix and runtime evidence.
---

# Diagnosing bugs

Use the short path first. Read the affected runtime's navigation and relevant
ADRs when needed to locate its seam. Repository execution policy governs all
commands; this skill grants no device, Simulator, network or publication access.

## Short path

1. **Reproduce.** Capture the exact symptom and source/build identity with the
   real tool or app the user exercised. Select an existing focused command or
   normal GUI flow and retain its output. For packaging/linker failures, use a
   copy of the real artifact and actual platform tools before changing mocks;
   preserve the original artifact. A log message alone does not prove a product
   failure: identify the observable behavior it accompanies.
2. **Fix.** Identify the smallest cause supported by that reproduction and change
   only its owning seam. A known tool diagnostic with a direct repro does not
   need a multi-phase investigation or a fixed number of hypotheses.
3. **Regress.** Exercise the real failing boundary, adding regression coverage
   when behavior changes. Demonstrate red-before/green-after when feasible;
   cover success and relevant failure, cancellation or identity cases. Mocks
   supplement real-tool checks, especially for signing and binary mutations.
   Rerun the original app journey when app behavior is affected.
4. **Review.** Inspect the final diff against coding standards. Remove temporary
   probes, report exact results and unresolved limits, and stop when the scoped
   acceptance passes. The reviewer checks scope, test quality and evidence;
   unrelated cleanup or architecture work requires separate concrete need.

Prefer compatible incremental artifacts. Explain dependency rebuilds before
starting them and separate preparation/build duration from test execution.
If the user takes over an Xcode check, record app acceptance as pending until
its result is received; do not count the handoff as a passed test.

## Expand only when evidence requires it

Expand when the real symptom cannot be reproduced, the cause remains ambiguous,
the fix fails the original journey, or measurements show a performance problem.
Name the unresolved question and the next bounded experiment before widening.

- Narrow the reproduction to the smallest scenario that still fails, preserving
  the user's actual symptom. Reuse captured input, logs and artifacts.
- Rank only plausible competing causes and state a falsifiable prediction for
  each. Change one variable per experiment; use a debugger or targeted probe
  that distinguishes those predictions.
- For timing or performance failures, record a comparable baseline and candidate
  on the same input, cache state and target. Repeat only enough to resolve the
  uncertainty; stress loops and parallel load require explicit task scope.
- If access or an artifact is missing, report what was tried and the precise
  missing evidence. Continue independent work; avoid speculative product fixes.
- Preserve real failure/cancellation statuses. Remove temporary instrumentation
  after the diagnosis and retain bounded evidence outside published source.

Completion requires the scoped regression and original journey to pass, or an
explicit unresolved acceptance/blocker. Source parsing, mocks and a successful
build cannot substitute for affected real-app behavior.
