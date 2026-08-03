# Detect — Gather SVN repo info

## Purpose

Auto-detect whether the current working directory is an SVN working copy or bare repository, gather layout and author
info, and return a structured summary to the orchestrating agent. The orchestrator uses this to conduct the migration
interview. No function library is required — only the `svn` CLI.

**This runbook is executed by a subagent. Do not ask the user for anything — return all findings as structured output at
the end.**

## Inputs

- Current working directory (passed by orchestrator as `$cwd`)
- No `$svnUrl` needed — detection is automatic

## PowerShell snippet

```powershell
$cwd = '<CWD>'   # orchestrator fills in the current working directory
Set-Location $cwd

# Step 1: Auto-detect SVN repo
$svnUrl = $null
$detectionMethod = 'none'

$cwdInfoRaw = & svn info --xml . 2>&1
if ($LASTEXITCODE -eq 0) {
    $cwdInfo  = [xml]$cwdInfoRaw
    $svnUrl   = $cwdInfo.info.entry.repository.root
    $detectionMethod = 'working-copy'
} elseif ((Test-Path ".\format") -and (Test-Path ".\db")) {
    $repoPath = (Resolve-Path .).Path
    $svnUrl   = 'file:///' + ($repoPath -replace '\\', '/')
    $detectionMethod = 'bare-repo'
}

# Step 2: Gather repo details (only if URL was detected)
$headRev  = 'UNKNOWN'
$repoUuid = 'UNKNOWN'
$rootUrl  = $svnUrl
$layout   = 'unknown'
$authors  = @()
$authorScanComplete = $false

if ($svnUrl) {
    $infoXml  = [xml](& svn info --xml $svnUrl 2>&1)
    $headRev  = $infoXml.info.entry.repository.commit.revision
    $repoUuid = $infoXml.info.entry.repository.uuid
    $rootUrl  = $infoXml.info.entry.repository.root

    # Step 3: Detect layout
    $listing = & svn list $svnUrl 2>&1
    $hasTrunk    = $listing -match '^trunk/'
    $hasBranches = $listing -match '^branches/'
    $hasTags     = $listing -match '^tags/'
    if ($hasTrunk -and $hasBranches -and $hasTags) { $layout = 'standard' }
    elseif ($hasTrunk) { $layout = 'trunk-only' }
    else { $layout = 'custom' }

    # Step 4: Discover ALL unique authors (-q = headers only, fast on large repos)
    # No --limit so every committer is captured, regardless of repo age.
    $logXml = [xml](& svn log --xml -q $svnUrl 2>&1)
    $authors = $logXml.log.logentry |
        ForEach-Object { $_.author } |
        Where-Object   { $_ -ne $null } |
        Sort-Object -Unique
    $authorScanComplete = $true
}

# ── Structured return ─────────────────────────────────────────────────────────
Write-Host "=== DETECT RESULT ==="
Write-Host "DETECTION_METHOD : $detectionMethod"
Write-Host "SVN_URL          : $(if ($svnUrl) { $svnUrl } else { 'NOT_DETECTED' })"
Write-Host "HEAD_REVISION    : $headRev"
Write-Host "REPO_UUID        : $repoUuid"
Write-Host "REPO_ROOT        : $rootUrl"
Write-Host "LAYOUT           : $layout"
Write-Host "AUTHOR_COUNT     : $($authors.Count)"
Write-Host "AUTHOR_SCAN_COMPLETE : $($authorScanComplete.ToString().ToLower())"
Write-Host "AUTHORS          : $($authors -join ', ')"
Write-Host "NEEDS_URL        : $(if (-not $svnUrl) { 'true' } else { 'false' })"
Write-Host "=== END DETECT RESULT ==="
```

## Return

The orchestrator reads the `=== DETECT RESULT ===` block. Key fields:

- **Field:** `NEEDS_URL: true`
  - **Meaning:** URL not auto-detected — orchestrator must ask the user before Phase 0

- **Field:** `NEEDS_URL: false`
  - **Meaning:** URL detected — confirm with the user, then proceed to interview

- **Field:** `LAYOUT: standard`
  - **Meaning:** Repo has `trunk/`, `branches/`, `tags/` — suggest `--stdlayout` in interview

- **Field:** `LAYOUT: custom`
  - **Meaning:** Non-standard paths — orchestrator must ask user to specify them

- **Field:** `AUTHOR_SCAN_COMPLETE`
  - **Meaning:** `true` = all committers discovered; `false` = scan failed (e.g. network timeout) — some authors may be
    missing

- **Field:** `AUTHORS`
  - **Meaning:** Comma-separated list — orchestrator offers to build `authors.txt`

## On error

- **Symptom:** `E170001: Authentication required`
  - **Likely cause:** Repo needs credentials
  - **Fix:** Add `--username <u> --password <p>` to every `svn` call

- **Symptom:** `E200009: URL does not exist`
  - **Likely cause:** Wrong URL
  - **Fix:** Confirm the URL with the user

- **Symptom:** `Cannot convert value … to type [xml]`
  - **Likely cause:** `svn` wrote an error message instead of XML
  - **Fix:** Check the raw output: `& svn info --xml $svnUrl 2>&1`

- **Symptom:** Empty authors list or `AUTHOR_SCAN_COMPLETE: false`
  - **Likely cause:** `svn log -q` timed out or failed on a large repo
  - **Fix:** The full scan failed. Increase bandwidth or run this locally to parse authors manually:

    ```powershell
    svn log --xml -q <url> |
      Select-String '<author>' |
      ForEach-Object { ($_ -replace '.*<author>(.*)</author>.*','$1').Trim() } |
      Sort-Object -Unique
    ```

- **Symptom:** `svn info` fails on a local repo folder
  - **Likely cause:** CWD is a bare SVN repository, not a checkout
  - **Fix:** Step 1b detects `format`+`db/` and builds `file:///` URL automatically
