# Run Phase (1–8) — Unified runbook

## Purpose

Execute any single migration phase (1–8) using the unified `scripts/run-phase.pslib` library.
Phase 0 is the only exception — it has its own runbook (`phase-0.md`) because the state
directory does not exist yet.

**Phases 4, 5, 6 are long-running** (minutes to hours) and are why this runbook has two
execution modes below. A single foreground `powershell -Command` tool call that blocks for
hours will die when the calling agent session's token expires (`403` / "token expired or
invalid") — the request itself is still in flight when the token goes stale, and there is no
way to refresh a token from inside an open call. **Detached mode** (below) avoids this by never
holding a request open: the phase runs as an independent OS process, and the orchestrator only
ever makes short polling calls. Phases 1, 2, 3, 7, 8 are short enough to run in the plain
foreground snippet as before.

## Inputs

| Variable | Description |
|----------|-------------|
| `$skillDir` | Absolute path to the `svn-to-git-migration` skill directory |
| `$stateDir` | Canonical state directory path — the `CANONICAL_STATEDIR=` value from Phase 0 output |
| `$phase` | Phase number as a string: `'1'`, `'2'`, …, `'8'` |
| `$maxMinutes` | Optional. Time budget in minutes for phases 4–6. `0` or unset = unlimited. On expiry the phase saves state, prints a `CHECKPOINT:` line, writes `phase-<N>.status.json` with `status: "checkpoint"`, and exits cleanly. Re-running the same phase continues where it left off (already-converted revisions are skipped via the SHA index). Ignored by phases 1, 2, 3, 7, 8. |

## PowerShell snippet (foreground)

Use this directly for phases 1, 2, 3, 7, 8. For phases 4, 5, 6, prefer **Detached mode**
below — only fall back to this foreground form per the **Chunked fallback** section.

```powershell
$skillDir   = '<SKILL_DIR>'    # absolute path to the skill directory — constant across all phases
$stateDir   = '<STATE_DIR>'    # CANONICAL_STATEDIR value from Phase 0 output
$phase      = '<PHASE_NUMBER>' # '1' through '8'
$maxMinutes = 0                # phases 4-6 only; 0 = unlimited; set e.g. 20 for a chunked run

# Load and run — dot-source keeps $stateDir, $phase, $maxMinutes in scope.
# .pslib extension is intentionally non-executable; never use -File.
. ([scriptblock]::Create([System.IO.File]::ReadAllText("$skillDir\scripts\run-phase.pslib")))
```

## State files phases 4–6 write

| File | Written | Purpose |
|------|---------|---------|
| `$stateDir\progress.json` | Every processed revision (checkpoint cadence: every 50 revisions, plus in `finally` blocks) | Live progress: `{"phase","ref","rev","revIndex","revTotal","commits","status","message","updatedAt"}`. `status` is `running` \| `checkpoint` \| `complete` \| `error`. |
| `$stateDir\phase-<N>.status.json` | Once, when the phase run ends (success, checkpoint, or error) | Terminal result: `{"phase","status","message","completedAt"}`. `status` is `success` \| `checkpoint` \| `error`. |
| stdout | Once, only when `$maxMinutes` expires | `CHECKPOINT: phase=<N> ref=<refName> rev=<lastConvertedRev>` |

`progress.json` is overwritten in place (always reflects the latest revision). `phase-<N>.status.json`
is the authoritative terminal state for a run — always check it first when polling.

## Detached mode (default for phases 4, 5, 6)

Launch the phase as an independent background process so no agent tool call stays open for
its whole duration. The orchestrator (or a short-lived subagent) runs this **launcher**
snippet, which returns immediately.

```powershell
$skillDir   = '<SKILL_DIR>'    # absolute path to the skill directory — constant across all phases
$stateDir   = '<STATE_DIR>'    # CANONICAL_STATEDIR value from Phase 0 output
$phase      = '<PHASE_NUMBER>' # '4', '5', or '6'
$maxMinutes = 0                # 0 = unlimited; set e.g. 20 to also checkpoint periodically in the background

# Build the child process's script text as a double-quoted here-string. Backtick-escaped
# `$` stays literal in the child's script; un-escaped $skillDir/$stateDir/$phase/$maxMinutes
# interpolate from THIS (parent) scope right now — the child gets baked-in literal values,
# not live variable references, so it needs no environment/argument passing.
$innerCommand = @"
`$skillDir = '$skillDir'
`$stateDir = '$stateDir'
`$phase = '$phase'
`$maxMinutes = $maxMinutes
. ([scriptblock]::Create([System.IO.File]::ReadAllText('$skillDir\scripts\run-phase.pslib')))
"@

# Base64-encode the child script (-EncodedCommand) — passing a multi-line string through
# -ArgumentList '-Command' mangles newlines/quotes on Windows PowerShell 5.1.
$encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($innerCommand))

# If a previous run's log files are still open by a live process, delete/rename them first —
# -RedirectStandardOutput/-Error fail if the target path is locked.
$proc = Start-Process powershell `
    -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) `
    -WindowStyle Hidden `
    -RedirectStandardOutput "$stateDir\phase-$phase.log" `
    -RedirectStandardError  "$stateDir\phase-$phase.err.log" `
    -PassThru

Write-Host "LAUNCHED phase=$phase pid=$($proc.Id)"
```

The launcher call itself completes in well under a second — it starts the child process and
returns. The child process (and the conversion work) survives independently of the launching
tool call, the subagent that ran it, and even the orchestrator's own session.

### Poll snippet

Short, cheap, safe to call every few minutes:

```powershell
$stateDir = '<STATE_DIR>'
$phase    = '<PHASE_NUMBER>'

$statusFile   = "$stateDir\phase-$phase.status.json"
$progressFile = "$stateDir\progress.json"

if (Test-Path $statusFile) {
    $s = Get-Content $statusFile -Raw
    Write-Host $s
    if ((ConvertFrom-Json $s).status -eq 'error') {
        Write-Host '--- last log lines ---'
        if (Test-Path "$stateDir\phase-$phase.log")     { Get-Content "$stateDir\phase-$phase.log"     -Tail 20 }
        if (Test-Path "$stateDir\phase-$phase.err.log") { Get-Content "$stateDir\phase-$phase.err.log" -Tail 20 }
    }
} elseif (Test-Path $progressFile) {
    Get-Content $progressFile -Raw | Write-Host
} else {
    Write-Host "NOT_STARTED: no phase-$phase.status.json or progress.json yet in $stateDir"
}
```

### Polling protocol for the orchestrator

1. Launch detached via a short subagent call (the launcher snippet above). It returns
   `LAUNCHED phase=<N> pid=<PID>` almost instantly.
2. Poll every 2–5 minutes with short subagent calls running the poll snippet. Never keep a
   single tool call open waiting for a long phase to finish.
3. Report progress to the user each poll, e.g. `Phase 4: rev 3200/5000 (64%)` (derive the
   percentage from `progress.json`'s `revIndex`/`revTotal`).
4. On `status: "checkpoint"` in `phase-<N>.status.json` — relaunch the same phase (detached
   launcher again, same `$phase`); it resumes from the last checkpointed revision.
5. On `status: "error"` — consult the **On error** tables below, fix the problem, relaunch.
6. On `status: "success"` — proceed to the next phase.

## Chunked fallback (when `Start-Process` is blocked)

Some corporate policies block spawning detached processes. In that case run the plain
**foreground snippet** with a bounded `$maxMinutes` (e.g. `20`) inside a normal subagent call,
and relaunch (same phase, same command) until `phase-<N>.status.json` reports `success`:

```powershell
$skillDir   = '<SKILL_DIR>'
$stateDir   = '<STATE_DIR>'
$phase      = '<PHASE_NUMBER>'  # '4', '5', or '6'
$maxMinutes = 20                # keep each call well under the agent session's own timeout

. ([scriptblock]::Create([System.IO.File]::ReadAllText("$skillDir\scripts\run-phase.pslib")))
```

Each call either finishes the phase (`success`) or checkpoints (`checkpoint`) and exits
cleanly before the time budget — never open-ended, so the request itself can't outlive the
session token.

## Success checks by phase

| Phase | Success signal |
|-------|---------------|
| 1 | Output ends with `Phase 1 complete` |
| 2 | Output contains `VERIFIED: authors-loaded=N` then `Phase 2 complete` (N = 0 if no authors file) |
| 3 | Output contains `VERIFIED: refs-written=N branches=B tags=T` then `Phase 3 complete` |
| 4 | `phase-4.status.json` status `success` — output ends with `Phase 4 complete`; `sha-index.json` updated in state dir |
| 5 | `phase-5.status.json` status `success` — output ends with `Phase 5 complete`; branches appear in `git branch -a` |
| 6 | `phase-6.status.json` status `success` — output ends with `Phase 6 complete`; tags appear in `git tag` |
| 7 | Output ends with `Phase 7 complete` — HEAD points to default branch |
| 8 | Summary printed — commit counts, branch/tag totals, next-steps hint |

> Phases 4–6 may also legitimately end with `status: "checkpoint"` instead of `success` — that
> is not a failure, it means `$maxMinutes` expired mid-run. Relaunch the same phase to continue.

> **Orchestrator tip:** Parse `VERIFIED:` lines from phases 2 and 3 to report concrete counts to the user: `✅ Phase 3 complete — 14 refs (3 branches, 11 tags)`.

## On error

### General / any phase

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `$stateDir must be set` | Orchestrator forgot to set `$stateDir` before dot-sourcing | Set `$stateDir` in the same scope before the dot-source line |
| `config.json missing` / `No config found` | Phase 0 did not complete | Re-run Phase 0 (`phase-0.md`) |
| `refs.json missing` | Phase 3 did not complete | Re-run Phase 3 (`$phase = '3'`) |
| `sha-index.json missing` (phase 5/6) | Phase 4 (and for phase 6, Phase 5) did not complete | Re-run the missing prior phase |
| `Invoke-SvnXml`/`Write-Summary`/etc. "command not found" | `core.pslib` not loaded (missing or corrupt copy in state dir) | Confirm `core.pslib` exists in `$stateDir`; re-run Phase 0 if missing |
| `403` / `session expired` / `invalid token` | The agent session running the phase timed out mid-call (long-lived request) | Relaunch the phase — resume skips already-converted revisions/refs via the SHA index. Prefer **detached mode** so no single request runs long enough to hit this. Last resort only: paste the snippet into an interactive `powershell -Command` window with `$skillDir`, `$stateDir`, `$phase` set. |
| Network error / transient SVN failure mid-run | SVN server hiccup, auth expiry | Re-run the phase — already-converted revisions/refs are skipped via the SHA index |

### Phase 1 — Git init

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Target … exists and is not a git repo or migration target` | Unrelated directory at target path | Choose a different `$target` or remove the existing directory |
| `git: command not found` / `git is not recognized` | Git not on PATH | Install Git for Windows and restart the shell |

### Phase 2 — Author map

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Cannot find path … authors.txt` | File path in config is wrong or file was moved | Re-run Phase 0 with the correct `$authorsFile` path, or edit `config.json` manually |
| `Parse error at line N` | Malformed authors.txt line (expected `svnuser = Full Name <email>`) | Fix that line in authors.txt and re-run this phase |

### Phase 3 — Resolve refs

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `SelectSingleNode … returned null` | SVN URL unreachable or wrong | Verify `$cfg.SvnUrl` with `svn info <url>` |
| `refs.json` is empty array `[]` | Layout flags don't match the repo structure | Re-run Phase 0 with correct `$stdLayout`/`$trunk`/`$branches`/`$tags` values |

### Phases 4–6 — Convert trunk / branches / tags

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `No trunk ref found` / filtered ref list is empty (phase 4) | `DefaultBranch` in config doesn't match the ref in `refs.json` | Inspect `refs.json` and verify `RefName` for trunk |
| Branch has no parent commit / detached history (phase 5) | Phase 4 SHA index not loaded | Confirm `sha-index.json` exists in `$stateDir`; re-run Phase 4 if missing |
| `copyfrom` parent not found (phase 5/6) | Branch/tag was copied from a revision outside the `--revision` range | Widen `$cfg.Revision` and re-run from Phase 4 |
| Tags show as branches (unexpected, phase 6) | Tags were modified after creation in SVN (dirty tags) | Expected behaviour; use `--tags-as-branches` to make it consistent |
| `git hash-object` / `write-tree` errors | Disk full or git repo corrupt | Free disk space; check `git fsck` |
| Very slow progress | Large binary files or many revisions | Normal — let it run (or checkpoint via detached mode / `$maxMinutes` and relaunch); or narrow `--revision N:M` ranges across multiple runs |

### Phase 7 — Post-processing

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Invoke-CreateIgnore` fails | SVN URL unreachable while reading `svn:ignore` | Check network/credentials; re-run, or set `NoCreateIgnore = true` in `config.json` and re-run |
| `symbolic-ref` fails with `not a git repository` | `$cfg.Target` path is wrong | Verify `Target` in `config.json` matches the actual git repo location |
| `git gc` takes very long | Large repo | Normal — let it finish; it only needs to run once |

### Phase 8 — Summary

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Zero commits reported | Phases 4–6 did not run or failed silently | Check `git log --oneline` in `$cfg.Target`; re-run Phase 4 |
| Dirty-tag warnings for all tags | All tags were modified after creation in SVN | Expected for some repos; tags become `tags/<name>` branches — that is correct |
