---
name: auto-prompt-execute
description: Turn a request or continuation into a Matt skill execution prompt, run it immediately, and manage a goal when explicitly authorized.
---

# Auto Prompt Execute

Use this skill when the user wants an objective turned into a strong execution prompt and carried out immediately. The prompt is an internal working artifact: write it, follow its selected skill workflow in the same session, and report the result. Do not stop after presenting a prompt.

## Procedure

1. Recover the user's objective, constraints, acceptance criteria, and authorization from the live conversation and workspace. Inspect applicable project instructions and preserve existing changes.
2. Consult the installed `ask-matt/SKILL.md` as the routing reference when this skill is explicitly invoked to automate Matt's flow. Its result is the selected route and next concrete action, not a recommendation to return to the user. Discover it through the skill catalog or the sibling global skill directory. Use the smallest route that fits the current phase; add domain skills only when needed. If the router is missing, report that and route with available skill descriptions. Load each selected skill before executing it. A named skill is not evidence that it is installed; replace missing optional skills with an available equivalent and disclose the substitution. If a required skill is missing and has no adequate equivalent, finish independent work and report the blocker.
3. Resolve routine details from repository instructions and evidence. Ask the user only when a missing decision changes scope, risk, authorization, compatibility, or acceptance. Continue independent work while waiting.
4. Write a concise executable prompt using the template below. Present it when the user requests a prompt; otherwise keep it as a working artifact. This skill's explicit invocation authorizes executing the resulting prompt within the user's stated task. Resume the active task for requests such as “continue” or “do everything”; use current evidence rather than selecting an unrelated backlog item. When the request is only to create or update this skill, that authoring task is the scope; an example product task remains an example.
5. Execute that prompt now. Load and follow the selected skills; do not merely describe or invoke them rhetorically. Keep the work within the user's authorized scope, and verify each stated acceptance criterion with direct evidence.
6. If a blocker prevents execution, complete independent authorized work and report the exact blocker and next action. Never report the prompt itself as completed work.
7. Inspect the final changes and report what changed, the checks actually run, their results, and remaining gaps.

## Routing notes

- A clear, small engineering task can go directly to implementation; do not add a grilling/spec phase just to use more skills.
- For user-created requests, do not route through triage.
- Skills guide execution but do not grant permission for external, destructive, irreversible, device, service, commit, push, publish, or merge actions. Respect project and session authorization.

## Goal lifecycle

Use a goal for sustained execution when the user explicitly requests one or says to use a goal if necessary. Skill invocation alone is not an explicit request to create a goal. Simple edits can execute directly.

When authorized and goal tools are available, inspect the current goal first. Reuse an unfinished goal covering this task; preserve an unrelated active goal and execute without replacing it. Otherwise create a goal with the prompt's observable objective. Set a token budget only when the user supplied one. If the tools are unavailable, continue the task and disclose that no tracked goal was created.

Keep working through implementation, verification, and final review. Follow the goal tool's exact status rules: complete only after all required acceptance is achieved; pause only on explicit request; use blocked only after the required consecutive-turn threshold. A failed device/service prerequisite does not end independent authorized work. Report the exact missing prerequisite without repeating unchanged probes. At completion report remaining limits and any budget usage returned by the tool.

## Execution prompt

```text
Objective: [observable result; preserve literal user identifiers]
Current evidence: [active request, workspace state, completed checks, remaining gap]
Skill route: [selected installed skills, in execution order, and their purpose]
Scope and authorization: [allowed actions, protected state, pending approvals]
Acceptance: [behavior and artifacts that establish completion]
Verification: [smallest applicable runtime checks and actual project tasks]
Goal: [reuse/create if explicitly authorized and useful; otherwise execute directly]
Delivery: [requested local/external actions and evidence report]
Execute this prompt now. Continue until acceptance is verified or independent
authorized work is exhausted. Distinguish completed work from blocked checks.
```
