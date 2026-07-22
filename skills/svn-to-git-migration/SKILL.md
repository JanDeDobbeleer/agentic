---
name: svn-to-git-migration
description: >
  Migrate a Subversion (SVN) repository to a standalone Git repository by running the
  migration directly using inline PowerShell (on Windows) or bash (on macOS/Linux).
  The agent executes all commands itself — detection, each migration phase, and
  verification — using the powershell tool with inline code (never pointing to a .ps1
  file, which is blocked by Group Policy). Use this skill whenever the user mentions
  SVN migration, converting SVN to Git, "we're moving away from SVN", "git svn is
  missing", "git-svn not found on Windows", or wants to import SVN history into a Git
  repo. Also use when someone asks how to preserve SVN history in Git, convert
  branches/tags from SVN, or set up a Git mirror of an SVN repo.
---

# SVN → Git Migration

> **Agent instructions — read this before every action:**
>
> You ORCHESTRATE the migration. Every phase runs as a background subagent via the `task` tool — you never run `powershell` phase snippets yourself. Your context is for orchestration only.
>
> **Windows execution model (critical — applies inside every subagent):**
> - `powershell -File script.ps1` → **ALWAYS BLOCKED** by Group Policy. Never use this.
> - `powershell -Command "..."` → **Never blocked**. Always use this.
> - Inline technique: read `lib/core.pslib` as text, wrap in `[scriptblock]::Create()`, dot-source it — no `-File`, no ExecutionPolicy issue.
>
> **For every Windows phase:** Tell a `task` subagent the runbook path (e.g. `phases/phase-0.md`) and the placeholder values. The subagent reads the file, fills in values, and executes the snippet. **The orchestrator never opens a runbook file.**
>
> **macOS / Linux:** Use `bash scripts/migrate.sh run <url> ...` — no policy constraint. Run it via the bash tool (or delegate to a subagent).
>
> **State between phases:** Each phase saves its output to `$target\.svn2git\*.json`. The next phase reads it. This is how cross-phase state (sha-index, refs, config) survives across separate `powershell -Command` invocations.

`git-svn` is no longer bundled with Git for Windows (and macOS Homebrew dropped it
too). This skill recreates the full `git svn clone` behaviour using only the `svn` CLI
and standard git plumbing commands (`hash-object`, `write-tree`, `commit-tree`,
`update-ref`, `update-index`). No Perl, no native extensions required.

**Platform support:**
- **Windows** — agent runs each phase inline via `powershell -Command`; state persisted as JSON between phases
- **macOS / Linux** — agent runs `migrate.sh run` directly via bash

> ⚠️ **macOS users:** The system bash is version 3.2 and will not work. Install bash ≥ 4
> first: `brew install bash`. The script checks at startup and aborts with instructions
> if the version is too old.

---

## Prerequisites

Verify these before starting:

```sh
svn --version          # any modern version (TortoiseSVN, SlikSVN, Homebrew, distro pkg)
git --version          # 2.x or later
python3 --version      # 3.x — used for XML parsing in the bash script
```

**macOS only:**
```sh
bash --version         # must be 4.0 or later
# If not: brew install bash
```

**Files (relative to the skill directory):**
- macOS / Linux: `scripts/migrate.sh`
- Windows: `lib/core.pslib` — function library loaded inline by the phase runbooks (never run directly)

---

## Step 1 — Detect

> **Agent:** Delegate detect to a `task` subagent — pass the skill directory path and the current working directory. The subagent reads `phases/detect.md`, runs the detection commands, and returns the structured result: SVN URL, layout, authors, head revision.
>
> Once the subagent returns, **immediately present the interview questions from Step 2 to the user in a single message** — do not wait for a follow-up prompt. Include in that message:
> - A summary of what detect found (URL, layout, author count, head revision)
> - All interview questions that are not already answered by the detect output
> - A pre-filled suggestion for each question where detect gave enough information
>
> Only ask the user for the URL if the subagent reports it could not be auto-detected.

---

## Step 2 — Interview: migration options

Work through these decisions **in order** based on what the `svn info` / `svn log` output showed.

### a. Repository layout

What layout does your SVN repository use?

| Layout | Description | Flag to use |
|--------|-------------|-------------|
| **Standard** | Has `trunk/`, `branches/`, `tags/` at the top level | `--stdlayout` |
| **Custom paths** | Different names (e.g. `main/`, `rb/`, `rel/`) | `-T <trunk> -b <branches> -t <tags>` |
| **Single path** | No branches or tags — just one linear history | _(no flag)_ |

The `detect` output will suggest the likely layout. You can always override it.

### b. Author mapping

Do you want real names and email addresses in git commits?

SVN commits store only a username (e.g. `jsmith`). Without a mapping, each commit
author defaults to `jsmith@<repo-uuid>` — fine for private repositories, but not ideal
for public ones.

To provide a mapping, create an `authors.txt` file (see `assets/authors.template.txt`):
```
jsmith = Jane Smith <jane.smith@example.com>
bwilliams = Bob Williams <bob@example.com>
(no author) = Unknown Committer <unknown@example.com>
```

The `detect` output lists every SVN author that appears in the log — use that list to
build your file. Ask me to generate a stub `authors.txt` from that list if you'd like.

> ⚠️ **If the detect output shows `AUTHOR_SCAN_COMPLETE: false`**, the full log scan timed out. Some older committers may be missing from the list. You can get the complete set by running locally:
> ```powershell
> svn log --xml -q <svn-url> | Select-String '<author>' | ForEach-Object { ($_ -replace '.*<author>(.*)</author>.*','$1').Trim() } | Sort-Object -Unique
> ```
> Any SVN username not in `authors.txt` will default to `username@<repo-uuid>` and will be listed as "Unmapped SVN authors" in the Phase 8 summary.

Pass the file with: `--authors-file authors.txt`

### c. Metadata trailer

Keep `git-svn-id` in each commit message?

Each commit will end with a line like:
```
git-svn-id: https://svn.example.com/repos/myproject/trunk@42 a1b2c3d4-e5f6-...
```

- **Default (recommended):** keep it — preserves SVN revision traceability. You can
  always strip it later with `git filter-repo`.
- **To omit:** add `--no-metadata`

### d. Path filtering

Are there directories you want to exclude — generated code, large binaries, IDE files?

Use `--ignore-paths <regex>` with a regex matched against **ref-root-relative** paths.

Example — exclude a generated directory and all `.class` files:
```
--ignore-paths "(^generated/|\.class$)"
```

> ⚠️ **Migrating from git-svn?** `git-svn` matched `--ignore-paths` against
> **repo-root-relative** paths (e.g. `/trunk/generated/`). This skill matches against
> **ref-root-relative** paths (e.g. `generated/`). Adjust your patterns accordingly.
> See `references/git-svn-mapping.md` for the full mapping.

Use `--include-paths <regex>` to do the inverse (whitelist).

### e. Tag handling

Clean tags (directories that were never modified after the SVN copy) automatically
become annotated git tags. Dirty tags (modified after creation) automatically become
branches named `tags/<tagname>`, with a warning printed in the summary.

Override with `--tags-as-branches` to turn **all** SVN tags into branches regardless
of cleanliness.

### f. Default branch name

What should the trunk become in git?

| Choice | Flag |
|--------|------|
| `main` (default) | _(omit flag)_ |
| `master` | `--default-branch master` |
| `trunk` | `--default-branch trunk` |

### g. svn:ignore → .gitignore conversion

The skill reads `svn:ignore` properties from the SVN repository and writes `.gitignore` files into the git repository, then creates a final commit on each ref. Recommended: keep the default (enabled).

**Variable to set in Phase 0:** `$noCreateIgnore`
| User wants | Set `$noCreateIgnore` to |
|-----------|--------------------------|
| Create `.gitignore` files (default) | `$false` |
| Skip `.gitignore` creation | `$true` |

> ⚠️ The variable is **negated** — `$false` = enabled, `$true` = disabled. Do not confuse with a `$createIgnore` flag.

### h. Target directory

Where should the git repository be created?

Default: `./repo-name` (derived from the SVN URL). Override with `--target <path>`.

### i. Revision range

Migrate all revisions (default), or a specific range?

- All revisions: _(omit flag)_ — equivalent to `--revision 1:HEAD`
- Specific range: `--revision N:M`
- Single revision: `--revision N`

For very large repositories (> 5 000 revisions), consider migrating in chunks and
re-running with a later range. See `references/troubleshooting.md` for guidance.

---

## Step 3 — Run the phases

> **Agent:** For each phase, launch a `task` subagent with the runbook path and placeholder values — **do not open the runbook file yourself**. The subagent reads it, fills in placeholders, and runs the snippet.

Windows runs the migration as **individual phases** — this works regardless of ExecutionPolicy, gives visibility into progress, and allows resuming if interrupted. macOS/Linux uses a single `run` command (no ExecutionPolicy constraint there).

---

### macOS / Linux

One command does everything:

```bash
bash scripts/migrate.sh run https://svn.example.com/repos/myproject \
  --stdlayout \
  --authors-file authors.txt \
  --default-branch main \
  --target ./myproject-git
```

> Tell me your answers to the interview questions and I'll produce the exact command.

---

### Windows — Phase-by-phase (always use this)

For each phase, launch a `task` subagent with the runbook path and the three placeholder values. Phases 1–8 all use the **same runbook** (`phases/run-phase.md`) — only `$phase` changes.

| Phase | Runbook file | Name | What it does |
|-------|-------------|------|--------------|
| — | [`phases/detect.md`](phases/detect.md) | Detect | Gather SVN repo info before the interview |
| 0 | [`phases/phase-0.md`](phases/phase-0.md) | Preflight + config | SVN reachability, writes `config.json`, copies `lib/core.pslib` to state dir |
| 1 ⟳ | [`phases/run-phase.md`](phases/run-phase.md) — `$phase='1'` | Git init | Creates the git repository — **parallel with 2 & 3** |
| 2 ⟳ | [`phases/run-phase.md`](phases/run-phase.md) — `$phase='2'` | Author map | Validates the authors file — **parallel with 1 & 3** |
| 3 ⟳ | [`phases/run-phase.md`](phases/run-phase.md) — `$phase='3'` | Resolve refs | Enumerates SVN branches/tags, writes `refs.json` — **parallel with 1 & 2** |
| 4 | [`phases/run-phase.md`](phases/run-phase.md) — `$phase='4'` | Convert trunk | Replays trunk revisions as git commits _(long-running)_ |
| 5 | [`phases/run-phase.md`](phases/run-phase.md) — `$phase='5'` | Convert branches | Replays branch revisions _(may be long)_ |
| 6 | [`phases/run-phase.md`](phases/run-phase.md) — `$phase='6'` | Convert tags | Creates annotated git tags or dirty-tag branches |
| 7 | [`phases/run-phase.md`](phases/run-phase.md) — `$phase='7'` | Post-processing | `svn:ignore` → `.gitignore`, set HEAD, run `git gc` |
| 8 | [`phases/run-phase.md`](phases/run-phase.md) — `$phase='8'` | Summary | Prints the migration report |

⟳ = phases 1, 2, 3 can run in parallel — launch all three simultaneously, wait for all three before Phase 4.

If a phase fails, fix the problem and re-run that phase — earlier phases don't need to be repeated. The SHA index and state are preserved in `$target\.svn2git\`.


---

## Step 4 — Execute

> **Agent — orchestration model (critical):**
>
> **Every phase runs as a background subagent** via the `task` tool (`agent_type: "task"`, `mode: "background"`). You are the orchestrator — you read runbooks, fill in placeholders, launch subagents, read results, and report progress to the user. You never run `powershell` tool calls yourself for phase execution.
>
> **Why:** Keeps your context small. Phase output (potentially hundreds of lines of SVN progress) goes into subagent context, not yours. You only see the summary returned by the subagent.
>
> **Phases 4, 5, 6 — detached mode + polling (mandatory):** These phases can run for hours.
> A subagent call that stays open that long dies when its session token expires (`403` /
> "token expired or invalid") — a long-lived request can't be refreshed from the inside.
> Detached processes don't have this problem: they survive independently of the tool call,
> the subagent, and even the orchestrator's own session. So for phases 4–6, launch via the
> **detached mode** launcher in `phases/run-phase.md` (a short subagent call that starts a
> background process and returns immediately), then poll `progress.json` /
> `phase-<N>.status.json` every 2–5 minutes with short subagent calls — never hold one call
> open waiting for the phase to finish. If corporate policy blocks spawning detached
> processes, use the **chunked fallback** instead: run the foreground snippet with
> `$maxMinutes` set (e.g. `20`) and relaunch until the phase reports `success`. Any phase can
> be safely re-run — already-converted revisions/refs are skipped via the SHA index, so a
> relaunch after a checkpoint or an error always resumes rather than restarting.
>
> **How to launch a phase as a subagent:**
> 1. **Phase 0:** `task(prompt="Read phases/phase-0.md in skill dir <skillDir>. Fill in all interview values. Run the PowerShell snippet.")`
> 2. **Phases 1, 2, 3, 7, 8:** `task(prompt="Read phases/run-phase.md in skill dir <skillDir>. Set $skillDir='<skillDir>', $stateDir='<stateDir>', $phase='<N>'. Run the foreground PowerShell snippet.")`
> 3. **Phases 4, 5, 6:** `task(prompt="Read phases/run-phase.md in skill dir <skillDir>. Set $skillDir='<skillDir>', $stateDir='<stateDir>', $phase='<N>'. Run the detached-mode launcher snippet and report the LAUNCHED line.")`, then poll with separate short subagent calls per the polling protocol in that runbook.
>
> Only 3 substitutions for phases 1–8: `$skillDir` (constant), `$stateDir` (from Phase 0), `$phase` (the number). No assembling 30-line templates.
>
> **Model selection for phase subagents:** Phases 1–8 are mechanical — the subagent reads a runbook and runs a fixed PowerShell snippet. Heavy reasoning is not needed. Always use the lightest model available in the user's setup:
> - Claude Haiku if available (`claude-haiku-4.5`)
> - GPT-4.1 mini / GPT-4o mini as an alternative
> - Fall back to the user's default only if no lightweight model is configured
>
> Pass `model: "claude-haiku-4.5"` (or equivalent) on every `task()` call for phases 1–8. Phase 0 and the Detect step may use the default model as they require light reasoning to fill placeholders.
>
> The subagent reads the runbook, fills placeholders, and executes — the orchestrator never reads runbook content itself.
>
> **Runbook access:** The subagent reads its own runbook — the orchestrator only passes the skill directory path and the placeholder values gathered from the interview. The orchestrator never reads runbook content.
>
> **Always pass absolute paths:** Subagents run in an unknown working directory. Always resolve `$target` and `$authorsFile` to absolute paths before passing them — use the CWD reported by the detect subagent as the base for any relative path the user provided.

**Execution order:**

| Step | What | How |
|------|------|-----|
| Detect | Auto-detect SVN repo | Subagent reads `phases/detect.md` — returns URL, layout, authors, head revision |
| Phase 0 | Preflight + config | Subagent reads `phases/phase-0.md` — 15+ placeholder values from interview. **Capture `CANONICAL_STATEDIR=` and `CANONICAL_TARGET=` from its output — these are `$stateDir` and `$target` for all subsequent phases.** |
| Phases 1 + 2 + 3 | Git init, Author map, Resolve refs | **3 subagents in parallel** — each reads `phases/run-phase.md` with `$phase='1'`, `'2'`, `'3'`. Only 3 substitutions: `$skillDir`, `$stateDir`, `$phase`. **Use lightest available model.** |
| Phase 4 | Convert trunk | Subagent reads `phases/run-phase.md` with `$phase='4'`. **Before launching, tell the user: "Phase 4 is starting — this replays every trunk revision and can take minutes to hours."** **Launch detached, then poll** (see orchestration note above) — never a single blocking call. Use lightest available model. _(long-running)_ |
| Phase 5 | Convert branches | Subagent reads `phases/run-phase.md` with `$phase='5'`. Warn if repo has many branches. **Launch detached, then poll.** Use lightest available model. |
| Phase 6 | Convert tags | Subagent reads `phases/run-phase.md` with `$phase='6'`. **Launch detached, then poll.** Use lightest available model. |
| Phase 7 | Post-processing | Subagent reads `phases/run-phase.md` with `$phase='7'`. Use lightest available model. |
| Phase 8 | Summary | Subagent reads `phases/run-phase.md` with `$phase='8'`. Use lightest available model. |

- After each subagent completes (or, for phases 4–6, after polling reports `success`), report a one-line status to the user: `✅ Phase N complete — <key result>`
- If a phase fails, consult the consolidated `## On error` tables in `phases/run-phase.md`, fix the problem, and re-launch that phase only — earlier phases don't need to repeat (state is preserved in `$target\.svn2git\`); any phase can be safely re-run since already-converted revisions/refs are skipped automatically
- A state guard at the start of phases 4–6 will tell you exactly which prior phase to re-run if state files are missing

The most common issues are covered in `references/troubleshooting.md`.

---

## Step 5 — Verify

After the migration completes, check the result:

```bash
# Check recent commit messages and SVN revision traceability
git log --oneline | head -20

# Check all branches were created
git branch -a

# Check tags
git tag

# Inspect the latest commit in full
git show HEAD
```

If anything looks wrong (missing branches, garbled commit messages, missing history),
share the output here.

---

## Step 6 — Next steps

**Push to a remote:**
```bash
git remote add origin <remote-url>
git push --all origin
git push --tags origin
```

**Optional — strip git-svn-id trailers** (irreversible; requires `git filter-repo`):
```bash
git filter-repo --message-callback 'return re.sub(rb"\ngit-svn-id:.*", b"", message)'
```

---

## Reference files

- `references/algorithm.md` — technical algorithm spec (for debugging/understanding the scripts)
- `references/git-svn-mapping.md` — mapping from original git-svn CLI switches to this skill's options
- `references/troubleshooting.md` — auth issues, encoding, large repos, edge cases
