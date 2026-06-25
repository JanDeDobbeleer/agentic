# Phase 6 — Convert Tags

## Purpose

Replay SVN tag directories as git refs. Clean tags (directories never modified after the SVN copy operation) become annotated git tags. Dirty tags (modified after creation) become branches named `tags/<tagname>` with a warning printed in the summary. Use `$cfg.TagsAsBranches = $true` to force all SVN tags into branches regardless of cleanliness.

**Phases 4 and 5 must complete before this phase** — tag commits may need the trunk/branch SHA index to resolve parent commits.

## Inputs

- `$stateDir` — exact canonical state directory path (the `CANONICAL_STATEDIT=` value emitted by Phase 0)
- `$stateDir\config.json`
- `$stateDir\refs.json` — written by Phase 3
- `$stateDir\sha-index.json` — written by Phases 4–5
- `$stateDir\core.pslib`
- Live network access to `$cfg.SvnUrl`

## PowerShell snippet

```powershell
$stateDir = '<STATE_DIR>'   # exact CANONICAL_STATEDIT value from Phase 0 output — passed directly by orchestrator

# ── State guard: verify required files from prior phases ─────────────────────
$_missing = @()
if (-not (Test-Path "$stateDir\config.json"))   { $_missing += 'config.json    (re-run Phase 0)' }
if (-not (Test-Path "$stateDir\core.pslib"))    { $_missing += 'core.pslib     (re-run Phase 0)' }
if (-not (Test-Path "$stateDir\refs.json"))     { $_missing += 'refs.json      (re-run Phase 3)' }
if (-not (Test-Path "$stateDir\sha-index.json")){ $_missing += 'sha-index.json (re-run Phase 4 then Phase 5)' }
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

# ── Phase 6: tags only ────────────────────────────────────────────────────────
$filteredRefs = $refs | Where-Object { $_.IsTag -eq $true }

Write-Host "Phase 6: converting $($filteredRefs.Count) tag ref(s)."

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
    Write-Host "Phase 6 complete."
}
finally {
    if (Test-Path $tempBase) { Remove-Item $tempBase -Recurse -Force -ErrorAction SilentlyContinue }
    Save-MigrationState -StateDir $stateDir
}
```

## Success check

- `git -C $cfg.Target tag` lists the expected tag names
- Dirty tags appear as `git branch -a` entries prefixed `tags/`
- Output ends with `Phase 6 complete`
- For a repo with no SVN tags, `$filteredRefs.Count` will be `0` — this is normal

## On error

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| State guard throws missing files | Prior phases didn't complete or state was lost | Follow the recovery hint in the error message |
| Tags show as branches (unexpected) | Tags were modified after creation (dirty tags) | Expected behaviour; use `--tags-as-branches` to make it consistent |
| Tag parent commit missing | Phase 4/5 SHA index not saved | Confirm `sha-index.json` in `$stateDir`; re-run Phase 4 then 5 |
| Network error mid-run | Transient SVN failure | Re-run this phase — already-converted refs are skipped |
