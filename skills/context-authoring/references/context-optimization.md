# Context Optimization

The examples in this reference use a file-driven workspace (`spec.md`, `clarifications.md`, and so on) because that's this package's own convention. That convention is itself a design decision, made once by whoever designs the orchestrator, not a rule that orchestrators or agents must follow in general (see the Input contract section in `references/agent-design.md`). A system that keeps the same state some other way still follows the principles below: hold little, pass a reference instead of content, and return a structured verdict, just with a different kind of reference.

## The problem

A spec workspace at the end of a feature delivery can hold `spec.md`, `clarifications.md`, `plan.md`, `command-map.md`, `tasks.md`, `security.md`, `ui-contract.md`, `adr.md`, `review-checklist.md`, and `legacy-impact.md`. Loading all of it into one context window to run a governance review is expensive and unfocused: the governance reviewer doesn't need `spec.md` to check statistics, and the security reviewer doesn't need `ui-contract.md` to assess the security surface.

Context optimization is the practice of **giving each agent only what it needs to do its specific job.**

## The thin orchestrator pattern

An orchestrator managing a multi-agent workflow should hold as little as possible.

**What the orchestrator holds:**
- The feature ID.
- The workspace path template: `specs/<feature_id>/`.
- The workflow state: which phase has completed.
- Structured verdict objects returned by sub-agents.

**What the orchestrator never holds:**
- File contents from the workspace.
- Skill references loaded for context.
- Intermediate prose or notes from sub-agents.

The orchestrator routes forward or stops based on verdict values. It never interprets content itself.

## Pass references, not content

When dispatching a sub-agent, pass the reference to what it needs (a file path, in this package's case), not the content itself.

**Correct dispatch:**

```
Dispatch spec-reviewer with:
  spec.md path:           specs/002-auth-service/spec.md
  clarifications.md path: specs/002-auth-service/clarifications.md
```

**Incorrect dispatch:**

```
Dispatch spec-reviewer with:
  spec content: "# Goal\nThis feature implements..."
  [200 lines of spec.md inlined here]
```

The agent loads the file itself, and loads only what it needs. The orchestrator's context window stays clean of content it can't act on.

## Structured verdicts keep orchestrator context small

Sub-agents return structured verdicts, not prose summaries. The orchestrator reads the verdict fields and routes: it does not parse prose.

```
verdict:  READY | NEEDS-REWORK | BLOCKED | COMPLETE
blockers: [ "Acceptance criteria for user story 3 are not testable." ]
gaps:     [ "Non-functional requirements missing for performance." ]
notes:    "Spec is mostly solid; two blockers must resolve before planning."
```

The orchestrator reads `verdict`, and if it isn't `READY`, surfaces `blockers[]` to the user verbatim. It never reads `notes`. The full review detail stays inside the sub-agent's own context; it never enters the orchestrator's.

## Own context windows for specialists

Each specialist agent dispatched in a multi-agent flow runs in its own context window. This buys two things:

1. **Focused loading**: the security reviewer loads only security guidance; the spec reviewer loads only spec-authoring guidance. Neither knows the other's references exist.
2. **Independent findings**: specialists can't influence each other. The security reviewer can't be swayed by the spec reviewer's confidence in the spec.

This matters most for concurrent dispatch. Take a review phase where `spec-reviewer` (implementation alignment) and `security-reviewer` run simultaneously: sharing a context here would let one agent's findings bias the other.

## Gate conditions replace content checks

An orchestrator should never read a file to decide whether to proceed. Use gate conditions built on verdicts and file-existence checks instead.

| Instead of this | Use this |
|---|---|
| Read `spec.md` and decide if it's complete | Run `spec-reviewer`; check verdict = `READY` |
| Check if `plan.md` looks detailed enough | Check that `plan.md` and `tasks.md` exist in the workspace |
| Read `security.md` and assess risk level | Run `security-reviewer`; check verdict != `BLOCKED` |

File-existence checks are fast and cost no context. Verdict checks delegate the judgment to the specialist who's actually qualified to make it.

## The pipeline skill's orchestrator contract

The `feature-pipeline` skill states these rules explicitly, as a contract the orchestrator must follow:

```
The orchestrator MUST NOT:
- Load the spec-authoring, delivery-planning, or
  governance-review skills.
- Read spec.md, plan.md, tasks.md, security.md, or any workspace file.
- Make content-level judgments about the feature.
- Interpret or paraphrase blockers: surface them as returned.
```

Before this pattern was formalized, the orchestrator's own invocation logic carried inline workflow instructions that described reading spec content and making routing decisions from it. That loaded irrelevant context into the orchestrating agent, and produced inconsistent routing: different agents drew different conclusions from the same prose.

The pipeline skill replaces that with explicit verdict-based routing and a strict dispatch contract. The orchestrator's context window holds only the feature ID, the workspace path, and the verdicts. All reasoning about content happens inside the sub-agents, where it belongs.

## Anti-patterns

- **Content-reading orchestrator**: an orchestrator that reads `spec.md` to judge whether the spec is good. Delegate to `spec-reviewer` and trust the verdict.
- **Prose verdicts**: "the spec looks mostly good but I noticed a few issues." The orchestrator can't route on this. Return a structured verdict instead.
- **Front-loaded context**: an orchestrating agent that loads every skill and reference file at session start "just in case." Load only the pipeline skill; let sub-agents load what they need.
- **Inline content in dispatch**: passing file contents in the sub-agent dispatch message. Pass paths; let the agent load what it needs.
- **Single-context multi-agent illusion**: running several "agents" as sequential steps in one shared context window while calling it multi-agent. If they share a context, they're one agent playing roles, not independent specialists. Dispatch into genuinely separate context windows.
