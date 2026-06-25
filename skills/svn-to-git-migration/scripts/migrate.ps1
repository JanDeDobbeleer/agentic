#Requires -Version 5.1
<#
.SYNOPSIS
    Migrates a Subversion (SVN) repository to a standalone Git repository.

.DESCRIPTION
    Uses only the svn CLI and git plumbing commands (hash-object, write-tree,
    commit-tree, update-ref, update-index). No git-svn required.
    Target platform: Windows, Windows PowerShell 5.1+ or PowerShell 7+.

    Subcommands
      detect  Run Phase 0 preflight only and print a report.
      run     Perform the full migration (Phases 1–8).

.PARAMETER Command
    'detect' or 'run'.

.PARAMETER SvnUrl
    Full URL of the SVN repository or path to migrate.
    Example: https://svn.example.com/repos/myrepo

.PARAMETER StdLayout
    Assume standard trunk/branches/tags layout. Short alias: -s

.PARAMETER Trunk
    Custom trunk path relative to SvnUrl (e.g. 'trunk' or 'main-line').
    Short alias: -T

.PARAMETER Branches
    One or more custom branches container paths (e.g. 'branches').
    Repeatable. Short alias: -b

.PARAMETER Tags
    One or more custom tags container paths (e.g. 'tags').
    Repeatable. Short alias: -t

.PARAMETER AuthorsFile
    Path to an authors map file in git-svn format:
      svn-username = Full Name <email@example.com>
    Short alias: -A

.PARAMETER NoMetadata
    Omit the git-svn-id trailer from every commit message.

.PARAMETER IgnorePaths
    .NET regex matched against ref-root-relative paths. Matching paths are
    excluded from every commit.

.PARAMETER IncludePaths
    .NET regex matched against ref-root-relative paths. Only matching paths
    are included; all others are excluded.

.PARAMETER Revision
    Revision range to process: a single number (N) or a range (N:M).
    Default: 1:HEAD

.PARAMETER NoSkipEmptyCommits
    By default commits whose tree is identical to the previous commit are
    dropped. Use this flag to keep them (useful to preserve SVN revision
    numbers in git-svn-id trailers).

.PARAMETER DefaultBranch
    Name of the git default branch. Default: main

.PARAMETER TagsAsBranches
    Convert all SVN tags to git branches regardless of dirtiness.

.PARAMETER NoCreateIgnore
    Disable the svn:ignore → .gitignore conversion (Phase 7.1).
    By default .gitignore files are generated and committed.

.PARAMETER Encoding
    Source encoding of SVN commit messages and author names, e.g.
    windows-1252. Required when the SVN server declares a non-UTF-8
    encoding.

.PARAMETER Target
    Output git repository directory.
    Default: .\<last-segment-of-SvnUrl>

.EXAMPLE
    .\migrate.ps1 detect https://svn.example.com/repos/myrepo

.EXAMPLE
    .\migrate.ps1 run https://svn.example.com/repos/myrepo `
        -StdLayout -AuthorsFile .\authors.txt -Target C:\repos\myrepo-git

.EXAMPLE
    .\migrate.ps1 run https://svn.example.com/repos/myrepo `
        -Trunk trunk -Branches branches -Tags tags `
        -AuthorsFile .\authors.txt -Encoding windows-1252

.NOTES
    Requires: Windows PowerShell 5.1+ or PowerShell 7+, svn CLI (any modern version), git 2.x.
    Does NOT require git-svn.
    Path filtering uses ref-root-relative paths, unlike git-svn which uses
    repo-root-relative paths. Adjust patterns accordingly.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('detect', 'run', 'phase')]
    [string]$Command,

    # Not mandatory so 'phase' subcommand only needs -Target and -Phase
    [Parameter(Position = 1)]
    [string]$SvnUrl = '',

    # Used with the 'phase' subcommand to select which phase to run (0–8)
    [int]$Phase = -1,

    [Alias('s')]
    [switch]$StdLayout,

    [Alias('T')]
    [string]$Trunk,

    [Alias('b')]
    [string[]]$Branches = @(),

    [string[]]$Tags = @(),

    [Alias('A')]
    [string]$AuthorsFile,

    [switch]$NoMetadata,

    [string]$IgnorePaths,

    [string]$IncludePaths,

    [Alias('r')]
    [string]$Revision = '1:HEAD',

    [switch]$NoSkipEmptyCommits,

    [string]$DefaultBranch = 'main',

    [switch]$TagsAsBranches,

    [switch]$NoCreateIgnore,

    [string]$Encoding,

    [string]$Target
)

# ─────────────────────────────────────────────────────────────────────────────
# RUNTIME GUARDS
# ─────────────────────────────────────────────────────────────────────────────

$v = $PSVersionTable.PSVersion
if ($v.Major -lt 5 -or ($v.Major -eq 5 -and $v.Minor -lt 1)) {
    Write-Error "Windows PowerShell 5.1 or PowerShell 7+ required. Install from: https://aka.ms/powershell"
    exit 1
}

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0   # 3.0 is valid in PS 5.1+

# ─────────────────────────────────────────────────────────────────────────────
# SCRIPT-SCOPE STATE
# ─────────────────────────────────────────────────────────────────────────────

# Outer key: canonical SVN URL. Inner: SortedDictionary[revision → commit-SHA].
$Script:ShaIndex = [System.Collections.Generic.Dictionary[
    string,
    System.Collections.Generic.SortedDictionary[int, string]]]::new()

$Script:Stats = [pscustomobject]@{
    TotalBranches    = 0
    TotalTags        = 0
    TotalCommits     = 0
    SvnRevisions     = 0
    SkippedEmpty     = 0
    DirtyTags        = [System.Collections.Generic.List[string]]::new()
    UnmappedAuthors  = [System.Collections.Generic.HashSet[string]]::new()
    OrphanedBranches = [System.Collections.Generic.List[string]]::new()
}

# ─────────────────────────────────────────────────────────────────────────────
# LOAD HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

. "$PSScriptRoot\_migrate.core.ps1"

# ─────────────────────────────────────────────────────────────────────────────
# MAIN — ENTRY POINT (wrapped so dot-sourcing this file has no side effects)
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-Main {

    Assert-Prerequisites

    # Resolve --Target default
    if (-not $Target) {
        $lastSeg = ($SvnUrl.TrimEnd('/') -split '/')[-1]
        $Target  = Join-Path (Get-Location) $lastSeg
    }
    $Target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Target)

    # Parse --revision range
    $revRange = Parse-RevisionRange -RevRange $Revision

    # ── DETECT subcommand ────────────────────────────────────────────────────────
    if ($Command -eq 'detect') {
        $preflight = Invoke-Preflight -SvnUrl       $SvnUrl `
                                      -AuthorsFilePath $AuthorsFile `
                                      -SourceEncoding  $Encoding
        exit $(if ($preflight) { 0 } else { 1 })
    }

    # ── RUN subcommand ───────────────────────────────────────────────────────────

    Write-Log "=== SVN → Git Migration ==="
    Write-Log "Source : $SvnUrl"
    Write-Log "Target : $Target"

    # Phase 0 — Preflight
    $preflight = Invoke-Preflight -SvnUrl        $SvnUrl `
                                   -AuthorsFilePath $AuthorsFile `
                                   -SourceEncoding  $Encoding
    if (-not $preflight) { exit 1 }

    $repoRoot = $preflight.RepoRoot
    $repoUuid = $preflight.RepoUuid

    # Phase 2 — Author map
    $authorMap = Import-AuthorMap -FilePath $AuthorsFile

    # Phase 3 — Layout / ref resolution
    Write-Log '=== Phase 3: Resolving SVN refs ==='
    $refs = Resolve-Refs `
        -SvnUrl        $SvnUrl `
        -RepoRoot      $repoRoot `
        -UseStdLayout  $StdLayout `
        -TrunkPath     $Trunk `
        -BranchPaths   $Branches `
        -TagPaths      $Tags `
        -DefaultBranch $DefaultBranch `
        -SourceEncoding $Encoding

    if ($refs.Count -eq 0) {
        Write-Log 'No refs to process. Check your layout flags.' -Level ERROR
        exit 1
    }

    Write-Log "Refs to process: $($refs.Count)"
    foreach ($r in $refs) {
        Write-Log "  $($r.RefName)  →  $($r.SvnUrl)"
    }

    # Phase 1 — Initialise git repository
    Write-Log '=== Phase 1: Initialising git repository ==='
    if (Test-Path $Target) {
        # Allow re-running into an existing (perhaps partially migrated) directory
        if (-not (Test-Path (Join-Path $Target '.git'))) {
            Write-Log "Target '$Target' exists but is not a git repo. Aborting." -Level ERROR
            exit 1
        }
        Write-Log "  Reusing existing git repo at $Target" -Level WARN
    }
    else {
        Invoke-Git -GitDir (Split-Path $Target) `
                   -GitArgs @('init', "--initial-branch=$DefaultBranch", $Target) | Out-Null
    }
    Invoke-Git -GitDir $Target -GitArgs @('config', 'core.autocrlf', 'false') | Out-Null

    # Create temp directory for staging exports
    $tempBase    = Join-Path ([System.IO.Path]::GetTempPath()) "svn2git_$(Get-Random)"
    $stagingDir  = Join-Path $tempBase 'staging'
    New-Item -ItemType Directory -Path $tempBase -Force | Out-Null

    try {
        # Phase 4–6 — Per-ref conversion (trunk first, then branches, then tags)
        Write-Log '=== Phases 4–6: Converting SVN revisions to git commits ==='

        # Sort: trunk first (not a tag), then non-tag branches, then tags
        $sortedRefs = $refs | Sort-Object {
            if (-not $_.IsTag -and $_.RefName -eq "refs/heads/$DefaultBranch") { 0 }
            elseif (-not $_.IsTag) { 1 }
            else { 2 }
        }

        foreach ($ref in $sortedRefs) {
            Invoke-ConvertRef `
                -Ref               $ref `
                -GitDir            $Target `
                -StagingDir        $stagingDir `
                -RepoUuid          $repoUuid `
                -RevRange          $revRange `
                -AuthorMap         $authorMap `
                -IgnorePattern     $IgnorePaths `
                -IncludePattern    $IncludePaths `
                -KeepEmpty:        $NoSkipEmptyCommits `
                -OmitMetadata:     $NoMetadata `
                -AllTagsAsBranches:$TagsAsBranches `
                -SourceEncoding    $Encoding
        }

        # Phase 7.1 — svn:ignore → .gitignore
        if (-not $NoCreateIgnore) {
            Write-Log '=== Phase 7: Post-processing ==='
            Invoke-CreateIgnore `
                -Refs           $refs `
                -GitDir         $Target `
                -StagingDir     $stagingDir `
                -RepoUuid       $repoUuid `
                -AuthorMap      $authorMap `
                -SourceEncoding $Encoding
        }

        # Phase 7.2 — Set default branch
        Write-Log "── Phase 7.2: Setting default branch to $DefaultBranch"
        Invoke-Git -GitDir $Target `
                   -GitArgs @('symbolic-ref', 'HEAD', "refs/heads/$DefaultBranch") | Out-Null

        # Phase 7.3 — gc
        Write-Log '── Phase 7.3: Running git gc --aggressive --prune=now'
        & git -C $Target gc --aggressive --prune=now 2>&1 | Out-Null

        # Phase 8 — Summary
        Write-Summary -GitDir $Target -SvnUrl $SvnUrl
    }
    finally {
        # Clean up temp directory
        if (Test-Path $tempBase) {
            Remove-Item $tempBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE SUBCOMMAND — per-phase execution with state persistence
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-PhaseCommand {
    if (-not $Target) {
        Write-Error "The 'phase' subcommand requires -Target <path>."
        exit 1
    }
    if ($Phase -lt 0) {
        Write-Error "The 'phase' subcommand requires -Phase <0-8>."
        exit 1
    }

    $stateDir = Join-Path $Target '.svn2git'
    $configPath = Join-Path $stateDir 'config.json'

    if ($Phase -eq 0) {
        # Phase 0 — write config and run preflight
        if (-not $SvnUrl) {
            Write-Error "Phase 0 requires -SvnUrl."
            exit 1
        }

        Assert-Prerequisites

        # Resolve Target to absolute path
        $resolvedTarget = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Target)

        # Save config so later phases can restore all options from just -Target
        $null = New-Item -ItemType Directory -Path $stateDir -Force
        $config = [ordered]@{
            SvnUrl              = $SvnUrl
            StdLayout           = [bool]$StdLayout
            Trunk               = $Trunk
            Branches            = $Branches
            Tags                = $Tags
            AuthorsFile         = $AuthorsFile
            NoMetadata          = [bool]$NoMetadata
            IgnorePaths         = $IgnorePaths
            IncludePaths        = $IncludePaths
            Revision            = $Revision
            NoSkipEmptyCommits  = [bool]$NoSkipEmptyCommits
            DefaultBranch       = $DefaultBranch
            TagsAsBranches      = [bool]$TagsAsBranches
            NoCreateIgnore      = [bool]$NoCreateIgnore
            Encoding            = $Encoding
            Target              = $resolvedTarget
        }
        $config | ConvertTo-Json -Depth 4 | Set-Content $configPath -Encoding UTF8

        # Copy scripts to state dir so snippets can reference them there
        Copy-Item -Path "$PSScriptRoot\migrate.ps1"        -Destination $stateDir -Force
        Copy-Item -Path "$PSScriptRoot\_migrate.core.ps1"  -Destination $stateDir -Force

        Write-Log "Phase 0: Config saved to $configPath"
        $preflight = Invoke-Preflight -SvnUrl $SvnUrl -AuthorsFilePath $AuthorsFile `
                                      -SourceEncoding $Encoding
        if (-not $preflight) { exit 1 }
        Save-MigrationState -StateDir $stateDir
        Write-Log "Phase 0 complete. Run phase 1 next: migrate.ps1 phase -Phase 1 -Target '$resolvedTarget'"
        return
    }

    # Phases 1–8: load config + state
    if (-not (Test-Path $configPath)) {
        Write-Error "No config found at $configPath. Run phase 0 first."
        exit 1
    }
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    # Restore params from config (script-scope so Invoke-* functions can read them)
    $Script:_SvnUrl             = $cfg.SvnUrl
    $Script:_StdLayout          = [bool]$cfg.StdLayout
    $Script:_Trunk              = $cfg.Trunk
    $Script:_Branches           = @($cfg.Branches)
    $Script:_Tags               = @($cfg.Tags)
    $Script:_AuthorsFile        = $cfg.AuthorsFile
    $Script:_NoMetadata         = [bool]$cfg.NoMetadata
    $Script:_IgnorePaths        = $cfg.IgnorePaths
    $Script:_IncludePaths       = $cfg.IncludePaths
    $Script:_Revision           = $cfg.Revision
    $Script:_NoSkipEmpty        = [bool]$cfg.NoSkipEmptyCommits
    $Script:_DefaultBranch      = $cfg.DefaultBranch
    $Script:_TagsAsBranches     = [bool]$cfg.TagsAsBranches
    $Script:_NoCreateIgnore     = [bool]$cfg.NoCreateIgnore
    $Script:_Encoding           = $cfg.Encoding
    $resolvedTarget             = $cfg.Target

    Assert-Prerequisites
    Import-MigrationState -StateDir $stateDir

    try {
        switch ($Phase) {
            1 {
                Write-Log '=== Phase 1: Initialising git repository ==='
                if (Test-Path $resolvedTarget) {
                    if (-not (Test-Path (Join-Path $resolvedTarget '.git'))) {
                        Write-Log "Target '$resolvedTarget' exists but is not a git repo. Aborting." -Level ERROR
                        exit 1
                    }
                    Write-Log "  Reusing existing git repo at $resolvedTarget" -Level WARN
                } else {
                    Invoke-Git -GitDir (Split-Path $resolvedTarget) `
                               -GitArgs @('init', "--initial-branch=$($Script:_DefaultBranch)", $resolvedTarget) | Out-Null
                }
                Invoke-Git -GitDir $resolvedTarget -GitArgs @('config', 'core.autocrlf', 'false') | Out-Null
                Write-Log "Phase 1 complete."
            }
            2 {
                Write-Log '=== Phase 2: Loading author map ==='
                $authorMap = Import-AuthorMap -FilePath $Script:_AuthorsFile
                Write-Log "Author map loaded ($($authorMap.Count) entries)."
            }
            3 {
                Write-Log '=== Phase 3: Resolving SVN refs ==='
                $refs = Resolve-Refs `
                    -SvnUrl         $Script:_SvnUrl `
                    -RepoRoot       (Invoke-SvnXml -SvnArgs @('info','--xml',$Script:_SvnUrl)).SelectSingleNode('//repository/root').InnerText `
                    -UseStdLayout:  ([switch]$Script:_StdLayout) `
                    -TrunkPath      $Script:_Trunk `
                    -BranchPaths    $Script:_Branches `
                    -TagPaths       $Script:_Tags `
                    -DefaultBranch  $Script:_DefaultBranch `
                    -SourceEncoding $Script:_Encoding
                $refs | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $stateDir 'refs.json') -Encoding UTF8
                Write-Log "Phase 3 complete. $($refs.Count) refs resolved."
            }
            { $_ -in 4,5,6 } {
                Write-Log "=== Phases 4–6: Converting SVN revisions ==="
                $refsJson = Get-Content (Join-Path $stateDir 'refs.json') -Raw | ConvertFrom-Json
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
                $infoXml  = Invoke-SvnXml -SvnArgs @('info','--xml',$Script:_SvnUrl)
                $repoUuid = $infoXml.SelectSingleNode('//repository/uuid').InnerText
                $revRange = Parse-RevisionRange -RevRange $Script:_Revision
                $authorMap = Import-AuthorMap -FilePath $Script:_AuthorsFile

                $tempBase   = Join-Path ([System.IO.Path]::GetTempPath()) "svn2git_$(Get-Random)"
                $stagingDir = Join-Path $tempBase 'staging'
                New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
                try {
                    $sortedRefs = $refs | Sort-Object {
                        if (-not $_.IsTag -and $_.RefName -eq "refs/heads/$($Script:_DefaultBranch)") { 0 }
                        elseif (-not $_.IsTag) { 1 }
                        else { 2 }
                    }
                    foreach ($ref in $sortedRefs) {
                        Invoke-ConvertRef `
                            -Ref               $ref `
                            -GitDir            $resolvedTarget `
                            -StagingDir        $stagingDir `
                            -RepoUuid          $repoUuid `
                            -RevRange          $revRange `
                            -AuthorMap         $authorMap `
                            -IgnorePattern     $Script:_IgnorePaths `
                            -IncludePattern    $Script:_IncludePaths `
                            -KeepEmpty:        ([switch]$Script:_NoSkipEmpty) `
                            -OmitMetadata:     ([switch]$Script:_NoMetadata) `
                            -AllTagsAsBranches:([switch]$Script:_TagsAsBranches) `
                            -SourceEncoding    $Script:_Encoding
                    }
                } finally {
                    if (Test-Path $tempBase) { Remove-Item $tempBase -Recurse -Force -ErrorAction SilentlyContinue }
                }
                Write-Log "Phases 4–6 complete."
            }
            7 {
                Write-Log '=== Phase 7: Post-processing ==='
                $refsJson = Get-Content (Join-Path $stateDir 'refs.json') -Raw | ConvertFrom-Json
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
                $infoXml  = Invoke-SvnXml -SvnArgs @('info','--xml',$Script:_SvnUrl)
                $repoUuid = $infoXml.SelectSingleNode('//repository/uuid').InnerText
                $authorMap = Import-AuthorMap -FilePath $Script:_AuthorsFile
                $tempBase   = Join-Path ([System.IO.Path]::GetTempPath()) "svn2git_$(Get-Random)"
                $stagingDir = Join-Path $tempBase 'staging'
                New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
                try {
                    if (-not $Script:_NoCreateIgnore) {
                        Invoke-CreateIgnore -Refs $refs -GitDir $resolvedTarget `
                            -StagingDir $stagingDir -RepoUuid $repoUuid `
                            -AuthorMap $authorMap -SourceEncoding $Script:_Encoding
                    }
                    Write-Log "── Phase 7.2: Setting default branch to $($Script:_DefaultBranch)"
                    Invoke-Git -GitDir $resolvedTarget `
                               -GitArgs @('symbolic-ref','HEAD',"refs/heads/$($Script:_DefaultBranch)") | Out-Null
                    Write-Log '── Phase 7.3: Running git gc --aggressive --prune=now'
                    & git -C $resolvedTarget gc --aggressive --prune=now 2>&1 | Out-Null
                } finally {
                    if (Test-Path $tempBase) { Remove-Item $tempBase -Recurse -Force -ErrorAction SilentlyContinue }
                }
                Write-Log "Phase 7 complete."
            }
            8 {
                Write-Log '=== Phase 8: Summary ==='
                Write-Summary -GitDir $resolvedTarget -SvnUrl $Script:_SvnUrl
            }
            default {
                Write-Error "Unknown phase $Phase. Valid values: 0–8."
                exit 1
            }
        }
    }
    finally {
        Save-MigrationState -StateDir $stateDir
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# TOP-LEVEL DISPATCHER
# ─────────────────────────────────────────────────────────────────────────────

switch ($Command) {
    'detect' { Invoke-Main }
    'run'    { Invoke-Main }
    'phase'  { Invoke-PhaseCommand }
}