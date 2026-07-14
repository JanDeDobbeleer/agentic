---
name: code-changes
description: >
  Orchestration workflow for any task that ends in code changes: issue analysis, pull request
  review, feature implementation, bug fixes, refactors, or fleshing out an idea. MUST be invoked
  at the start of such a task, before reading or writing any code. Defines how to analyze first,
  gate on user approval, plan, pick the right executor model, delegate and supervise subagents,
  verify, and deliver.
---

# Code Changes

The workflow for going from an issue, pull request, idea, or feature request to shipped code.
Follow the phases in order. Analysis always comes first; code comes last.

Each phase has a reference file with the full instructions. **Read the reference file when you
enter the phase** — not before, and never skip it because the phase "looks obvious".

## Roles

Assign work based on model capability:

| Role         | Capability tier                               | Owns                                      |
| ------------ | --------------------------------------------- | ----------------------------------------- |
| Orchestrator | Strongest reasoning model available           | Analysis, plan, supervision, verification |
| Implementer  | Mid-tier coder; small model for trivial edits | Executing one pinned, self-contained task |

Concrete model names per vendor (Anthropic, OpenAI, Google) and how to run the split in Claude
Code, GitHub Copilot, Codex, or IDE agents: [references/model-tiers.md](references/model-tiers.md).

When the current agent already runs on an implementer-tier model, skip delegation: plan and
execute directly, still following every phase. Never delegate to a model more capable than the
current one.

## The flow

1. **Analyze** ([references/analyze.md](references/analyze.md)) — root cause and scope,
   validated against the code, never against the report alone.
2. **Plan** ([references/plan.md](references/plan.md)) — pinned spec, task split, parallel vs
   sequential, workspace per task.
3. **Delegate** ([references/delegate.md](references/delegate.md)) — match each task to the
   cheapest capable executor.
4. **Supervise** ([references/supervise.md](references/supervise.md)) — monitor, unblock, and
   critically review implementer output.
5. **Verify** ([references/verify.md](references/verify.md)) — quality gates plus functional
   proof, never delegated.
6. **Deliver** ([references/deliver.md](references/deliver.md)) — conventional commits and an
   outcome-first report.

**Stop gate:** Phase 1 ends with reporting the analysis and proposed approach to the user and
waiting for a go. Skip the gate only when the user already gave the go in the request itself
("do it", "fix it and commit", "implement with Sonnet").

## Special cases

These entry points replace or extend Phase 1; the rest of the flow applies unchanged.

- Pull request review comments →
  [references/pr-review-comments.md](references/pr-review-comments.md)
- Issue triage → [references/issue-triage.md](references/issue-triage.md)
