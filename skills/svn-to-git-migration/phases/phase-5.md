# Phase 5 — Convert Branches

## Purpose

Replay SVN revisions for every non-trunk branch as git commits. Branch commits that were copied from trunk (or another branch) use the SHA index built in Phase 4 to set the correct parent commit, preserving copy history. **Phase 4 must complete successfully before running this phase.**

Like Phase 4, this can be long-running for repos with many branches or large histories.

## Inputs

- `$stateDir` — exact canonical state directory path (the `CANONICAL_STATEDIT=` value emitted by Phase 0)
- `$stateDir\config.json`
- `$stateDir\refs.json` — written by Phase 3
- `$stateDir\sha-index.json` — written by Phase 4 (via `Save-MigrationState`)
- `$stateDir\core.pslib`
- An initialised git repo at `$cfg.Target` with trunk commits (Phase 4)
- Live network access to `$cfg.SvnUrl`

## PowerShell snippet

```powershell
$stateDir = '<STATE_DIR>'   # exact CANONICAL_STATEDIT value from Phase 0 output — passed directly by orchestrator

# ── State guard: verify required files from prior phases ─────────────────────
$_missing = @()
if (-not (Test-Path "$stateDir\config.json"))   { $_missing += 'config.json    (re-run Phase 0)' }
if (-not (Test-Path "$stateDir\core.pslib"))    { $_missing += 'core.pslib     (re-run Phase 0)' }
if (-not (Test-Path "$stateDir\refs.json"))     { $_missing += 'refs.json      (re-run Phase 3)' }
if (-not (Test-Path "$stateDir\sha-index.json")){ $_missing += 'sha-index.json (re-run Phase 4)' }
if ($_missing.Count -gt 0) {
    throw ("State files missing from '$stateDir':`n  " + ($_missing -join "`n  "))
}

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

# ── Reconstruct typed ref list from JSON ─────────────────────────────────────
$refsJson = Get-Content "$stateDir\refs.json" -Raw | ConvertFrom-Json
$refs = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($r in $refsJson) {
    $refs.Add([pscustomobject]@{
        RefName     = $r.RefName
        SvnUrl      = $r.SvnUrl
        IsTag       = [bool]$r.IsTag
        TagName     = $r.TagName
        CopyfromUrl = $r.CopyfromUrl
        CopyfromRev = $r.CopyfromRev
    })
}

$infoXml  = Invoke-SvnXml -SvnArgs @('info', '--xml', $cfg.SvnUrl)
$repoUuid = $infoXml.SelectSingleNode('//repository/uuid').InnerText
$revRange = Parse-RevisionRange -RevRange $cfg.Revision
$authorMap = Import-AuthorMap -FilePath $cfg.AuthorsFile

$tempBase   = Join-Path ([System.IO.Path]::GetTempPath()) "svn2git_$(Get-Random)"
$stagingDir = Join-Path $tempBase 'staging'
New-Item -ItemType Directory -Path $tempBase -Force | Out-Null

# ── Phase 5: non-trunk branches only ─────────────────────────────────────────
$trunkRef = "refs/heads/$($cfg.DefaultBranch)"
$filteredRefs = $refs | Where-Object { -not $_.IsTag -and $_.RefName -ne $trunkRef }

Write-Host "Phase 5: converting $($filteredRefs.Count) branch ref(s)."

try {
    foreach ($ref in $filteredRefs) {
        Invoke-ConvertRef `
            -Ref               $ref `
            -GitDir            $resolvedTarget `
            -StagingDir        $stagingDir `
            -RepoUuid          $repoUuid `
            -RevRange          $revRange `
            -AuthorMap         $authorMap `
            -IgnorePattern     $cfg.IgnorePaths `
            -IncludePattern    $cfg.IncludePaths `
            -KeepEmpty:        ([switch][bool]$cfg.NoSkipEmptyCommits) `
            -OmitMetadata:     ([switch][bool]$cfg.NoMetadata) `
            -AllTagsAsBranches:([switch][bool]$cfg.TagsAsBranches) `
            -SourceEncoding    $cfg.Encoding
    }
    Write-Host "Phase 5 complete."
}
finally {
    if (Test-Path $tempBase) { Remove-Item $tempBase -Recurse -Force -ErrorAction SilentlyContinue }
    Save-MigrationState -StateDir $stateDir
}
```

## Success check

- `git -C $cfg.Target branch -a` shows the expected branch names after the phase
- Output ends with `Phase 5 complete`
- For a repo with no branches (single-path layout), `$filteredRefs.Count` will be `0` — this is normal

## On error

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| State guard throws missing files | Prior phases didn't complete or state was lost | Follow the recovery hint in the error message |
| Branch has no parent commit / detached history | Phase 4 SHA index not loaded | Confirm `sha-index.json` exists in `$stateDir`; re-run Phase 4 if missing |
| `copyfrom` parent not found | Branch was copied from a revision outside the `--revision` range | Widen `$cfg.Revision` and re-run from Phase 4 |
| Network error mid-run | Transient SVN failure | Re-run this phase — already-converted revisions are skipped via the SHA index |
