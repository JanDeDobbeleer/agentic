---
name: context-authoring
description: Use when designing a new agent, skill, or multi-agent orchestrator, or when reviewing an existing one against established patterns. Covers which primitive fits a given need, how to name, scope, and contract each one, and the conventions that keep a growing set of them consistent. Trigger on requests like "design an agent for X", "review this skill", "should this be an agent or a skill", "how should these agents pass work to each other", or any request to add, extend, or audit agents, skills, or orchestrators.
---

# Context Authoring

Use this skill in two situations: someone wants to build a new agent, skill, or multi-agent orchestrator and needs help shaping it correctly, or someone has an existing one, or a proposed change to one, and wants it checked against established patterns.

## Before anything else

Every primitive here ends up as the same thing at runtime: Markdown text an agent reads into its context window. There's rarely one correct shape for a given piece of context, and more than one arrangement often works. The question worth asking before any rule below: **when should the agent read this?** Content needed on every task belongs somewhere always loaded; content needed only sometimes belongs somewhere loaded only then. Treat everything below as convention, not law: it records what's worked so far, not the one correct way to do it.

## Decision guide

| If the need is... | Use | Load |
|---|---|---|
| A new capability that does one bounded job and returns a defined output | An **agent**, including its tool scoping | `references/agent-design.md` |
| The exact procedure for one concrete, repeatable task, callable directly by name | A **skill**, task-execution shape | `references/skill-design.md` |
| Domain-specific guidance an agent should consult only when the task calls for it | A **skill**, domain-guidance shape | `references/skill-design.md` |
| Coordination across several agents in a multi-step workflow, or how work and state pass between them | An **orchestrating agent**, following the context-optimization rules | `references/context-optimization.md` |
| A rule two or more of the above already need | A shared reference, loaded by each one that needs it | whichever reference already owns the concern |

## How to apply this skill

**Reviewing something that exists.** Load the reference matching what's being reviewed, and check it against that reference's naming rule, contracts, and anti-patterns specifically. Cite the rule by name rather than saying a design "feels off." Where something deviates from a rule but still works, per "before anything else" above, name the trade-off rather than demanding a rewrite.

**Designing something new.** Start from the decision guide to pick the primitive and shape, then load the matching reference for the concrete rules: required frontmatter, naming convention, input and output contracts, and, for agents, tool scoping. Ask what the person is actually trying to build before assuming file-driven storage, a particular orchestrator, or any other detail the decision guide doesn't settle on its own.

## Authoring invariants

These apply no matter which primitive is being created or reviewed:

- **One primitive, one responsibility.** If describing what a file does takes a second sentence, split it.
- **Name things by what they produce, not by when they run.** A name built on the job survives a pipeline getting reordered; a name built on timing doesn't.
- **Never duplicate content across primitives.** If two primitives need the same rule, extract it once to a shared reference and have both load it.
- **The package must remain self-contained.** No primitive may reference a file outside the package; it needs to travel as a portable unit across whatever tools load or compile it.
