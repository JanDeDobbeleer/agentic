#Requires -Version 7.0
<#
.SYNOPSIS
    Creates a throwaway SVN test repository for validating migrate.ps1.
    Prints the file:// URL of the created repository to stdout.

.PARAMETER RepoPath
    Path where the SVN repository will be created.
    Defaults to a random subdirectory under $env:TEMP.

.EXAMPLE
    pwsh -File create_test_repo.ps1
    pwsh -File create_test_repo.ps1 -RepoPath C:\temp\my-test-repo
#>
[CmdletBinding()]
param(
    [string]$RepoPath = (Join-Path $env:TEMP (
        "svn-validate-repo-" + [System.IO.Path]::GetRandomFileName().Replace(".", "").Substring(0, 8)
    ))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── PATH fixup: prefer scoop SlikSVN over TortoiseSVN CLI when the latter ───
#     crashes (TortoiseSVN GUI-only installs lack the UCRT api-ms-win-crt DLL)
$scoopShims = Join-Path $env:USERPROFILE "scoop\shims"
if (Test-Path $scoopShims) {
    # Always prepend scoop shims to ensure SlikSVN wins over TortoiseSVN (whose
    # svnadmin.exe can crash with STATUS_INVALID_IMAGE_FORMAT due to missing UCRT DLL)
    $env:PATH = "$scoopShims;" + ($env:PATH -replace [regex]::Escape("$scoopShims;"), "")
}
# Quick sanity-check: run svnadmin; if it still crashes try the scoop shim path explicitly
$null = & svnadmin --version --quiet 2>&1
if ($LASTEXITCODE -ne 0) {
    throw ("svnadmin is not functional (exit=$LASTEXITCODE).`n" +
           "Install SlikSVN:  scoop install sliksvn  (or from https://sliksvn.com)")
}

# ─── helpers ─────────────────────────────────────────────────────────────────

function Invoke-Svn {
    param([string[]]$SvnArgs)
    $output = & svn @SvnArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "svn $($SvnArgs[0]) failed (exit=$LASTEXITCODE):`n$($output -join "`n")"
    }
    return $output
}

function Set-RevProps {
    param([string]$Url, [int]$Rev, [string]$Author, [string]$Date)
    $r = & svn propset svn:author $Author --revprop -r $Rev $Url 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to set svn:author on r${Rev}: $r" }
    $r = & svn propset svn:date   $Date   --revprop -r $Rev $Url 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to set svn:date on r${Rev}: $r" }
    Write-Verbose "  r$Rev author=$Author date=$Date"
}

# ─── Phase 1: create repo ────────────────────────────────────────────────────

Write-Host "Creating SVN repository at: $RepoPath" -ForegroundColor Cyan

& svnadmin create $RepoPath
if ($LASTEXITCODE -ne 0) { throw "svnadmin create failed" }

$repoUrl = "file:///" + ($RepoPath -replace '\\', '/')

# Allow any revprop change (needed for svn propset svn:author / svn:date)
$hookContent = "@echo off`r`nexit 0"
Set-Content -Path (Join-Path $RepoPath "hooks\pre-revprop-change.bat") `
            -Value $hookContent -Encoding ascii

Write-Host "  Hook: pre-revprop-change.bat installed"

# ─── Phase 2: revision 1 — create layout ─────────────────────────────────────

Write-Host "r1: trunk / branches / tags layout..."
Invoke-Svn @("mkdir",
    "$repoUrl/trunk",
    "$repoUrl/branches",
    "$repoUrl/tags",
    "-m", "Create layout") | Out-Null
Set-RevProps $repoUrl 1 "svnadmin" "2020-01-01T10:00:00.000000Z"

# ─── working copies ──────────────────────────────────────────────────────────

$rand       = [System.IO.Path]::GetRandomFileName().Replace(".", "").Substring(0, 8)
$wcTrunk    = Join-Path $env:TEMP "svn-validate-wc-trunk-$rand"
$wcBranch   = Join-Path $env:TEMP "svn-validate-wc-branch-$rand"

Invoke-Svn @("checkout", "$repoUrl/trunk", $wcTrunk) | Out-Null

# ─── r2: README.md → trunk ───────────────────────────────────────────────────

Write-Host "r2: trunk/README.md  (jsmith)"
Set-Content -Path (Join-Path $wcTrunk "README.md") -Value "Hello SVN" -NoNewline
Invoke-Svn @("add", (Join-Path $wcTrunk "README.md")) | Out-Null
Invoke-Svn @("commit", $wcTrunk, "-m", "Initial commit") | Out-Null
Set-RevProps $repoUrl 2 "jsmith" "2020-01-02T10:00:00.000000Z"

# ─── r3: src/main.c → trunk ──────────────────────────────────────────────────

Write-Host "r3: trunk/src/main.c  (bwilliams)"
New-Item -ItemType Directory -Path (Join-Path $wcTrunk "src") | Out-Null
Set-Content -Path (Join-Path $wcTrunk "src\main.c") `
            -Value "#include <stdio.h>`nint main(){return 0;}" -NoNewline
Invoke-Svn @("add", (Join-Path $wcTrunk "src")) | Out-Null
Invoke-Svn @("commit", $wcTrunk, "-m", "Add C source") | Out-Null
Set-RevProps $repoUrl 3 "bwilliams" "2020-01-03T10:00:00.000000Z"

# ─── r4: copy trunk → branches/feature-x ────────────────────────────────────
# Copies current trunk HEAD (= r3), so copyfrom-rev will be 3

Write-Host "r4: copy trunk → branches/feature-x  (jsmith)"
Invoke-Svn @("copy",
    "$repoUrl/trunk",
    "$repoUrl/branches/feature-x",
    "-m", "Create branch feature-x") | Out-Null
Set-RevProps $repoUrl 4 "jsmith" "2020-01-04T10:00:00.000000Z"

# ─── r5: modify src/main.c on feature-x ──────────────────────────────────────

Write-Host "r5: feature-x/src/main.c modified  (bwilliams)"
Invoke-Svn @("checkout", "$repoUrl/branches/feature-x", $wcBranch) | Out-Null
Set-Content -Path (Join-Path $wcBranch "src\main.c") `
            -Value "#include <stdio.h>`n#include <stdlib.h>`nint main(){return 0;}" -NoNewline
Invoke-Svn @("commit", $wcBranch, "-m", "Branch change") | Out-Null
Set-RevProps $repoUrl 5 "bwilliams" "2020-01-05T10:00:00.000000Z"

# ─── r6: clean tag — copy trunk@3 → tags/v1.0 ────────────────────────────────
# Explicitly pinned to r3 so copyfrom-rev=3 and tag is "clean" (no post-copy commits)

Write-Host "r6: copy trunk@3 → tags/v1.0  (jsmith)"
Invoke-Svn @("copy",
    "$repoUrl/trunk@3",
    "$repoUrl/tags/v1.0",
    "-m", "Tag v1.0") | Out-Null
Set-RevProps $repoUrl 6 "jsmith" "2020-01-06T10:00:00.000000Z"

# ─── r7: CHANGES.txt → trunk ─────────────────────────────────────────────────

Write-Host "r7: trunk/CHANGES.txt  (jsmith)"
Invoke-Svn @("update", $wcTrunk) | Out-Null
Set-Content -Path (Join-Path $wcTrunk "CHANGES.txt") -Value "v1.0 - Initial release" -NoNewline
Invoke-Svn @("add", (Join-Path $wcTrunk "CHANGES.txt")) | Out-Null
Invoke-Svn @("commit", $wcTrunk, "-m", "Post-tag trunk commit") | Out-Null
Set-RevProps $repoUrl 7 "jsmith" "2020-01-07T10:00:00.000000Z"

# ─── r8: NOTES.txt → trunk by zuser ─────────────────────────────────────────
# Not in the main authors file — used by assertion #10 to test author fallback

Write-Host "r8: trunk/NOTES.txt  (zuser — unmapped author)"
Invoke-Svn @("update", $wcTrunk) | Out-Null
Set-Content -Path (Join-Path $wcTrunk "NOTES.txt") -Value "Maintenance notes" -NoNewline
Invoke-Svn @("add", (Join-Path $wcTrunk "NOTES.txt")) | Out-Null
Invoke-Svn @("commit", $wcTrunk, "-m", "Add maintenance notes") | Out-Null
Set-RevProps $repoUrl 8 "zuser" "2020-01-08T10:00:00.000000Z"

# ─── cleanup working copies ──────────────────────────────────────────────────

Remove-Item -Recurse -Force $wcTrunk  -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $wcBranch -ErrorAction SilentlyContinue

# ─── final summary ───────────────────────────────────────────────────────────

Write-Host "`nRepository ready. Revision log:" -ForegroundColor Green
try {
    [xml]$logXml = Invoke-Svn @("log", "--xml", "-q", $repoUrl)
    foreach ($entry in $logXml.log.logentry) {
        $date = if ($entry.date) { $entry.date.Substring(0, 10) } else { "?" }
        Write-Host "  r$($entry.revision)  author=$($entry.author)  ($date)"
    }
} catch {
    Write-Host "  (could not parse revision log: $_)" -ForegroundColor DarkGray
}

Write-Host ""

# stdout: just the URL (consumed by validate.ps1)
Write-Output $repoUrl
