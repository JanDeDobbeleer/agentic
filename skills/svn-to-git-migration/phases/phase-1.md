# Phase 1 — Git Init

## Purpose

Initialise an empty git repository at the target path with `core.autocrlf false`. If a git repo already exists at that path it is reused (allowing resume after interruption). Requires Phase 0 to have run first.

## Parallelism

This phase can run in parallel with Phase 2 and Phase 3. All three depend only on Phase 0's output (`config.json` + `core.pslib`) and do not write to the same files. Launch them simultaneously as background agents after Phase 0 completes; wait for all three before starting Phase 4.

## Inputs

- `$stateDir` — exact canonical state directory path (the `CANONICAL_STATEDIT=` value emitted by Phase 0)
- `$stateDir\config.json` — written by Phase 0
- `$stateDir\core.pslib` — copied by Phase 0

## PowerShell snippet

```powershell
$stateDir = '<STATE_DIR>'   # exact CANONICAL_STATEDIT value from Phase 0 output — passed directly by orchestrator

# ── Load core functions inline ───────────────────────────────────────────────
$_coreContent = [System.IO.File]::ReadAllText("$stateDir\core.pslib")
. ([scriptblock]::Create($_coreContent))

$ErrorActionPreference = 'Stop'
$Script:ShaIndex = [System.Collections.Generic.Dictionary[string,
    [System.Collections.Generic.SortedDictionary[int,string]]]]::new()
$Script:Stats = New-StatsObject
Import-MigrationState -StateDir $stateDir

$cfg            = Get-Content "$stateDir\config.json" -Raw | ConvertFrom-Json
$resolvedTarget = $cfg.Target
$defaultBranch  = $cfg.DefaultBranch

try {
    if (Test-Path $resolvedTarget) {
        if (Test-Path (Join-Path $resolvedTarget '.git')) {
            Write-Host "Reusing existing git repo at $resolvedTarget"
        } elseif (Test-Path (Join-Path $resolvedTarget '.svn2git')) {
            # Phase 0 created the directory (via state dir) but git init hasn't run yet
            & git init "--initial-branch=$defaultBranch" $resolvedTarget | Out-Null
            Write-Host "Initialised git repo inside existing migration target at $resolvedTarget"
        } else {
            throw "Target '$resolvedTarget' exists and is not a git repo or migration target. Choose a different path or remove it."
        }
    } else {
        & git init "--initial-branch=$defaultBranch" $resolvedTarget | Out-Null
        Write-Host "Initialised git repo at $resolvedTarget"
    }
    & git -C $resolvedTarget config core.autocrlf false | Out-Null
    Write-Host "Phase 1 complete. Git repo at: $resolvedTarget"
}
finally {
    Save-MigrationState -StateDir $stateDir
}
```

## Success check

- `$resolvedTarget\.git\` directory exists after the phase
- `git -C $resolvedTarget config core.autocrlf` returns `false`
- Output ends with `Phase 1 complete`

## On error

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `No config found` | Phase 0 was skipped | Run Phase 0 first |
| `Target … exists and is not a git repo or migration target` | Unrelated directory at target path | Choose a different `$target` or remove the existing directory |
| `git: command not found` / `git is not recognized` | Git not on PATH | Install Git for Windows and restart the shell |


