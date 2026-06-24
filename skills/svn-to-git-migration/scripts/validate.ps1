#Requires -Version 7.0
<#
.SYNOPSIS
    End-to-end validation harness for migrate.ps1.

.DESCRIPTION
    Phase A  — Creates a throwaway SVN repo (r1-r8) via create_test_repo.ps1,
               or reuses an existing repo when -SvnRepoUrl is supplied.
    Phase B  — Writes an authors file (jsmith / bwilliams / svnadmin; NOT zuser).
    Phase C  — Runs three migrations:
                 Main      : --stdlayout --authors-file --revision 1:7
                 No-meta   : same + --no-metadata
                 Fallback  : --stdlayout, no authors file, --revision 1:8
    Phase D  — Evaluates 10 assertions and prints PASS/FAIL for each.

.PARAMETER SvnRepoUrl
    file:// URL of an existing test repo.  If omitted the harness creates one.

.PARAMETER WorkDir
    Scratch directory for authors file, git outputs, and exports.
    Defaults to a random subdirectory under $env:TEMP.

.PARAMETER KeepWorkDir
    Suppress deletion of WorkDir on exit (useful for post-mortem inspection).

.EXAMPLE
    pwsh -File validate.ps1
    pwsh -File validate.ps1 -SvnRepoUrl file:///C:/temp/my-repo -KeepWorkDir
#>
[CmdletBinding()]
param(
    [string]$SvnRepoUrl,
    [string]$WorkDir = (Join-Path $env:TEMP (
        "svn-validate-work-" + [System.IO.Path]::GetRandomFileName().Replace(".", "").Substring(0, 8)
    )),
    [switch]$KeepWorkDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ═══════════════════════════════════════════════════════════════════════════════
#  Constants
# ═══════════════════════════════════════════════════════════════════════════════

$SKILL_DIR      = "C:\Users\jande\.copilot\skills\svn-to-git-migration\scripts"
$MIGRATE_SCRIPT = Join-Path $SKILL_DIR "migrate.ps1"
$CREATE_SCRIPT  = Join-Path $SKILL_DIR "create_test_repo.ps1"

# ─── PATH fixup: prefer scoop SlikSVN over broken TortoiseSVN CLI ────────────
$scoopShims = Join-Path $env:USERPROFILE "scoop\shims"
if (Test-Path $scoopShims) {
    $env:PATH = "$scoopShims;" + ($env:PATH -replace [regex]::Escape("$scoopShims;"), "")
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Result tracking
# ═══════════════════════════════════════════════════════════════════════════════

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([int]$Num, [string]$Name, [bool]$Pass, [string]$Detail = "")
    $script:results.Add([PSCustomObject]@{
        Number = $Num; Name = $Name; Pass = $Pass; Detail = $Detail
    })
    $icon  = if ($Pass) { "PASS" } else { "FAIL" }
    $color = if ($Pass) { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
    $line  = "  $icon  $Num. $Name"
    if ($Detail) { $line += "  —  $Detail" }
    Write-Host $line -ForegroundColor $color
}

function Add-Skip {
    param([int]$Num, [string]$Name, [string]$Reason)
    $script:results.Add([PSCustomObject]@{
        Number = $Num; Name = $Name; Pass = $false; Detail = "SKIP: $Reason"
    })
    Write-Host "  SKIP  $Num. $Name  —  $Reason" -ForegroundColor Yellow
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Helpers
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-Git {
    # Returns [string[]] output; throws on non-zero exit only when -Strict
    param([string]$Dir, [string[]]$GitArgs, [switch]$Strict)
    $out = & git -C $Dir @GitArgs 2>&1
    if ($Strict -and $LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed (exit=$LASTEXITCODE)"
    }
    return $out
}

# Find the git commit SHA whose message contains a specific git-svn-id line
function Find-CommitBySvnId {
    param([string]$GitDir, [string]$Ref, [string]$SvnUrl, [int]$Rev)
    $pattern = "git-svn-id: $([regex]::Escape($SvnUrl))@$Rev "
    $shas = Invoke-Git $GitDir @("log", $Ref, "--format=%H")
    foreach ($sha in $shas) {
        $sha = $sha.Trim()
        if (-not $sha) { continue }
        $body = (Invoke-Git $GitDir @("log", "-1", "--format=%B", $sha)) -join "`n"
        if ($body -match $pattern) { return $sha }
    }
    return $null
}

# Run migrate.ps1 with splatted arguments; return $true on success
function Invoke-Migration {
    param([string]$Label, [string[]]$MigrateArgs)
    Write-Host "  Running migration: $Label" -ForegroundColor DarkCyan
    if (-not (Test-Path $MIGRATE_SCRIPT)) {
        Write-Warning "  migrate.ps1 not found — skipping"
        return $false
    }
    & pwsh -File $MIGRATE_SCRIPT @MigrateArgs 2>&1 |
        ForEach-Object { Write-Verbose "    [migrate] $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  Migration '$Label' exited $LASTEXITCODE"
        return $false
    }
    return $true
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Main body
# ═══════════════════════════════════════════════════════════════════════════════

try {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

    Write-Host "`n╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host   "║   SVN → Git Migration Validation Harness             ║" -ForegroundColor Cyan
    Write-Host   "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host   "  Work dir : $WorkDir"
    Write-Host   "  migrate  : $MIGRATE_SCRIPT"
    if (-not (Test-Path $MIGRATE_SCRIPT)) {
        Write-Host "  (migrate.ps1 does not exist yet — migration assertions will be FAIL)" `
            -ForegroundColor Yellow
    }

    # ── Prerequisites ─────────────────────────────────────────────────────────
    Write-Host "`n─── Prerequisites ───────────────────────────────────────────────────────"
    foreach ($tool in @("svn", "svnadmin", "git")) {
        if (Get-Command $tool -ErrorAction SilentlyContinue) {
            Write-Host "  $tool : OK"
        } else {
            throw "Required tool '$tool' not found on PATH. Install TortoiseSVN / Git."
        }
    }

    # ── Phase A: SVN repository ───────────────────────────────────────────────
    Write-Host "`n─── Phase A: SVN repository ─────────────────────────────────────────────"

    $repoUrl = if ($SvnRepoUrl) {
        Write-Host "  Using existing repo: $SvnRepoUrl"
        $SvnRepoUrl
    } else {
        Write-Host "  Creating test repo via create_test_repo.ps1 ..."
        $lines = & pwsh -File $CREATE_SCRIPT 2>&1
        if ($LASTEXITCODE -ne 0) { throw "create_test_repo.ps1 failed: $($lines -join "`n")" }
        # The script writes the file:// URL as the very last stdout line
        $url = $lines | Where-Object { $_ -like "file:///*" } | Select-Object -Last 1
        if (-not $url) { throw "create_test_repo.ps1 did not print a file:// URL.`nOutput:`n$($lines -join "`n")" }
        Write-Host "  Created: $url" -ForegroundColor Green
        $url
    }

    # Parse UUID and derive helper URLs
    [xml]$svnInfoXml = & svn info --xml $repoUrl 2>&1
    $repoUuid = $svnInfoXml.info.entry.repository.uuid
    $trunkUrl  = "$repoUrl/trunk"
    Write-Host "  UUID : $repoUuid"

    # ── Phase B: authors file ─────────────────────────────────────────────────
    Write-Host "`n─── Phase B: Authors file ───────────────────────────────────────────────"

    $authorsFile = Join-Path $WorkDir "authors.txt"
    # NOTE: zuser is intentionally absent — needed for fallback assertion #10
    @"
jsmith = Jane Smith <jane@example.com>
bwilliams = Bob Williams <bob@example.com>
svnadmin = SVN Admin <admin@example.com>
"@ | Set-Content -Path $authorsFile -Encoding UTF8
    Write-Host "  $authorsFile  (jsmith / bwilliams / svnadmin; zuser excluded)"

    # ── Phase C: migrations ───────────────────────────────────────────────────
    Write-Host "`n─── Phase C: Migrations ─────────────────────────────────────────────────"

    $gitOutMain     = Join-Path $WorkDir "git-output-main"
    $gitOutNoMeta   = Join-Path $WorkDir "git-output-nometa"
    $gitOutFallback = Join-Path $WorkDir "git-output-fallback"

    # C1 — Main migration (r1:7, with authors file, --stdlayout)
    #      r1:7 excludes the zuser commit so the authors-file check passes.
    #      Commit count on main expected: 4
    #        r1 → empty-tree first commit (no HEAD yet ⇒ not skipped by Phase 4.6)
    #        r2 → README.md
    #        r3 → src/main.c
    #        r7 → CHANGES.txt
    $mainOk = Invoke-Migration "main (r1:7, authors)" @(
        "run", $repoUrl,
        "-StdLayout",
        "-AuthorsFile", $authorsFile,
        "-Revision", "1:7",
        "-Target", $gitOutMain
    )

    # C2 — No-metadata migration (same range, same authors, adds --no-metadata)
    $noMetaOk = Invoke-Migration "no-metadata (r1:7)" @(
        "run", $repoUrl,
        "-StdLayout",
        "-AuthorsFile", $authorsFile,
        "-NoMetadata",
        "-Revision", "1:7",
        "-Target", $gitOutNoMeta
    )

    # C3 — Fallback migration (r1:8, NO authors file)
    #      Without --authors-file every author uses the default: <user>@<uuid>
    #      This is how we exercise the fallback for the unmapped zuser (r8).
    $fallbackOk = Invoke-Migration "fallback/no-authors (r1:8)" @(
        "run", $repoUrl,
        "-StdLayout",
        "-Revision", "1:8",
        "-Target", $gitOutFallback
    )

    # ── Phase D: assertions ───────────────────────────────────────────────────
    Write-Host "`n─── Phase D: Assertions ─────────────────────────────────────────────────"

    $mainGitDir     = Join-Path $gitOutMain ".git"
    $noMetaGitDir   = Join-Path $gitOutNoMeta ".git"
    $fallbackGitDir = Join-Path $gitOutFallback ".git"

    $mainAvail     = $mainOk     -and (Test-Path $mainGitDir)
    $noMetaAvail   = $noMetaOk   -and (Test-Path $noMetaGitDir)
    $fallbackAvail = $fallbackOk -and (Test-Path $fallbackGitDir)

    # ── 1. Commit count on refs/heads/main ────────────────────────────────────
    if ($mainAvail) {
        $count = [int]((Invoke-Git $gitOutMain @("rev-list", "--count", "refs/heads/main")) -join "").Trim()
        # Expected 4:
        #   r1 → first-ever commit; empty-tree SHA ≠ "" so Phase 4.6 does NOT skip it
        #   r2 → README.md
        #   r3 → src/main.c
        #   r7 → CHANGES.txt
        # Phase 7.1 (.gitignore) adds no commit because no svn:ignore is set.
        $expected = 4
        Add-Result 1 "Commit count on main" ($count -eq $expected) "expected=$expected got=$count"
    } else {
        Add-Skip 1 "Commit count on main" "main migration unavailable"
    }

    # ── 2. Author e-mail mapping ───────────────────────────────────────────────
    if ($mainAvail) {
        $emails  = Invoke-Git $gitOutMain @("log", "--format=%ae", "refs/heads/main")
        $hasJane = (@($emails | Where-Object { $_ -eq "jane@example.com"  })).Count -gt 0
        $hasBob  = (@($emails | Where-Object { $_ -eq "bob@example.com"   })).Count -gt 0
        $pass    = $hasJane -and $hasBob
        $detail  = "jane@example.com:$(if($hasJane){'✓'}else{'✗'})  bob@example.com:$(if($hasBob){'✓'}else{'✗'})"
        Add-Result 2 "Author mapping" $pass $detail
    } else {
        Add-Skip 2 "Author mapping" "main migration unavailable"
    }

    # ── 3. Branch feature-x exists ────────────────────────────────────────────
    if ($mainAvail) {
        $bl   = Invoke-Git $gitOutMain @("branch", "--list", "feature-x")
        $pass = (@($bl | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq "feature-x" })).Count -gt 0
        $detail3 = if ($pass) { "found" } else { "not found — git branch --list: '$bl'" }
        Add-Result 3 "Branch feature-x exists" $pass $detail3
    } else {
        Add-Skip 3 "Branch feature-x exists" "main migration unavailable"
    }

    # ── 4. Branch ancestry (CRITICAL) ─────────────────────────────────────────
    #
    #   branches/feature-x was created by:  svn copy trunk  (copyfrom-rev = 3)
    #   So the first git commit on feature-x must have the trunk@3 git commit as parent.
    #   git merge-base feature-x main  must equal the git commit that imported trunk@r3.
    #
    if ($mainAvail) {
        $trunk3Sha = Find-CommitBySvnId $gitOutMain "refs/heads/main" $trunkUrl 3
        if ($trunk3Sha -and $trunk3Sha -match '^[0-9a-f]{40}$') {
            $mergeBase = (Invoke-Git $gitOutMain @("merge-base", "feature-x", "main")) -join "" |
                            ForEach-Object { $_.Trim() }
            $pass = ($mergeBase -eq $trunk3Sha)
            $short = { param($s) if ($s.Length -ge 8) { $s.Substring(0,8) } else { $s } }
            Add-Result 4 "Branch ancestry (feature-x parent = trunk@3)" $pass (
                "expected=$(& $short $trunk3Sha)  merge-base=$(& $short $mergeBase)"
            )
        } else {
            Add-Result 4 "Branch ancestry" $false "could not find trunk@3 commit in main log (got: '$trunk3Sha')"
        }
    } else {
        Add-Skip 4 "Branch ancestry" "main migration unavailable"
    }

    # ── 5. Tag v1.0 exists ────────────────────────────────────────────────────
    if ($mainAvail) {
        $tl   = Invoke-Git $gitOutMain @("tag", "--list", "v1.0")
        $pass = (@($tl | Where-Object { $_.Trim() -eq "v1.0" })).Count -gt 0
        $detail5 = if ($pass) { "found" } else { "git tag --list v1.0 returned: '$tl'" }
        Add-Result 5 "Tag v1.0 exists" $pass $detail5
    } else {
        Add-Skip 5 "Tag v1.0 exists" "main migration unavailable"
    }

    # ── 6. Tag v1.0 is annotated ──────────────────────────────────────────────
    #
    #   tags/v1.0 has no commits after the svn copy (clean tag).
    #   Per Phase 6 the migration must create an annotated tag object, not a lightweight tag.
    #
    if ($mainAvail) {
        $tagType = (Invoke-Git $gitOutMain @("cat-file", "-t", "v1.0")) -join "" | ForEach-Object { $_.Trim() }
        $pass    = ($tagType -eq "tag")
        Add-Result 6 "Tag v1.0 is annotated" $pass "git cat-file -t v1.0 = '$tagType' (want 'tag')"
    } else {
        Add-Skip 6 "Tag v1.0 is annotated" "main migration unavailable"
    }

    # ── 7. git-svn-id trailer present in every commit ─────────────────────────
    if ($mainAvail) {
        $totalCommits = [int]((Invoke-Git $gitOutMain @("rev-list", "--count", "refs/heads/main")) -join "").Trim()
        # Count commits whose body contains the trailer
        $withTrailer  = [int](@(Invoke-Git $gitOutMain @(
            "log", "--format=%H", "refs/heads/main", "--grep", "git-svn-id: file:///"
        ) | Where-Object { $_ -match '^[0-9a-f]{40}$' }).Count)
        # Allow one trailer-less commit (the optional .gitignore commit from Phase 7.1)
        $pass   = ($withTrailer -ge ($totalCommits - 1)) -and ($withTrailer -gt 0)
        Add-Result 7 "git-svn-id trailer in commits" $pass "$withTrailer/$totalCommits commits have trailer"
    } else {
        Add-Skip 7 "git-svn-id trailer in commits" "main migration unavailable"
    }

    # ── 8. HEAD tree matches svn export of trunk@7 ────────────────────────────
    if ($mainAvail) {
        $exportDir   = Join-Path $WorkDir "svn-export-check"
        $gitCheckDir = Join-Path $WorkDir "git-checkout-check"
        try {
            New-Item -ItemType Directory -Path $gitCheckDir -Force | Out-Null

            # SVN export of trunk at r7 (the last trunk revision in our migration)
            & svn export -r 7 $trunkUrl $exportDir --force 2>&1 | Out-Null

            # Materialize the git HEAD into a plain directory.
            # git checkout-index reads the INDEX, not HEAD — so load HEAD into index first.
            Invoke-Git $gitOutMain @("read-tree", "HEAD") | Out-Null
            $prefix = ($gitCheckDir -replace '\\', '/') + "/"
            Invoke-Git $gitOutMain @("checkout-index", "-a", "--prefix=$prefix") | Out-Null

            # Build sorted relative-path lists
            $svnFiles = Get-ChildItem -Recurse -File $exportDir |
                ForEach-Object { $_.FullName.Substring($exportDir.Length).TrimStart('\', '/') } |
                Sort-Object

            $gitFiles = Get-ChildItem -Recurse -File $gitCheckDir |
                ForEach-Object { $_.FullName.Substring($gitCheckDir.Length).TrimStart('\', '/') } |
                Where-Object   { $_ -ne ".gitignore" } |   # gitignore may be added by Phase 7.1
                Sort-Object

            $listDiff = Compare-Object $svnFiles $gitFiles -ErrorAction SilentlyContinue

            # Content comparison for files present in both trees
            $contentMismatches = @()
            foreach ($f in ($svnFiles | Where-Object { $gitFiles -contains $_ })) {
                $svnContent = Get-Content (Join-Path $exportDir   $f) -Raw -ErrorAction SilentlyContinue
                $gitContent = Get-Content (Join-Path $gitCheckDir $f) -Raw -ErrorAction SilentlyContinue
                if ($svnContent -ne $gitContent) { $contentMismatches += $f }
            }

            $listOk    = (-not $listDiff) -or ($listDiff.Count -eq 0)
            $contentOk = $contentMismatches.Count -eq 0
            $pass      = $listOk -and $contentOk

            $detail = if (-not $listOk) {
                "File list differs: " + (($listDiff | ForEach-Object { "$($_.SideIndicator)$($_.InputObject)" }) -join "  ")
            } elseif (-not $contentOk) {
                "Content differs: $($contentMismatches -join ', ')"
            } else {
                "Trees match ($(($svnFiles).Count) files)"
            }
            Add-Result 8 "HEAD tree matches svn export of trunk@7" $pass $detail
        } finally {
            Remove-Item -Recurse -Force $exportDir   -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force $gitCheckDir -ErrorAction SilentlyContinue
        }
    } else {
        Add-Skip 8 "HEAD tree matches svn export" "main migration unavailable"
    }

    # ── 9. --no-metadata: no git-svn-id trailer ───────────────────────────────
    if ($noMetaAvail) {
        $allBodies = (Invoke-Git $gitOutNoMeta @("log", "--format=%B", "refs/heads/main")) -join "`n"
        $found     = $allBodies -match 'git-svn-id:'
        $detail9   = if ($found) { "git-svn-id: found in at least one commit message" }
                     else        { "no git-svn-id trailer found (correct)" }
        Add-Result 9 "--no-metadata: no git-svn-id in messages" (-not $found) $detail9
    } elseif (-not (Test-Path $MIGRATE_SCRIPT)) {
        Add-Skip 9 "--no-metadata variant" "migrate.ps1 not found"
    } else {
        Add-Result 9 "--no-metadata variant" $false "--no-metadata migration failed"
    }

    # ── 10. Default author fallback: zuser → zuser@<uuid> ────────────────────
    #
    #   C3 ran with no --authors-file.  Per Phase 2 of the spec, every author
    #   without a map entry gets:  name=<svn-user>  email=<svn-user>@<REPO_UUID>
    #   zuser's commit is r8 (trunk/NOTES.txt).  Verify the email in git log.
    #
    if ($fallbackAvail) {
        $emails     = Invoke-Git $gitOutFallback @("log", "--format=%ae", "refs/heads/main")
        $zuserEmail = $emails | Where-Object { $_ -match "^zuser@" } | Select-Object -First 1
        $expectedEmail = "zuser@$repoUuid"
        $pass = ($zuserEmail -and $zuserEmail.Trim() -eq $expectedEmail)
        $detail = if ($zuserEmail) {
            "got='$($zuserEmail.Trim())'  expected='$expectedEmail'"
        } else {
            "no zuser@ email found in git log (all emails: $($emails -join ', '))"
        }
        Add-Result 10 "Default author fallback (zuser@uuid)" $pass $detail
    } elseif (-not (Test-Path $MIGRATE_SCRIPT)) {
        Add-Skip 10 "Default author fallback" "migrate.ps1 not found"
    } else {
        Add-Result 10 "Default author fallback" $false "fallback migration failed"
    }

} catch {
    Write-Host "`n  ERROR in validation harness: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    # Fill any un-recorded assertions as FAIL so the summary is complete
    for ($i = $results.Count + 1; $i -le 10; $i++) {
        $results.Add([PSCustomObject]@{
            Number = $i; Name = "(not reached)"; Pass = $false
            Detail = "harness error: $($_.Exception.Message)"
        })
    }
} finally {
    if (-not $KeepWorkDir -and (Test-Path $WorkDir)) {
        Write-Host "`n  Cleaning up: $WorkDir"
        Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
    } elseif ($KeepWorkDir) {
        Write-Host "`n  Work dir retained: $WorkDir" -ForegroundColor DarkYellow
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Summary
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║   Validation Summary                                 ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan

$passCount = 0
foreach ($r in $results) {
    if ($r.Pass) { $passCount++ }
    $icon  = if ($r.Pass)                     { "PASS" }
             elseif ($r.Detail -like "SKIP:*") { "SKIP" }
             else                              { "FAIL" }
    $color = if ($r.Pass)                     { [ConsoleColor]::Green  }
             elseif ($r.Detail -like "SKIP:*") { [ConsoleColor]::Yellow }
             else                              { [ConsoleColor]::Red    }
    $line  = "$icon  $($r.Number.ToString().PadLeft(2)). $($r.Name)"
    if ($r.Detail) { $line += "  —  $($r.Detail)" }
    Write-Host $line -ForegroundColor $color
}

$total  = $results.Count
$allOk  = ($passCount -eq $total)
$color  = if ($allOk) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
Write-Host "`n  $passCount/$total assertions passed" -ForegroundColor $color

exit $(if ($allOk) { 0 } else { 1 })



