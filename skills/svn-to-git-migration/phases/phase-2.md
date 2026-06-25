# Phase 2 — Author Map

## Purpose

Load and validate the SVN-to-Git authors mapping from the file path recorded in `config.json`. If no authors file was provided, `Import-AuthorMap` returns an empty map and commits will use `svnuser@<repo-uuid>` as the author email. Requires Phase 0 to have run first.

## Parallelism

This phase can run in parallel with Phase 1 and Phase 3. All three depend only on Phase 0's output (`config.json` + `core.pslib`) and do not write to the same files. Launch them simultaneously as background agents after Phase 0 completes; wait for all three before starting Phase 4.

## Inputs

- `$stateDir` — exact canonical state directory path (the `CANONICAL_STATEDIT=` value emitted by Phase 0)
- `$stateDir\config.json` — must contain `AuthorsFile` (may be empty string)
- `$stateDir\core.pslib`

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
    $authorMap = Import-AuthorMap -FilePath $cfg.AuthorsFile
    Write-Host "Phase 2 complete. $($authorMap.Count) author entries loaded."
}
finally {
    Save-MigrationState -StateDir $stateDir
}
```

## Success check

- Output prints `Phase 2 complete. N author entries loaded.`
- If `AuthorsFile` was empty, `N` is `0` — this is valid; authors will default to `svnuser@<uuid>`
- If `AuthorsFile` was provided, `N` should match the number of lines in the file

## On error

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Cannot find path … authors.txt` | File path in config is wrong or file was moved | Re-run Phase 0 with the correct `$authorsFile` path, or edit `config.json` manually |
| `Parse error at line N` | Malformed authors.txt line (expected `svnuser = Full Name <email>`) | Fix that line in authors.txt and re-run this phase |
