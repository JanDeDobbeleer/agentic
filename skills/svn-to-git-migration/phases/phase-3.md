# Phase 3 — Resolve Refs

## Purpose

Query the SVN repository to enumerate all refs (trunk, branches, tags) and write the result to `$stateDir\refs.json`. Later phases read this file to know which SVN URLs to convert and how to name the resulting git refs.

## Parallelism

This phase can run in parallel with Phase 1 and Phase 2. All three depend only on Phase 0's output (`config.json` + `core.pslib`) and do not write to the same files. Launch them simultaneously as background agents after Phase 0 completes; wait for all three before starting Phase 4.

## Inputs

- `$stateDir` — exact canonical state directory path (the `CANONICAL_STATEDIT=` value emitted by Phase 0)
- `$stateDir\config.json` — must contain layout options (`StdLayout`, `Trunk`, `Branches`, `Tags`, `DefaultBranch`, `Encoding`)
- `$stateDir\core.pslib`
- Live network access to `$cfg.SvnUrl`

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
    $repoRoot = (Invoke-SvnXml -SvnArgs @('info', '--xml', $cfg.SvnUrl)).SelectSingleNode('//repository/root').InnerText

    $refs = Resolve-Refs `
        -SvnUrl         $cfg.SvnUrl `
        -RepoRoot       $repoRoot `
        -UseStdLayout:  ([switch][bool]$cfg.StdLayout) `
        -TrunkPath      $cfg.Trunk `
        -BranchPaths    @($cfg.Branches) `
        -TagPaths       @($cfg.Tags) `
        -DefaultBranch  $cfg.DefaultBranch `
        -SourceEncoding $cfg.Encoding

    $refs | ConvertTo-Json -Depth 4 | Set-Content "$stateDir\refs.json" -Encoding UTF8
    Write-Host "Phase 3 complete. $($refs.Count) refs resolved."
    $refs | ForEach-Object {
        $kind = if ($_.IsTag) { 'tag' } else { 'branch' }
        Write-Host "  [$kind] $($_.RefName)  →  $($_.SvnUrl)"
    }
}
finally {
    Save-MigrationState -StateDir $stateDir
}
```

## Success check

- `$stateDir\refs.json` is created and contains a JSON array
- Output lists at least one ref (the trunk / default branch)
- For a standard-layout repo, expect entries for `refs/heads/<defaultBranch>` plus any branches and tags
- `Phase 3 complete. N refs resolved.` where N ≥ 1

## On error

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `SelectSingleNode … returned null` | SVN URL unreachable or wrong | Verify `$cfg.SvnUrl` with `svn info <url>` |
| `refs.json` is empty array `[]` | Layout flags don't match the repo structure | Re-run Phase 0 with correct `$stdLayout`/`$trunk`/`$branches`/`$tags` values |
| `Invoke-SvnXml : command not found` | Core not loaded properly | Ensure `core.pslib` exists in `$stateDir` and contains `Invoke-SvnXml` |
