# Phase 4 — Convert Trunk

## Purpose

Replay every SVN revision on the trunk branch as a git commit, building the SHA index for the default branch. This is typically the longest phase — it can take minutes to hours on large repositories. **Inform the user before running** so they can set aside time or schedule it appropriately.

Branches (Phase 5) must run after this phase because they need the trunk SHA index to resolve `copyfrom` parent commits.

## Inputs

- `$stateDir` — exact canonical state directory path (the `CANONICAL_STATEDIT=` value emitted by Phase 0)
- `$stateDir\config.json`
- `$stateDir\refs.json` — written by Phase 3
- `$stateDir\core.pslib`
- An initialised git repo at `$cfg.Target` (Phase 1)
- Live network access to `$cfg.SvnUrl`

## PowerShell snippet

```powershell
$stateDir = '<STATE_DIR>'   # exact CANONICAL_STATEDIT value from Phase 0 output — passed directly by orchestrator

# ── State guard: verify required files from prior phases ─────────────────────
$_missing = @()
if (-not (Test-Path "$stateDir\config.json")) { $_missing += 'config.json  (re-run Phase 0)' }
if (-not (Test-Path "$stateDir\core.pslib"))  { $_missing += 'core.pslib   (re-run Phase 0)' }
if (-not (Test-Path "$stateDir\refs.json"))   { $_missing += 'refs.json    (re-run Phase 3)' }
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

# ── Phase 4: trunk only ───────────────────────────────────────────────────────
$trunkRef = "refs/heads/$($cfg.DefaultBranch)"
$filteredRefs = $refs | Where-Object { -not $_.IsTag -and $_.RefName -eq $trunkRef }

Write-Host "Phase 4: converting $($filteredRefs.Count) trunk ref(s). This may take a long time."

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
    Write-Host "Phase 4 complete."
}
finally {
    if (Test-Path $tempBase) { Remove-Item $tempBase -Recurse -Force -ErrorAction SilentlyContinue }
    Save-MigrationState -StateDir $stateDir
}
```

## Success check

- `git -C $cfg.Target log --oneline refs/heads/<defaultBranch>` shows commits after the phase
- Output ends with `Phase 4 complete`
- SHA index saved in `$stateDir\sha-index.json` (persisted by `Save-MigrationState`)
- `$Script:Stats` counters show processed revisions

## On error

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| State guard throws missing files | Prior phases didn't complete | Follow the recovery hint in the error message |
| `No trunk ref found` / `$filteredRefs` is empty | `DefaultBranch` in config doesn't match the ref in `refs.json` | Inspect `refs.json` and verify `RefName` for trunk |
| `svn update` fails mid-run | Network timeout or SVN auth expired | Re-run this phase — `Import-MigrationState` restores the SHA index; already-converted revisions are skipped |
| `git hash-object` / `write-tree` errors | Disk full or git repo corrupt | Free disk space; check `git fsck` |
| Very slow progress | Large binary files or many revisions | Normal — keep running; or use `--revision N:M` ranges across multiple phase-4 runs |
