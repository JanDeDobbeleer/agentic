# Phase 3 — Delegate

Match the executor to the task, not the other way around. The point is cost and speed without
losing quality — the orchestrator stays accountable for the result.

## Executor matrix

Tier definitions and per-vendor model examples: [model-tiers.md](model-tiers.md).

| Task profile                                             | Executor                                         |
| -------------------------------------------------------- | ------------------------------------------------ |
| Trivial: mechanical edit, config tweak, typo, doc update | Do it directly, or batch on a trivial-tier model |
| Standard, well-specified implementation                  | Implementer-tier subagent                        |
| Ambiguous, architectural, or judgment-heavy              | Orchestrator keeps it                            |

- Launch independent tasks as parallel subagents, each in its own worktree.
- When the current agent is itself implementer-tier, there is no further delegation: execute
  directly, following the same spec discipline.

## What a delegation carries

Hand the subagent its full pinned spec from Phase 2, plus:

- The verification commands it must run and pass before reporting done.
- The instruction to report what it changed and what it verified — not just "done".
- The instruction to stop and report when it hits something the spec does not cover, instead of
  improvising scope.

## What is never outsourced

The orchestrator never delegates:

- Analysis and root-cause work (Phase 1).
- Final verification (Phase 5) — an implementer's green run is a claim, not a result.
- Commits, history rewrites, pushes, and user-facing reporting (Phase 6).
