# Agent Design

## What an agent is

An agent describes a single specialist role with a clearly bounded input set and a predictable output set. It does one job. If an agent does two things that could be useful independently, split it into two agents.

**Naming rule:** name the agent for what it produces or decides, not for when it runs.

| Correct | Incorrect |
|---|---|
| `spec-author` | `pre-planning-agent` |
| `spec-reviewer` | `spec-checker-and-planner` |
| `governance-reviewer` | `post-implementation-agent` |

## Required frontmatter

```yaml
---
name: <role>
description: One sentence: what the agent does, when to invoke it.
---
```

The `description` field is what shows up in agent pickers, and what an orchestrator reads to select the right agent. Be specific about both halves: the trigger condition ("invoke after spec and clarifications are complete") and the output type ("returns a structured gap report").

## Input contract

State exactly what the agent expects. Name each input rather than inlining its content, so the contract stays short:

```markdown
## What you expect

- `specs/<feature>/spec.md`: the primary artifact to review.
- `specs/<feature>/clarifications.md`: open questions and decisions.
```

Whether that reference resolves to a file path, inline text, or a structured object passed straight in is not this contract's concern, and it isn't the agent's decision to make. That choice belongs to whoever invokes the agent, typically the orchestrating agent, as part of its own design (see `references/context-optimization.md`). Naming what's needed is the agent's job; working with whatever form it arrives in is also the agent's job. Deciding the form itself is not.

Never tell an agent to "read the context" or "look at the workspace generally." Every agent declares its inputs explicitly.

## Output contract

State exactly what the agent produces. Authoring agents name every artifact they produce. Review agents structure their output into named sections.

**Authoring agents name their output:**

```markdown
## What you produce

**`spec.md`** containing:
- Goal, context, scope, actors, user stories, acceptance criteria, non-functional requirements.
```

Whether that artifact ends up written to a file, stored as a record, or returned inline is, again, not something the agent's contract decides. That call is made once, for the whole system, by whoever's orchestrating it; an individual agent's design shouldn't need to know or care which way it went.

**Review agents return structured verdicts:**

```markdown
## What you return

A gap report with three sections: Blockers, Gaps, Confirmations.
Finish with a one-line readiness verdict: "Ready to plan", "Ready to plan with caveats", or "Not ready: blockers must be resolved".
```

## Rules section

Every agent ends with a `## Rules` section stating what it must and must not do. Write rules negative-first (MUST NOT). That's what makes a constraint unambiguous at the boundary:

```markdown
## Rules

- Do not invent technical decisions. Flag the gap; do not fill it.
- Do not rewrite any artifact. Cite the source and section when flagging an issue.
```

## Scoping tool access

Beyond `name` and `description`, most agent-hosting tools let an agent's frontmatter declare which tools it's allowed to use. Left unset, an agent typically gets every tool available in the environment, including ones it never needs. Declaring the list explicitly, even when "all tools" would technically work, turns an implicit assumption into an auditable line in the file: anyone reading the frontmatter can see exactly what this agent can touch, without reading its full prompt.

This matters most for the highest-risk tool categories: anything that executes shell commands, reaches the network, or writes to files the agent doesn't need to touch. A spec-reviewing agent has no legitimate reason to run shell commands. Restricting its tools to read-only access means a prompt injection, or a bad instruction sitting inside the spec it's reviewing, can't be turned into an arbitrary command, because the tool to run one was never granted in the first place. Scoping tools is a harness-level control, not a behavioral one: it holds even if the agent's own instructions are compromised or ignored.

### Deriving the minimal set

Don't start from the list of available tools and decide what to remove. Start from the contracts already defined above, and grant only what they require:

1. **Read the input contract.** Every input the agent reads maps to a read-only capability (`read`, `search`). Nothing else follows from inputs alone.
2. **Read the output contract.** An authoring agent that produces files needs `edit`. A review agent that only returns a verdict needs neither `edit` nor `execute`, no matter how tempting it is to leave the door open "in case."
3. **Read the Rules section.** A negative rule such as "Do not rewrite any artifact" should show up twice: once as a written constraint, and once as a tool absent from the list. If a rule forbids something the tool list still permits, the rule is doing work the frontmatter should be doing instead.
4. **Only then consider execution, network, and MCP access, and only if a step above actually required it.** An agent that never needed to run a command or reach a URL to do its job shouldn't have `execute` or `web` just because the environment happens to offer them.
5. **For MCP servers, scope to the tool, not the server.** Prefer `some-server/some-tool` over `some-server/*`, unless the job genuinely spans everything that server offers.

Done this way, the tool list is checkable, not guessed: someone reading an agent's input contract, output contract, and rules should be able to predict its `tools` list before seeing it. If they can't, either the contracts are incomplete or the tool list is wider than the job requires.

### Expressing it in frontmatter

**GitHub Copilot's custom agent frontmatter** is one concrete implementation of this pattern, and its fields carry the same idea across to most other agent-hosting tools, even where the exact field names differ:

| Field | What it does |
|---|---|
| `tools` | An allow-list of tool names or aliases the agent can use. Omit it, or set `tools: ["*"]`, to allow everything. Set `tools: []` to disable every tool. Anything else is a specific list, for example `tools: ["read", "edit", "search"]`. |
| `mcp-servers` | Scopes which MCP servers, and which of their tools, are available to this one agent, on top of whatever's already configured at the repository level. |

Copilot groups its built-in tools into a small set of aliases, which map onto categories worth reasoning about when scoping any agent, regardless of platform:

| Alias | Covers | Risk if left ungated |
|---|---|---|
| `read` | Reading file contents | Low: mostly read-only |
| `search` | Searching files and text | Low: mostly read-only |
| `edit` | Writing or modifying files | Medium: can change what's in the repository |
| `execute` | Running shell commands | High: arbitrary code execution |
| `web` | Fetching URLs, web search | High: network egress, potential data exfiltration |
| `agent` | Invoking another custom agent | Medium: expands the blast radius to whatever that agent can do |
| `todo` | Managing structured task lists | Low: no side effects outside the session |

A tool from a specific MCP server can be scoped even tighter: `some-server/some-tool` allows just that one tool, and `some-server/*` allows every tool that server offers, without opening up every other MCP server the repository has configured.

**Applying the method to the naming examples above:** `spec-author`'s output contract says it produces `spec.md`, so it needs `edit`. Its input contract only names files to read, so it needs `read` and `search` too. Nothing in its contract or rules calls for `execute`, `web`, or `agent`, so those stay off the list: `tools: ["read", "edit", "search"]`. `governance-reviewer`'s output contract is a returned verdict, not a file, so `edit` drops out entirely: `tools: ["read", "search"]`. Neither list was guessed; both follow directly from the contracts already on the page.

## Example: splitting a review agent by concern

Take a single agent that handles security review, UI review, ADR checking, checklist completion, and statistics recording. That's five independent concerns bundled into one file, which breaks the one-job rule above. Splitting it into `security-reviewer` (security surface only, returns a structured findings report) and `governance-reviewer` (everything else, loading each concern's guidance on demand) fixes that.

The split matters beyond tidiness: an orchestrator can now dispatch `security-reviewer` on its own, in a concurrent review phase, without also triggering UI or statistics work. Each agent gets only the context its job requires.

## Anti-patterns

- **God agent**: one file with eight numbered steps covering four unrelated concerns. Split it.
- **Vague output**: "summarise the findings." Name the sections and the verdict format explicitly.
- **Missing rules**: an agent with no `## Rules` section will improvise at its boundaries. Add the constraints.
- **Input by implication**: "review the feature," with no input named. Always declare the input contract.
- **Unscoped tools**: leaving `tools` unset because it's easier grants everything by default, including execution and network access an agent may never need. State the list explicitly, even when it ends up covering most of what's available, so the grant is visible rather than assumed.
