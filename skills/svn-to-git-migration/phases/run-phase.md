# Run Phase (1–8) — Unified runbook

## Purpose

Execute any single migration phase (1–8) using the unified `scripts/run-phase.pslib` library.
Phase 0 is the only exception — it has its own runbook (`phase-0.md`) because the state
directory does not exist yet.

## Inputs

| Variable | Description |
|----------|-------------|
| `$skillDir` | Absolute path to the `svn-to-git-migration` skill directory |
| `$stateDir` | Canonical state directory path — the `CANONICAL_STATEDIT=` value from Phase 0 output |
| `$phase` | Phase number as a string: `'1'`, `'2'`, …, `'8'` |

## PowerShell snippet

```powershell
$skillDir = '<SKILL_DIR>'   # absolute path to the skill directory — constant across all phases
$stateDir = '<STATE_DIR>'   # CANONICAL_STATEDIT value from Phase 0 output
$phase    = '<PHASE_NUMBER>'  # '1' through '8'

# Load and run — dot-source keeps $stateDir and $phase in scope.
# .pslib extension is intentionally non-executable; never use -File.
. ([scriptblock]::Create([System.IO.File]::ReadAllText("$skillDir\scripts\run-phase.pslib")))
```

## Orchestration

The orchestrating agent passes:
- `$skillDir` — same value for every phase; captured once at session start
- `$stateDir` — captured from `CANONICAL_STATEDIT=` in Phase 0 output; same for every phase
- `$phase` — the only value that changes per invocation

Three substitutions total; the phase number is the only one that varies after Phase 0.

## Success checks by phase

| Phase | Success signal |
|-------|---------------|
| 1 | Output ends with `Phase 1 complete` |
| 2 | Output ends with `Phase 2 complete. N author entries loaded.` |
| 3 | Output ends with `Phase 3 complete. N refs resolved.` |
| 4 | Output ends with `Phase 4 complete` — `sha-index.json` updated in state dir |
| 5 | Output ends with `Phase 5 complete` — branches appear in `git branch -a` |
| 6 | Output ends with `Phase 6 complete` — tags appear in `git tag` |
| 7 | Output ends with `Phase 7 complete` — HEAD points to default branch |
| 8 | Summary printed — commit counts, branch/tag totals, next-steps hint |

## On error

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `$stateDir must be set` | Orchestrator forgot to set `$stateDir` before dot-sourcing | Set `$stateDir` in the same scope before the dot-source line |
| `config.json missing` | Phase 0 did not complete | Re-run Phase 0 (`phase-0.md`) |
| `refs.json missing` | Phase 3 did not complete | Re-run Phase 3 (`$phase = '3'`) |
| `sha-index.json missing` (phase 5/6) | Phase 4 did not complete | Re-run Phase 4 (`$phase = '4'`) |
| Any other phase error | See the relevant `phase-N.md` for detailed error tables | Run that phase's individual runbook for the error table |
