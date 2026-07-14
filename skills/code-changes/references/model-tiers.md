# Model tiers and agent tooling

The workflow talks about capability tiers, not vendor names. Map whatever stack is in use onto
these three tiers. The model names below are a mid-2026 snapshot — they go stale; when a name no
longer exists, map its replacement by tier, not by nostalgia.

## The three tiers

| Tier         | Role                | Anthropic         | OpenAI            | Google            |
| ------------ | ------------------- | ----------------- | ----------------- | ----------------- |
| Orchestrator | Analysis, oversight | Fable 5, Opus 4.8 | Sol, GPT-5 (high) | Gemini 2.5 Pro    |
| Implementer  | Pinned-spec work    | Sonnet 5          | GPT-5, GPT-4.1    | Gemini 2.5 Flash  |
| Trivial      | Mechanical edits    | Haiku 4.5         | GPT-4.1 mini      | Gemini Flash-Lite |

- **Orchestrator** — the strongest reasoning model available. Pays for itself on root-cause
  analysis, architectural judgment, reviewing implementer diffs, and catching wrong-but-plausible
  fixes. Everything the workflow forbids delegating runs here.
- **Implementer** — the capable code monkey: fast, cheap, and reliable when handed a pinned spec
  with decisions already made. Falls over when asked to make judgment calls, which is exactly why
  the spec removes them.
- **Trivial** — small, very fast models for mechanical, unambiguous edits: renames, config
  tweaks, typo fixes, doc touch-ups. Batch several to amortize the dispatch overhead. When in
  doubt between trivial and implementer, pick implementer — a wrong cheap edit costs more than
  the price difference.

## Tooling mappings

How to run the orchestrator/implementer split in common agent tooling:

- **Claude Code** — the orchestrator session delegates via subagents (`Agent` tool) with a model
  override per task (`sonnet`, `haiku`), using worktree isolation for parallel tasks.
- **GitHub Copilot** — do analysis in Copilot Chat on the strongest reasoning model in the model
  picker; switch agent mode to a cheaper model for executing the pinned spec. Standalone,
  well-specified tasks can be assigned to the Copilot coding agent (assign the issue or PR to
  Copilot), which works on its own branch — the pinned spec becomes the issue body.
- **Codex** — orchestrate locally (CLI or chat) on the frontier model; dispatch each pinned spec
  as a Codex cloud task, one task per independent unit, and review the resulting diffs as PRs.
- **Cursor and similar IDE agents** — one composer/agent session per task with the model chosen
  per tier; background agents for the parallel ones.

**No subagent support at all?** Keep the phases, drop the parallelism: run analysis on the
strongest model, then switch the session model down for implementation, then switch back up to
review and verify. The discipline transfers even when the delegation mechanism does not.
