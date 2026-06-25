# Phase 8 — Summary

## Purpose

Print the migration summary report: commit counts, branch and tag totals, dirty-tag warnings, elapsed time, and the next-steps hint for pushing to a remote. No network access or state mutations — read-only.

## Inputs

- `$stateDir` — exact canonical state directory path (the `CANONICAL_STATEDIT=` value emitted by Phase 0)
- `$stateDir\config.json`
- `$stateDir\core.pslib`
- The completed git repo at `$cfg.Target`

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

$cfg = Get-Content "$stateDir\config.json" -Raw | ConvertFrom-Json
$resolvedTarget = $cfg.Target

try {
    Write-Summary -GitDir $resolvedTarget -SvnUrl $cfg.SvnUrl
}
finally {
    Save-MigrationState -StateDir $stateDir
}
```

## Success check

- Output shows commit count, branch count, tag count
- Any dirty-tag warnings appear clearly labelled
- Output includes the SVN URL and git target path for traceability

## On error

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Write-Summary : command not found` | Core not loaded | Confirm `core.pslib` in `$stateDir`; re-run |
| Zero commits reported | Phases 4–6 did not run or failed silently | Check `git log --oneline` in `$cfg.Target`; re-run Phase 4 |
| Dirty-tag warnings for all tags | All tags were modified after creation in SVN | Expected for some repos; tags become `tags/<name>` branches — that is correct |
