---
name: handoff
description: Export explicitly requested portable context for another harness, directory or colleague.
argument-hint: "What will the next session be used for?"
disable-model-invocation: true
---

Use this skill when the user explicitly requests a portable handoff document.
For ordinary same-project session continuity, use `ai-memory-handoff`.
Save the requested export to the operating system's temporary directory.

Include a "suggested skills" section in the document, which suggests skills that the agent should invoke.

Do not duplicate content already captured in other artifacts (specs, plans, ADRs, issues, commits, diffs). Reference them by path or URL instead.

Redact any sensitive information, such as API keys, passwords, or personally identifiable information.

If the user passed arguments, treat them as a description of what the next session will focus on and tailor the doc accordingly.
