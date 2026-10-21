# Development validation policy

[Execution policy](agents/execution-policy.md) is authoritative for platforms,
resources, native safety and delivery. [Delivery workflow](agent-workflow.md)
describes the implementation sequence; [coding standards](../CODING_STANDARDS.md)
define review evidence.

Select the smallest check that proves the requested behavior at its owning
runtime. Reproduce reported regressions before fixing them when feasible, then
exercise success and relevant failure, cancellation and identity cases. Add
meaningful regression coverage at that seam; there is no compulsory sequence of
verifier, critic and test author, or universal requirement for every test tier.

Native UI acceptance requires the affected real app and retained source/build
identity, logs and observed results. Host fixtures and source checks supplement
that evidence. Use [macOS validation](agents/macos-validation.md) for Apple
build/package/GUI work and the native reader instructions for reader changes.
Simulator execution remains quarantined; required SE1/iOS 15.5 acceptance stays
pending. Physical-device evidence cannot replace that specific target.

Android work remains paused until resumed by the user; Android/Samsung and
Flutter Linux work belongs on Arch. Document relevant client parity and platform
limits without starting an unrelated platform campaign. Python/Ruff execution
remains deferred to CI. Web tests start with at most two workers.

Documentation-only changes need focused content/link checks. Report the exact
checks performed, their limits and any pending acceptance. Follow atomic branch/
PR delivery and current automatic-merge safeguards; CI monitoring is opt-in.
