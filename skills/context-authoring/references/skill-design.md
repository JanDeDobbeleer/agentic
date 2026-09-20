# Skill Design

## What a skill is

A skill is a guide an agent loads to know how to handle a category of work. It isn't an agent: it has no bounded input or output contract of its own, and nothing invokes it directly the way an agent gets invoked. An agent loads a skill to get either the exact procedure for one concrete task, or the domain knowledge it needs to make a judgment call on a broader class of problem.

**A skill loaded into context tells the current agent: here is how to approach this class of problem.**

In current tooling, a skill can also serve as its own invocable entry point: its frontmatter exposes it directly as a slash command, consistently across the tooling landscape. There's no separate pointer file needed to bridge a user-facing command to the guidance it triggers; the skill is both.

## Two skill shapes

Skills come in two shapes. Which one fits depends on whether a single use of the skill needs most of its content, or only a slice of it.

### Task-execution skills

For a well-scoped, repeatable task, such as creating a Word document, filling a PDF form, or building a slide deck, `SKILL.md` can be the complete procedure: how to structure the output, which calls or scripts to run, what conventions the result should follow. There's no "load more only if needed" step here, because carrying out the task at all requires most of the file anyway. The folder can hold supporting scripts, templates, or example assets that `SKILL.md` tells the agent to use directly.

```
skills/pptx-authoring/
  SKILL.md          the full procedure: slide structure, library calls, output conventions
  scripts/
    build_deck.py   the script SKILL.md tells the agent to run
  assets/
    template.pptx   starting template SKILL.md references
```

This is the shape behind task-execution skills like a docx, pptx, pdf, or xlsx authoring skill: one `SKILL.md` per file format, each holding the whole procedure, each with its own scripts and assets sitting alongside it. Here `SKILL.md` is a document, not a table of contents, and that's the correct shape for it. Splitting a single, always-needed procedure into fragments just to satisfy a "keep it thin" rule adds indirection without saving any context, since the agent has to load every fragment anyway.

### Domain-guidance skills

For a broad area of knowledge, such as spec authoring or governance review, any single task usually touches only one slice of it. Loading the whole domain on every task wastes context. Here `SKILL.md` should describe when to use the skill and which reference file covers which concern, and defer the actual guidance to `references/`, loaded only when the current task calls for it. The rest of this reference covers this shape in detail; the same headings apply.

## Choosing a shape

| If… | Use |
|---|---|
| The skill covers one concrete, repeatable task, and doing it at all requires most of the guidance | **Task-execution shape**: `SKILL.md` holds the full procedure, with scripts or assets alongside it in the folder |
| The skill covers a broad domain where any single task only touches a slice of it | **Domain-guidance shape**: `SKILL.md` is a table of contents; guidance lives in `references/`, loaded on demand |
| Unsure which fits | Lean domain-guidance if the content is likely to grow past roughly 100 lines or serves more than one kind of task. Lean task-execution otherwise: it's simpler and avoids indirection the skill doesn't need. |

## SKILL.md is a table of contents, not a document (domain-guidance shape)

For a domain-guidance skill, the `SKILL.md` file must answer three questions:

1. When should this skill be used?
2. What inputs does it require?
3. Which reference file should be loaded for each specific concern?

It must not contain the guidance itself. Guidance lives in `references/`.

**Correct shape:**

```markdown
## Source material

Load the specific reference for each concern:

- Artifact sequence and required fields → LOAD `references/spec-workflow.md`
- When to ask questions and escalation triggers → LOAD `references/clarification-policy.md`
```

**Incorrect shape:**

```markdown
## Spec authoring guide

A specification must include: goal, context, scope, actors...
[200 lines of guidance follows]
```

The incorrect shape loads every line of guidance into context even when only one section is relevant. The correct shape loads only what the current task actually needs. (This is what distinguishes the shape from a task-execution skill: there, loading the whole file is expected and correct, because one task normally needs most of it anyway.)

## Reference files are single-concern

Each file in `references/` covers exactly one concern. If a reference file grows past two `##` sections covering different topics, split it.

**Good reference names:**

```
references/spec-workflow.md: artifact sequence and required fields
references/clarification-policy.md: when to ask, escalation triggers
references/plan-structure.md: what plan.md must contain
references/command-selection.md: how to pick the right command
```

**Bad reference names (too broad):**

```
references/spec-authoring-guide.md: workflow, fields, policy, and examples all mixed together
references/governance-guide.md: security, UI, ADR, and checklist all mixed together
```

## Progressive disclosure

The skill defines what's available to load. The agent loads only what it needs for the task in front of it: this is progressive disclosure.

A spec author working on `spec.md` loads `references/spec-workflow.md`. It doesn't also load `references/clarification-policy.md` unless it hits an ambiguous decision point. A governance reviewer checking security loads `references/security-review-guidance.md`. It doesn't also load `references/ui-guidance.md` unless a UI surface is actually in scope.

The rule: **load the minimum reference that answers the current question.**

## Example: the governance-guide.md split

Take `governance-guide.md` as a single 200-line file covering three unrelated concerns: security review defaults, UI compliance rules, and statistics recording format. Every governance review would load all 200 lines, regardless of whether the feature had a UI surface or needed a statistics update.

Splitting it fixes that:

```
references/security-review-guidance.md: 30 lines, security only
references/ui-guidance.md: 40 lines, UI only
references/statistics-recording.md: 25 lines, stats recording only
```

`SKILL.md` then reads:

```markdown
- Security surface → LOAD `references/security-review-guidance.md`
- UI alignment → LOAD `references/ui-guidance.md`
- Changeset statistics → LOAD `references/statistics-recording.md`
```

A feature with no UI surface loads just 30 lines instead of 200. A feature that touches all three concerns still loads only the three relevant files: 95 lines total, instead of one undifferentiated 200-line block.

## Skill folder layout

```
skills/<skill-name>/
  SKILL.md      task-execution shape: holds the full procedure
                domain-guidance shape: a table of contents
  references/   domain-guidance only: single-concern files loaded on demand
  scripts/      task-execution only: code SKILL.md tells the agent to run
  assets/
    templates/  file templates or starting assets SKILL.md references
```

A skill doesn't need every folder shown here: a task-execution skill typically has no `references/`, and a domain-guidance skill typically has no `scripts/`. Reserve `assets/` for reusable templates and static resources; never put guidance there, in either shape.

## Naming rule

Name skill folders for the category of work, not for the agent or phase they support:

| Correct | Incorrect |
|---|---|
| `spec-authoring` | `spec-author-resources` |
| `governance-review` | `post-implementation` |
| `feature-pipeline` | `workflow-orchestration-skill` |

## Anti-patterns

- **Content in SKILL.md, for a domain-guidance skill**: any guidance beyond load instructions and a short workflow summary belongs in a reference file. This doesn't apply to a task-execution skill, where the full procedure belongs in `SKILL.md` by design.
- **Needless splitting, for a task-execution skill**: breaking a single always-needed procedure into several reference files "just in case." If one task normally needs the whole thing, keep it in one `SKILL.md`; the split only adds indirection.
- **Multi-concern reference files**: one file covering security, UI, and stats is three files pretending to be one.
- **Loading all references upfront**: a domain-guidance skill that says "load all references before proceeding" defeats progressive disclosure entirely.
- **Duplicating agent content**: if a skill reference restates what the agent already knows from its own frontmatter, delete the duplication.
