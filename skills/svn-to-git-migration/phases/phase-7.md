# Phase 7 — Post-processing

## Purpose

Three clean-up steps after all history has been converted:

1. **svn:ignore → .gitignore** — reads `svn:ignore` properties from the SVN repository and writes `.gitignore` files into the git tree, then creates a final commit on each ref (skipped if `NoCreateIgnore = true` in config).
2. **Set HEAD** — points `HEAD` at `refs/heads/<defaultBranch>` so the repo is in a clean state.
3. **git gc** — runs `git gc --aggressive --prune=now` to compact the object store and reduce on-disk size.

## Inputs

- `$stateDir` — exact canonical state directory path (the `CANONICAL_STATEDIT=` value emitted by Phase 0)
- `$stateDir\config.json`
- `$stateDir\refs.json` — written by Phase 3
- `$stateDir\sha-index.json` — written by Phases 4–6
- `$stateDir\core.pslib`
- Live network access to `$cfg.SvnUrl` (needed for `Invoke-CreateIgnore`)

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
$authorMap = Import-AuthorMap -FilePath $cfg.AuthorsFile

$tempBase   = Join-Path ([System.IO.Path]::GetTempPath()) "svn2git_$(Get-Random)"
$stagingDir = Join-Path $tempBase 'staging'
New-Item -ItemType Directory -Path $tempBase -Force | Out-Null

try {
    # 7.1 — svn:ignore → .gitignore
    if (-not [bool]$cfg.NoCreateIgnore) {
        Write-Host "Phase 7.1: Converting svn:ignore properties to .gitignore files..."
        Invoke-CreateIgnore -Refs $refs -GitDir $resolvedTarget `
            -StagingDir $stagingDir -RepoUuid $repoUuid `
            -AuthorMap $authorMap -SourceEncoding $cfg.Encoding
    } else {
        Write-Host "Phase 7.1: Skipped (NoCreateIgnore = true)"
    }

    # 7.2 — Set HEAD
    Write-Host "Phase 7.2: Setting HEAD to refs/heads/$($cfg.DefaultBranch)"
    & git -C $resolvedTarget symbolic-ref HEAD "refs/heads/$($cfg.DefaultBranch)" | Out-Null

    # 7.3 — git gc
    Write-Host "Phase 7.3: Running git gc --aggressive --prune=now (may take a few minutes)..."
    & git -C $resolvedTarget gc --aggressive --prune=now 2>&1 | Out-Null

    Write-Host "Phase 7 complete."
}
finally {
    if (Test-Path $tempBase) { Remove-Item $tempBase -Recurse -Force -ErrorAction SilentlyContinue }
    Save-MigrationState -StateDir $stateDir
}
```

## Success check

- `git -C $cfg.Target symbolic-ref HEAD` returns `refs/heads/<defaultBranch>`
- If `NoCreateIgnore` was false: each ref that had `svn:ignore` properties now has a `.gitignore` commit at its tip
- `git -C $cfg.Target count-objects -v` shows a reduced loose-object count after gc
- Output ends with `Phase 7 complete`

## On error

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Invoke-CreateIgnore` fails | SVN URL unreachable while reading `svn:ignore` | Check network/credentials; re-run or set `NoCreateIgnore = true` in `config.json` and re-run |
| `symbolic-ref` fails with `not a git repository` | `$cfg.Target` path is wrong | Verify `Target` in `config.json` matches the actual git repo location |
| `git gc` takes very long | Large repo | Normal — let it finish; it only needs to run once |
