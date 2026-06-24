#Requires -Version 7.0
<#
.SYNOPSIS
    Migrates a Subversion (SVN) repository to a standalone Git repository.

.DESCRIPTION
    Uses only the svn CLI and git plumbing commands (hash-object, write-tree,
    commit-tree, update-ref, update-index). No git-svn required.
    Target platform: Windows, PowerShell 7.0+.

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
    Requires: PowerShell 7.0+, svn CLI (any modern version), git 2.x.
    Does NOT require git-svn.
    Path filtering uses ref-root-relative paths, unlike git-svn which uses
    repo-root-relative paths. Adjust patterns accordingly.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('detect', 'run')]
    [string]$Command,

    [Parameter(Position = 1, Mandatory = $true)]
    [string]$SvnUrl,

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

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "PowerShell 7.0+ required. Install from: https://aka.ms/powershell"
    exit 1
}

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

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
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $tag = '[SVN→Git]'
    switch ($Level) {
        'WARN'  { Write-Host "$tag WARNING: $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "$tag ERROR: $Message"   -ForegroundColor Red }
        default { Write-Host "$tag $Message" }
    }
}

function Write-RevProgress {
    param(
        [int]$Rev,
        [int]$Total,
        [string]$RefName,
        [string]$Msg,
        [string]$Author
    )
    $short = $RefName -replace '^refs/(heads|tags)/', ''
    # Truncate long messages for readability
    if ($Msg.Length -gt 60) { $Msg = $Msg.Substring(0, 57) + '...' }
    Write-Host "[SVN→Git] Rev $Rev/$Total`: $short — '$Msg' ($Author)" -ForegroundColor Cyan
}

# ─────────────────────────────────────────────────────────────────────────────
# SVN HELPERS
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-Svn {
    <# Run svn, return stdout lines. Throws on non-zero exit. #>
    param([string[]]$SvnArgs)
    $out = & svn @SvnArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $err = ($out | Out-String).Trim()
        throw "svn failed [exit $LASTEXITCODE]: svn $($SvnArgs -join ' ')`n$err"
    }
    return $out
}

function Invoke-SvnXml {
    <#
    Run svn with --xml flag and return a [System.Xml.XmlDocument].
    When $SourceEncoding is set the raw stdout bytes are transcoded to UTF-8
    before XML parsing, preserving non-ASCII characters in commit messages.
    #>
    param(
        [string[]]$SvnArgs,
        [string]  $SourceEncoding = ''
    )

    if ($SourceEncoding) {
        # Capture raw bytes via ProcessStartInfo so we bypass PS's string
        # conversion which would corrupt non-UTF-8 bytes.
        $psi = [System.Diagnostics.ProcessStartInfo]::new('svn')
        # Build argument string – quote args that contain spaces
        $psi.Arguments = ($SvnArgs | ForEach-Object {
            if ($_ -match '\s') { "`"$_`"" } else { $_ }
        }) -join ' '
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        # Read as Latin-1 (1:1 byte→char) to preserve raw bytes
        $psi.StandardOutputEncoding = [System.Text.Encoding]::Latin1

        $proc = [System.Diagnostics.Process]::Start($psi)
        # Collect all stdout bytes
        $chars  = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        if ($proc.ExitCode -ne 0) {
            throw "svn failed [exit $($proc.ExitCode)]: $stderr"
        }

        # Re-encode: Latin-1 chars → bytes (lossless) → UTF-8 string
        $rawBytes  = [System.Text.Encoding]::Latin1.GetBytes($chars)
        $srcEnc    = [System.Text.Encoding]::GetEncoding($SourceEncoding)
        $utf8Bytes = [System.Text.Encoding]::Convert($srcEnc, [System.Text.Encoding]::UTF8, $rawBytes)
        $xmlStr    = [System.Text.Encoding]::UTF8.GetString($utf8Bytes)

        $doc = [System.Xml.XmlDocument]::new()
        $doc.LoadXml($xmlStr)
        return $doc
    }
    else {
        $out = & svn @SvnArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            $err = ($out | Out-String).Trim()
            throw "svn failed [exit $LASTEXITCODE]: svn $($SvnArgs -join ' ')`n$err"
        }
        $doc = [System.Xml.XmlDocument]::new()
        $doc.LoadXml(($out | Out-String).Trim())
        return $doc
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# GIT HELPERS
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-Git {
    <# Run git -C $GitDir, return trimmed stdout. Throws on non-zero exit. #>
    param(
        [string]  $GitDir,
        [string[]]$GitArgs,
        [switch]  $AllowFailure   # return $null instead of throwing
    )
    $out = & git -C $GitDir @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        $err = ($out | Out-String).Trim()
        throw "git failed [exit $LASTEXITCODE]: git $($GitArgs -join ' ')`n$err"
    }
    return ($out -join "`n").Trim()
}

function Set-GitAuthorEnv {
    param([string]$Name, [string]$Email, [string]$Date)
    $env:GIT_AUTHOR_NAME     = $Name
    $env:GIT_AUTHOR_EMAIL    = $Email
    $env:GIT_AUTHOR_DATE     = $Date
    $env:GIT_COMMITTER_NAME  = $Name
    $env:GIT_COMMITTER_EMAIL = $Email
    $env:GIT_COMMITTER_DATE  = $Date
}

function Clear-GitAuthorEnv {
    'GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_AUTHOR_DATE',
    'GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL','GIT_COMMITTER_DATE' |
        ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }
}

# ─────────────────────────────────────────────────────────────────────────────
# DATE CONVERSION
# ─────────────────────────────────────────────────────────────────────────────

function Convert-SvnDate {
    <#
    SVN XML date:  2023-04-15T10:30:00.123456Z
    git env var:   2023-04-15T10:30:00 +0000
    #>
    param([string]$SvnDate)
    try {
        $datePart = $SvnDate.Split('.')[0]   # strip microseconds
        $dt = [datetime]::ParseExact(
            $datePart,
            'yyyy-MM-ddTHH:mm:ss',
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        return $dt.ToString('yyyy-MM-ddTHH:mm:ss +0000')
    }
    catch {
        # Fallback: simple string surgery
        return ($SvnDate -replace '\.\d+Z$', ' +0000')
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# AUTHOR MAP
# ─────────────────────────────────────────────────────────────────────────────

function Import-AuthorMap {
    param([string]$FilePath)

    $map = [System.Collections.Generic.Dictionary[string, hashtable]]::new(
        [System.StringComparer]::Ordinal)

    if (-not $FilePath) { return $map }
    if (-not (Test-Path $FilePath)) {
        throw "Authors file not found: $FilePath"
    }

    $pattern = '^(.+?|\(no author\))\s*=\s*(.+?)\s*<(.*)>\s*$'
    foreach ($line in (Get-Content $FilePath -Encoding UTF8)) {
        if ($line -match $pattern) {
            $map[$Matches[1].Trim()] = @{
                Name  = $Matches[2].Trim()
                Email = $Matches[3].Trim()
            }
        }
    }
    return $map
}

function Resolve-Author {
    param(
        [string]$SvnUsername,
        [System.Collections.Generic.Dictionary[string, hashtable]]$AuthorMap,
        [string]$RepoUuid
    )
    $user = if ($SvnUsername) { $SvnUsername } else { '(no author)' }

    if ($AuthorMap.ContainsKey($user)) {
        return $AuthorMap[$user]
    }

    # Accumulate for summary report
    [void]$Script:Stats.UnmappedAuthors.Add($user)

    # Default: identical to what git-svn produces
    return @{ Name = $user; Email = "$user@$RepoUuid" }
}

# ─────────────────────────────────────────────────────────────────────────────
# SHA INDEX  (per-URL sorted map of revision → commit-SHA)
# ─────────────────────────────────────────────────────────────────────────────

function Update-ShaIndex {
    param([string]$Url, [int]$Rev, [string]$Sha)
    if (-not $Script:ShaIndex.ContainsKey($Url)) {
        $Script:ShaIndex[$Url] =
            [System.Collections.Generic.SortedDictionary[int, string]]::new()
    }
    $Script:ShaIndex[$Url][$Rev] = $Sha
}

function Get-CopyfromParentSha {
    <#
    "At-or-before" lookup: find the highest revision r in sha_index[url]
    where r ≤ copyfromRev, return its commit SHA.
    #>
    param([string]$CopyfromUrl, [int]$CopyfromRev)

    if (-not $Script:ShaIndex.ContainsKey($CopyfromUrl)) { return $null }

    $inner = $Script:ShaIndex[$CopyfromUrl]
    $keys  = $inner.Keys | Where-Object { $_ -le $CopyfromRev }
    if (-not $keys) { return $null }

    $maxRev = ($keys | Measure-Object -Maximum).Maximum
    return $inner[$maxRev]
}

# ─────────────────────────────────────────────────────────────────────────────
# PATH FILTERING  (ref-root-relative)
# ─────────────────────────────────────────────────────────────────────────────

function Test-PathIncluded {
    param([string]$RelPath, [string]$IgnorePattern, [string]$IncludePattern)
    if ($IncludePattern -and ($RelPath -notmatch $IncludePattern)) { return $false }
    if ($IgnorePattern  -and ($RelPath  -match  $IgnorePattern))  { return $false }
    return $true
}

function Remove-FilteredPaths {
    <# Delete from $StagingDir any file/dir whose relative path fails the filter. #>
    param(
        [string]$StagingDir,
        [string]$IgnorePattern,
        [string]$IncludePattern
    )
    if (-not $IgnorePattern -and -not $IncludePattern) { return }

    $base = $StagingDir.TrimEnd('\') + '\'
    Get-ChildItem -Path $StagingDir -Recurse -Force | ForEach-Object {
        $rel = $_.FullName.Substring($base.Length) -replace '\\', '/'
        if (-not (Test-PathIncluded -RelPath $rel `
                    -IgnorePattern $IgnorePattern `
                    -IncludePattern $IncludePattern)) {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# WORKING TREE HELPERS
# ─────────────────────────────────────────────────────────────────────────────

function Clear-WorkingTree {
    <# Remove everything from $GitDir except the .git folder. #>
    param([string]$GitDir)
    Get-ChildItem -Path $GitDir -Force |
        Where-Object { $_.Name -ne '.git' } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Copy-StagingToRepo {
    <# Copy staged export contents into the git working tree. #>
    param([string]$StagingDir, [string]$GitDir)
    $items = Get-ChildItem -Path $StagingDir -Force
    if (-not $items) { return }
    foreach ($item in $items) {
        $dest = Join-Path $GitDir $item.Name
        Copy-Item -Path $item.FullName -Destination $dest -Recurse -Force
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SVN:SPECIAL (SYMLINKS) — WINDOWS ONLY
# ─────────────────────────────────────────────────────────────────────────────

function Resolve-SvnSpecialFiles {
    <#
    Windows svn export produces text files with content "link <target>" for
    symlinks instead of real symlinks. Detect them and return a list of objects
    describing what needs to be staged as mode 120000.
    Returns list of [pscustomobject]@{ FileFullPath; RelPath; Target }
    #>
    param(
        [string]$StagingDir,
        [string]$RefUrl,
        [int]   $Rev
    )

    $result = [System.Collections.Generic.List[pscustomobject]]::new()
    $base   = $StagingDir.TrimEnd('\') + '\'

    $allFiles = Get-ChildItem -Path $StagingDir -Recurse -File -Force
    foreach ($f in $allFiles) {
        # Symlink placeholder files are tiny
        if ($f.Length -gt 1024) { continue }

        try   { $content = [System.IO.File]::ReadAllText($f.FullName) }
        catch { continue }

        if (-not $content.StartsWith('link ')) { continue }

        $relPath = ($f.FullName.Substring($base.Length)) -replace '\\', '/'

        # Confirm the svn:special property is actually set on this path
        $propOut = & svn propget svn:special "$RefUrl/$relPath" -r $Rev 2>&1
        if ($LASTEXITCODE -ne 0) { continue }
        $propStr = ($propOut | Out-String).Trim()
        if (-not $propStr) { continue }

        $target = $content.Substring(5).TrimEnd("`r", "`n")  # strip "link "
        $result.Add([pscustomobject]@{
            FileFullPath = $f.FullName
            RelPath      = $relPath
            Target       = $target
        })
    }
    return $result
}

function Stage-Symlinks {
    <#
    For each detected svn:special symlink:
      1. Remove the placeholder text file from the working tree.
      2. Hash the target string as a git blob.
      3. Stage it with mode 120000.
    Must be called AFTER git add -A (so the index has the placeholder) and
    BEFORE git write-tree.
    #>
    param(
        [System.Collections.Generic.List[pscustomobject]]$Symlinks,
        [string]$GitDir
    )
    foreach ($sym in $Symlinks) {
        # Remove placeholder from working tree so git add -A won't re-add it
        Remove-Item $sym.FileFullPath -Force -ErrorAction SilentlyContinue

        # Symlink blob content is just the target path (not "link <target>")
        $blobSha = ($sym.Target | & git -C $GitDir hash-object -w --stdin 2>&1)
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  Could not hash symlink blob for $($sym.RelPath)" -Level WARN
            continue
        }
        $blobSha = ($blobSha -join '').Trim()

        $cacheInfo = "120000,$blobSha,$($sym.RelPath)"
        & git -C $GitDir update-index --add --cacheinfo $cacheInfo 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  Could not stage symlink $($sym.RelPath)" -Level WARN
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SVN:EXECUTABLE — WINDOWS ONLY
# ─────────────────────────────────────────────────────────────────────────────

function Apply-ExecutableBits {
    <#
    Query all svn:executable properties under $RefUrl at $Rev, then run
    git update-index --chmod=+x for each matching file.
    Called after git add -A but before git write-tree.
    #>
    param([string]$GitDir, [string]$RefUrl, [int]$Rev)

    $propOut = & svn proplist --xml --depth infinity -r $Rev $RefUrl 2>&1
    if ($LASTEXITCODE -ne 0) { return }   # not fatal

    try {
        $propXml = [System.Xml.XmlDocument]::new()
        $propXml.LoadXml(($propOut | Out-String).Trim())
    }
    catch { return }

    $targets = $propXml.SelectNodes('//target')
    if (-not $targets) { return }

    foreach ($tgt in $targets) {
        $hasExec = $tgt.SelectNodes('property[@name="svn:executable"]').Count -gt 0
        if (-not $hasExec) { continue }

        $tgtPath = $tgt.GetAttribute('path')
        # path is relative to the queried URL; "." means the URL itself
        $relPath = $tgtPath.TrimStart('.').TrimStart('/') -replace '\\', '/'
        if (-not $relPath) { continue }

        & git -C $GitDir update-index --chmod=+x -- $relPath 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  svn:executable → +x $relPath"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# COPYFROM INFO
# ─────────────────────────────────────────────────────────────────────────────

function Get-CopyfromInfo {
    <#
    For a branch or tag URL, find the first revision (copy point) and extract
    the copyfrom-path / copyfrom-rev from the verbose log entry.
    Returns $null if not a copy, or [pscustomobject]@{CopyfromUrl; CopyfromRev}.
    #>
    param(
        [string]$RefUrl,
        [string]$RepoRoot,
        [string]$SourceEncoding
    )
    try {
        $logXml = Invoke-SvnXml `
            -SvnArgs @('log', '--xml', '--stop-on-copy', '-v', '--limit', '1',
                        '-r', '1:HEAD', $RefUrl) `
            -SourceEncoding $SourceEncoding
    }
    catch { return $null }

    $entries = $logXml.SelectNodes('//logentry')
    if ($entries.Count -eq 0) { return $null }

    $firstEntry = $entries[0]
    $paths      = $firstEntry.SelectNodes('paths/path')
    foreach ($p in $paths) {
        $cfPath = $p.GetAttribute('copyfrom-path')
        $cfRev  = $p.GetAttribute('copyfrom-rev')
        if ($cfPath -and $cfRev) {
            return [pscustomobject]@{
                CopyfromUrl = $RepoRoot.TrimEnd('/') + $cfPath
                CopyfromRev = [int]$cfRev
            }
        }
    }
    return $null
}

# ─────────────────────────────────────────────────────────────────────────────
# TAG DIRTY CHECK
# ─────────────────────────────────────────────────────────────────────────────

function Test-TagDirty {
    <#
    A tag is "dirty" if it has any revisions after its copy point.
    Returns $true if dirty, $false if clean.
    #>
    param([string]$TagUrl, [int]$FirstRev, [string]$SourceEncoding)

    $startRev = $FirstRev + 1
    try {
        $logXml = Invoke-SvnXml `
            -SvnArgs @('log', '--xml', '--stop-on-copy',
                        '-r', "${startRev}:HEAD", $TagUrl) `
            -SourceEncoding $SourceEncoding
    }
    catch { return $false }

    return ($logXml.SelectNodes('//logentry').Count -gt 0)
}

# ─────────────────────────────────────────────────────────────────────────────
# REVISION RANGE PARSING
# ─────────────────────────────────────────────────────────────────────────────

function Parse-RevisionRange {
    param([string]$RevRange)
    if ($RevRange -match '^(\d+):(\d+)$') {
        return @{ Start = [int]$Matches[1]; End = [int]$Matches[2] }
    }
    elseif ($RevRange -match '^(\d+):HEAD$') {
        return @{ Start = [int]$Matches[1]; End = [int]::MaxValue }
    }
    elseif ($RevRange -match '^\d+$') {
        $n = [int]$RevRange
        return @{ Start = $n; End = $n }
    }
    else {
        # Default 1:HEAD
        return @{ Start = 1; End = [int]::MaxValue }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 0 — PREFLIGHT
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-Preflight {
    param(
        [string]$SvnUrl,
        [string]$AuthorsFilePath,
        [string]$SourceEncoding
    )

    Write-Log '=== Phase 0: Preflight ==='
    Write-Log "Target URL: $SvnUrl"

    # 0.1 Reachability
    Write-Log 'Checking SVN reachability...'
    try {
        $infoXml = Invoke-SvnXml -SvnArgs @('info', '--xml', $SvnUrl) `
                                  -SourceEncoding $SourceEncoding
    }
    catch {
        Write-Log "Cannot reach SVN URL '$SvnUrl': $_" -Level ERROR
        return $null
    }

    $repoRoot = $infoXml.SelectSingleNode('//repository/root').InnerText
    $repoUuid = $infoXml.SelectSingleNode('//repository/uuid').InnerText
    $headRev  = [int]($infoXml.SelectSingleNode('//commit').GetAttribute('revision'))
    $startUrl = $infoXml.SelectSingleNode('//entry/url').InnerText

    Write-Log "  Repository root : $repoRoot"
    Write-Log "  Repository UUID : $repoUuid"
    Write-Log "  HEAD revision   : $headRev"
    Write-Log "  Canonical URL   : $startUrl"

    # 0.2 Encoding detection (read the XML declaration line)
    $rawFirst = (& svn info --xml $SvnUrl 2>&1 | Select-Object -First 2) -join ' '
    if ($rawFirst -match 'encoding="([^"]+)"') {
        $declaredEnc = $Matches[1]
        Write-Log "  SVN declared encoding: $declaredEnc"
        if ($declaredEnc -ine 'UTF-8' -and -not $SourceEncoding) {
            Write-Log ("SVN server reports encoding '$declaredEnc'. " +
                "Re-run with -Encoding $declaredEnc to transcode commit " +
                'messages and author names before processing.') -Level ERROR
            return $null
        }
    }

    # 0.3 Layout auto-detection
    $lsOut = & svn ls "$SvnUrl/trunk" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log '  Standard layout detected (trunk/branches/tags). Suggest: -StdLayout'
    }
    else {
        Write-Log '  No standard layout detected. Use -StdLayout or -Trunk/-Branches/-Tags, or single-path mode.'
    }

    # 0.4 Author enumeration
    Write-Log 'Enumerating unique SVN authors...'
    $foundAuthors = [System.Collections.Generic.HashSet[string]]::new()
    try {
        $logXml = Invoke-SvnXml -SvnArgs @('log', '-q', '--xml', $SvnUrl) `
                                  -SourceEncoding $SourceEncoding
        foreach ($entry in $logXml.SelectNodes('//logentry')) {
            $aNode = $entry.SelectSingleNode('author')
            $a     = if ($aNode) { $aNode.InnerText } else { '(no author)' }
            [void]$foundAuthors.Add($a)
        }
    }
    catch {
        Write-Log "Could not enumerate authors: $_" -Level WARN
    }

    Write-Log "  Unique authors ($($foundAuthors.Count)): $($foundAuthors -join ', ')"

    if ($AuthorsFilePath) {
        $authorMap = Import-AuthorMap -FilePath $AuthorsFilePath
        $unmapped  = $foundAuthors | Where-Object { -not $authorMap.ContainsKey($_) }
        if ($unmapped) {
            Write-Log 'Authors not in map (will use default email format):' -Level WARN
            foreach ($u in $unmapped) {
                Write-Log "    $u  →  $u = $u <$u@$repoUuid>" -Level WARN
            }
        }
        else {
            Write-Log '  All authors mapped.'
        }
    }
    else {
        Write-Log ('  No -AuthorsFile supplied. All authors will use default: ' +
            "name=<svn-user>, email=<svn-user>@$repoUuid") -Level WARN
    }

    # 0.5 Size estimation
    Write-Log "HEAD revision $headRev → estimated ≤ $headRev commits to process."
    if ($headRev -gt 5000) {
        Write-Log "Large repository ($headRev revisions). Migration may take a long time." -Level WARN
    }

    Write-Log '=== Preflight complete ==='
    return [pscustomobject]@{
        RepoRoot = $repoRoot
        RepoUuid = $repoUuid
        HeadRev  = $headRev
        StartUrl = $startUrl
        Authors  = $foundAuthors
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — LAYOUT / REF RESOLUTION
# ─────────────────────────────────────────────────────────────────────────────

function Resolve-Refs {
    param(
        [string]  $SvnUrl,
        [string]  $RepoRoot,
        [switch]  $UseStdLayout,
        [string]  $TrunkPath,
        [string[]]$BranchPaths,
        [string[]]$TagPaths,
        [string]  $DefaultBranch,
        [string]  $SourceEncoding
    )

    $refs = [System.Collections.Generic.List[pscustomobject]]::new()

    # Normalise layout args
    if ($UseStdLayout) {
        $TrunkPath   = 'trunk'
        $BranchPaths = @('branches')
        $TagPaths    = @('tags')
    }

    # ── Trunk / single-path ──────────────────────────────────────────────────
    if ($TrunkPath) {
        $trunkUrl = $SvnUrl.TrimEnd('/') + '/' + $TrunkPath.TrimStart('/')
        $ls = & svn ls $trunkUrl 2>&1
        if ($LASTEXITCODE -eq 0) {
            $refs.Add([pscustomobject]@{
                RefName     = "refs/heads/$DefaultBranch"
                SvnUrl      = $trunkUrl
                IsTag       = $false
                TagName     = $null
                CopyfromUrl = $null
                CopyfromRev = $null
            })
        }
        else {
            Write-Log "Trunk path not accessible: $trunkUrl" -Level WARN
        }
    }
    elseif (-not $BranchPaths -and -not $TagPaths) {
        # Single-path mode: treat the supplied URL as the one branch
        $refs.Add([pscustomobject]@{
            RefName     = "refs/heads/$DefaultBranch"
            SvnUrl      = $SvnUrl
            IsTag       = $false
            TagName     = $null
            CopyfromUrl = $null
            CopyfromRev = $null
        })
    }

    # ── Branches ─────────────────────────────────────────────────────────────
    foreach ($bp in $BranchPaths) {
        $baseUrl = $SvnUrl.TrimEnd('/') + '/' + $bp.TrimStart('/')
        $lsOut   = & svn ls --xml $baseUrl 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Branches container not accessible: $baseUrl" -Level WARN
            continue
        }
        try {
            $lsDoc = [System.Xml.XmlDocument]::new()
            $lsDoc.LoadXml(($lsOut | Out-String).Trim())
        }
        catch {
            Write-Log "Failed to parse branch listing for $baseUrl" -Level WARN
            continue
        }

        foreach ($entry in $lsDoc.SelectNodes('//entry')) {
            $name = $entry.SelectSingleNode('name').InnerText.TrimEnd('/')
            if (-not $name) { continue }
            $branchUrl = $baseUrl.TrimEnd('/') + '/' + $name
            $cf = Get-CopyfromInfo -RefUrl $branchUrl -RepoRoot $RepoRoot `
                                   -SourceEncoding $SourceEncoding
            $refs.Add([pscustomobject]@{
                RefName     = "refs/heads/$name"
                SvnUrl      = $branchUrl
                IsTag       = $false
                TagName     = $null
                CopyfromUrl = if ($cf) { $cf.CopyfromUrl } else { $null }
                CopyfromRev = if ($cf) { $cf.CopyfromRev } else { $null }
            })
        }
    }

    # ── Tags ─────────────────────────────────────────────────────────────────
    foreach ($tp in $TagPaths) {
        $baseUrl = $SvnUrl.TrimEnd('/') + '/' + $tp.TrimStart('/')
        $lsOut   = & svn ls --xml $baseUrl 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Tags container not accessible: $baseUrl" -Level WARN
            continue
        }
        try {
            $lsDoc = [System.Xml.XmlDocument]::new()
            $lsDoc.LoadXml(($lsOut | Out-String).Trim())
        }
        catch {
            Write-Log "Failed to parse tag listing for $baseUrl" -Level WARN
            continue
        }

        foreach ($entry in $lsDoc.SelectNodes('//entry')) {
            $name = $entry.SelectSingleNode('name').InnerText.TrimEnd('/')
            if (-not $name) { continue }
            $tagUrl = $baseUrl.TrimEnd('/') + '/' + $name
            $cf = Get-CopyfromInfo -RefUrl $tagUrl -RepoRoot $RepoRoot `
                                   -SourceEncoding $SourceEncoding
            $refs.Add([pscustomobject]@{
                RefName     = "refs/tags/$name"
                SvnUrl      = $tagUrl
                IsTag       = $true
                TagName     = $name
                CopyfromUrl = if ($cf) { $cf.CopyfromUrl } else { $null }
                CopyfromRev = if ($cf) { $cf.CopyfromRev } else { $null }
            })
        }
    }

    return $refs
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4–6 — PER-REF CONVERSION
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-ConvertRef {
    param(
        [pscustomobject]$Ref,
        [string]        $GitDir,
        [string]        $StagingDir,
        [string]        $RepoUuid,
        [hashtable]     $RevRange,       # @{Start;End}
        [System.Collections.Generic.Dictionary[string,hashtable]]$AuthorMap,
        [string]        $IgnorePattern,
        [string]        $IncludePattern,
        [switch]        $KeepEmpty,
        [switch]        $OmitMetadata,
        [switch]        $AllTagsAsBranches,
        [string]        $SourceEncoding
    )

    $refName = $Ref.RefName
    $refUrl  = $Ref.SvnUrl

    Write-Log "── Processing ref: $refName ($refUrl)"

    # ── 4.1 Get revision list ─────────────────────────────────────────────
    try {
        $logXml = Invoke-SvnXml `
            -SvnArgs @('log', '--xml', '--stop-on-copy', '-v',
                        '-r', '1:HEAD', $refUrl) `
            -SourceEncoding $SourceEncoding
    }
    catch {
        Write-Log "Could not get log for $refUrl`: $_" -Level WARN
        return
    }

    $allEntries = $logXml.SelectNodes('//logentry')
    if ($allEntries.Count -eq 0) {
        Write-Log "  No revisions found for $refUrl. Skipping." -Level WARN
        return
    }

    # Apply --revision filter
    $entries = $allEntries | Where-Object {
        $r = [int]$_.GetAttribute('revision')
        $r -ge $RevRange.Start -and $r -le $RevRange.End
    }
    if (-not $entries -or @($entries).Count -eq 0) {
        Write-Log "  No revisions in range $($RevRange.Start):$($RevRange.End) for $refUrl. Skipping."
        return
    }

    # Force array — Sort-Object returns a scalar for single-item input, which makes
    # $sortedEntries[0] return $null on XmlElement (no indexer). @() enforces array.
    [object[]]$sortedEntries = @(@($entries) | Sort-Object { [int]$_.GetAttribute('revision') })
    $totalRevs     = $sortedEntries.Count
    $firstRev      = [int]$sortedEntries[0].GetAttribute('revision')

    # ── Tag dirty / clean check (Phase 6) ────────────────────────────────
    $effectiveRefName = $refName
    $isCleanTag       = $false

    if ($Ref.IsTag -and -not $AllTagsAsBranches) {
        $dirty = Test-TagDirty -TagUrl $refUrl -FirstRev $firstRev `
                               -SourceEncoding $SourceEncoding
        if ($dirty) {
            $branchName       = 'tags/' + $Ref.TagName
            $effectiveRefName = "refs/heads/$branchName"
            Write-Log ("  WARNING: $($Ref.TagName) has commits after the copy point " +
                "— created as branch refs/heads/$branchName") -Level WARN
            [void]$Script:Stats.DirtyTags.Add($Ref.TagName)
        }
        else {
            $isCleanTag = $true
        }
    }
    elseif ($Ref.IsTag -and $AllTagsAsBranches) {
        $effectiveRefName = "refs/heads/tags/$($Ref.TagName)"
    }

    # ── Resolve copyfrom parent SHA (Phase 5) ────────────────────────────
    $parentSha = $null
    if ($Ref.CopyfromUrl) {
        $parentSha = Get-CopyfromParentSha -CopyfromUrl $Ref.CopyfromUrl `
                                           -CopyfromRev $Ref.CopyfromRev
        if ($parentSha) {
            Write-Log "  Copyfrom parent: $($Ref.CopyfromUrl)@$($Ref.CopyfromRev) → $($parentSha.Substring(0,8))..."
        }
        else {
            Write-Log ("  Copyfrom ref $($Ref.CopyfromUrl)@$($Ref.CopyfromRev) not in SHA index." +
                ' Creating as root commit.') -Level WARN
            [void]$Script:Stats.OrphanedBranches.Add($effectiveRefName)
        }
    }

    $revIdx          = 0
    $lastCommitSha   = $null
    $lastAuthorInfo  = $null
    $lastGitDate     = $null

    foreach ($entry in $sortedEntries) {
        $revIdx++
        $rev      = [int]$entry.GetAttribute('revision')
        $aNode    = $entry.SelectSingleNode('author')
        $svnUser  = if ($aNode) { $aNode.InnerText } else { '' }
        $svnDate  = $entry.SelectSingleNode('date').InnerText
        $msgNode  = $entry.SelectSingleNode('msg')
        $svnMsg   = if ($msgNode) { $msgNode.InnerText } else { '' }

        $authorInfo = Resolve-Author -SvnUsername $svnUser `
                                     -AuthorMap $AuthorMap `
                                     -RepoUuid $RepoUuid
        $gitDate    = Convert-SvnDate -SvnDate $svnDate

        Write-RevProgress -Rev $rev -Total $totalRevs `
                          -RefName $effectiveRefName `
                          -Msg $svnMsg -Author $svnUser

        $Script:Stats.SvnRevisions++

        # ── 4.2 Export to staging ──────────────────────────────────────
        if (Test-Path $StagingDir) {
            Remove-Item $StagingDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null

        try {
            Invoke-Svn @('export', '--force', '-r', $rev, $refUrl, $StagingDir)
        }
        catch {
            Write-Log ("svn export failed for $refUrl@$rev. Aborting.`n" +
                "URL: $refUrl`nRevision: $rev`nError: $_") -Level ERROR
            throw
        }

        # ── 4.3 Path filtering ────────────────────────────────────────
        Remove-FilteredPaths -StagingDir $StagingDir `
                             -IgnorePattern $IgnorePattern `
                             -IncludePattern $IncludePattern

        # ── 4.4 Detect svn:special BEFORE copying to working tree ─────
        # Wrap in @() so an empty list becomes an empty array, never $null
        # (PowerShell enumerates empty Generic.List to nothing → $null otherwise)
        [object[]]$symlinks = @(Resolve-SvnSpecialFiles -StagingDir $StagingDir `
                                            -RefUrl $refUrl -Rev $rev)

        # ── 4.5 Mirror into git working tree ─────────────────────────
        Clear-WorkingTree -GitDir $GitDir
        Copy-StagingToRepo -StagingDir $StagingDir -GitDir $GitDir

        # Stage all changes (handles adds, modifies, deletes)
        Invoke-Git -GitDir $GitDir -GitArgs @('add', '-A') | Out-Null

        # ── Handle svn:special: remove placeholders, stage as 120000 ──
        if ($symlinks.Count -gt 0) {
            Stage-Symlinks -Symlinks $symlinks -GitDir $GitDir
        }

        # ── Handle svn:executable (set +x on staged files) ────────────
        Apply-ExecutableBits -GitDir $GitDir -RefUrl $refUrl -Rev $rev

        # ── 4.6 Write tree + empty commit detection ───────────────────
        $newTreeSha = Invoke-Git -GitDir $GitDir -GitArgs @('write-tree')

        $headTreeSha = Invoke-Git -GitDir $GitDir `
                                  -GitArgs @('rev-parse', 'HEAD^{tree}') `
                                  -AllowFailure

        $isEmptyCommit = ($newTreeSha -eq $headTreeSha)
        if ($isEmptyCommit -and -not $KeepEmpty) {
            Write-Log "  Rev ${rev}: empty tree (same as HEAD). Skipping."
            $Script:Stats.SkippedEmpty++
            # Still index this rev pointing at whatever parentSha is
            if ($lastCommitSha) {
                Update-ShaIndex -Url $refUrl -Rev $rev -Sha $lastCommitSha
            }
            continue
        }

        # ── 4.7 Author + date env vars ────────────────────────────────
        Set-GitAuthorEnv -Name $authorInfo.Name -Email $authorInfo.Email `
                         -Date $gitDate

        # ── 4.8 Commit message (+ optional git-svn-id trailer) ────────
        $commitMsg = $svnMsg
        if (-not $OmitMetadata) {
            $commitMsg = $svnMsg.TrimEnd() + "`n`ngit-svn-id: $refUrl@$rev $RepoUuid"
        }

        # ── 4.9 Create commit object ──────────────────────────────────
        try {
            if ($parentSha) {
                $commitSha = $commitMsg | & git -C $GitDir commit-tree $newTreeSha -p $parentSha 2>&1
            }
            else {
                $commitSha = $commitMsg | & git -C $GitDir commit-tree $newTreeSha 2>&1
            }

            if ($LASTEXITCODE -ne 0) {
                $err = ($commitSha | Out-String).Trim()
                throw "git commit-tree failed: $err"
            }
            $commitSha = ($commitSha -join '').Trim()
        }
        finally {
            Clear-GitAuthorEnv
        }

        # ── 4.10 Update SHA index ─────────────────────────────────────
        Update-ShaIndex -Url $refUrl -Rev $rev -Sha $commitSha

        $parentSha      = $commitSha
        $lastCommitSha  = $commitSha
        $lastAuthorInfo = $authorInfo
        $lastGitDate    = $gitDate

        $Script:Stats.TotalCommits++
    }

    if (-not $lastCommitSha) {
        Write-Log "  No commits produced for $effectiveRefName. Ref not created." -Level WARN
        return
    }

    # ── Update git ref ────────────────────────────────────────────────────
    if ($isCleanTag -and -not $AllTagsAsBranches) {
        # Phase 6: annotated tag via tagger env vars
        Set-GitAuthorEnv -Name $lastAuthorInfo.Name -Email $lastAuthorInfo.Email `
                         -Date $lastGitDate
        try {
            & git -C $GitDir tag -a -m "SVN tag $($Ref.TagName)" `
                  --cleanup=verbatim $Ref.TagName $lastCommitSha 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Log "  git tag failed for $($Ref.TagName)" -Level WARN
            }
        }
        finally {
            Clear-GitAuthorEnv
        }
        $Script:Stats.TotalTags++
        Write-Log "  → tag $($Ref.TagName) @ $($lastCommitSha.Substring(0,8))"
    }
    else {
        Invoke-Git -GitDir $GitDir `
                   -GitArgs @('update-ref', $effectiveRefName, $lastCommitSha) | Out-Null
        $Script:Stats.TotalBranches++
        Write-Log "  → $effectiveRefName @ $($lastCommitSha.Substring(0,8))"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 7 — POST-PROCESSING
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-CreateIgnore {
    <#
    For each ref, query svn:ignore under that ref's SVN URL at HEAD,
    write .gitignore files to the git working tree, and commit.
    #>
    param(
        [System.Collections.Generic.List[pscustomobject]]$Refs,
        [string]$GitDir,
        [string]$StagingDir,
        [string]$RepoUuid,
        [System.Collections.Generic.Dictionary[string,hashtable]]$AuthorMap,
        [string]$SourceEncoding
    )

    Write-Log '── Phase 7.1: Converting svn:ignore → .gitignore'

    foreach ($ref in $Refs) {
        # Skip refs that produced no commits
        $refSha = Invoke-Git -GitDir $GitDir `
                             -GitArgs @('rev-parse', '--verify', $ref.RefName) `
                             -AllowFailure
        # Also check for effective branch name for dirty tags
        if (-not $refSha) {
            $altName = if ($ref.IsTag) { "refs/heads/tags/$($ref.TagName)" } else { $null }
            if ($altName) {
                $refSha = Invoke-Git -GitDir $GitDir `
                                     -GitArgs @('rev-parse', '--verify', $altName) `
                                     -AllowFailure
            }
        }
        if (-not $refSha) { continue }

        # Effective ref name (dirty tags become branches)
        $effectiveRef = $ref.RefName
        if ($ref.IsTag) {
            $altRef = "refs/heads/tags/$($ref.TagName)"
            $altSha = Invoke-Git -GitDir $GitDir `
                                 -GitArgs @('rev-parse', '--verify', $altRef) `
                                 -AllowFailure
            if ($altSha) { $effectiveRef = $altRef }
        }

        Write-Log "  Processing svn:ignore for $effectiveRef ($($ref.SvnUrl))"

        # Re-export HEAD of this ref to staging
        if (Test-Path $StagingDir) { Remove-Item $StagingDir -Recurse -Force }
        New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null

        try {
            Invoke-Svn @('export', '--force', $ref.SvnUrl, $StagingDir) | Out-Null
        }
        catch {
            Write-Log "  Could not export $($ref.SvnUrl) for .gitignore pass." -Level WARN
            continue
        }

        # Query svn:ignore recursively
        try {
            $ignoreXml = Invoke-SvnXml `
                -SvnArgs @('propget', 'svn:ignore', '--xml', '--depth', 'infinity',
                            $ref.SvnUrl) `
                -SourceEncoding $SourceEncoding
        }
        catch {
            Write-Log "  Could not query svn:ignore for $($ref.SvnUrl)" -Level WARN
            continue
        }

        $gitIgnoreMap = @{}   # relPath → list of patterns
        foreach ($tgt in $ignoreXml.SelectNodes('//target')) {
            $tgtPath  = $tgt.GetAttribute('path')
            $propNode = $tgt.SelectSingleNode('property[@name="svn:ignore"]')
            if (-not $propNode) { continue }
            $patterns = $propNode.InnerText -split "`n" |
                        ForEach-Object { $_.Trim() } |
                        Where-Object   { $_ -ne '' }
            if ($patterns) {
                # path="." means the root; strip leading ./ or /
                $dirKey = $tgtPath.TrimStart('.').TrimStart('/').TrimStart('\')
                $gitIgnoreMap[$dirKey] = $patterns
            }
        }

        if ($gitIgnoreMap.Count -eq 0) { continue }

        # Restore working tree to this ref's HEAD
        Clear-WorkingTree -GitDir $GitDir
        Copy-StagingToRepo -StagingDir $StagingDir -GitDir $GitDir

        # Read the current ref's HEAD into the index
        Invoke-Git -GitDir $GitDir -GitArgs @('add', '-A') | Out-Null

        $anyChange = $false
        foreach ($dir in $gitIgnoreMap.Keys) {
            $destDir = if ($dir) { Join-Path $GitDir $dir } else { $GitDir }
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            $gitIgnorePath = Join-Path $destDir '.gitignore'

            # Merge with existing .gitignore (append + deduplicate)
            $existing = @()
            if (Test-Path $gitIgnorePath) {
                $existing = Get-Content $gitIgnorePath |
                            ForEach-Object { $_.Trim() } |
                            Where-Object   { $_ -ne '' }
            }
            $merged = ($existing + $gitIgnoreMap[$dir]) | Select-Object -Unique
            $merged | Set-Content $gitIgnorePath -Encoding UTF8
            $anyChange = $true
        }

        if (-not $anyChange) { continue }

        Invoke-Git -GitDir $GitDir -GitArgs @('add', '-A') | Out-Null

        $newTreeSha = Invoke-Git -GitDir $GitDir -GitArgs @('write-tree')
        $oldTreeSha = Invoke-Git -GitDir $GitDir `
                                 -GitArgs @('rev-parse', "${effectiveRef}^{tree}") `
                                 -AllowFailure
        if ($newTreeSha -eq $oldTreeSha) { continue }

        # Use a generic bot identity for the .gitignore commit
        Set-GitAuthorEnv `
            -Name  'SVN Migration' `
            -Email "migration@$RepoUuid" `
            -Date  (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss +0000')
        try {
            $msg = 'Add .gitignore from svn:ignore'
            $newCommitSha = $msg |
                & git -C $GitDir commit-tree $newTreeSha -p $refSha 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Log "  git commit-tree failed for .gitignore on $effectiveRef" -Level WARN
                continue
            }
            $newCommitSha = ($newCommitSha -join '').Trim()
        }
        finally {
            Clear-GitAuthorEnv
        }

        Invoke-Git -GitDir $GitDir `
                   -GitArgs @('update-ref', $effectiveRef, $newCommitSha) | Out-Null
        Write-Log "  → ${effectiveRef}: added .gitignore commit $($newCommitSha.Substring(0,8))"
        $Script:Stats.TotalCommits++
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 8 — VERIFICATION SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

function Write-Summary {
    param([string]$GitDir, [string]$SvnUrl)

    $totalRefs = $Script:Stats.TotalBranches + $Script:Stats.TotalTags
    $dirtyList = if ($Script:Stats.DirtyTags.Count -gt 0) {
        $Script:Stats.DirtyTags -join ', '
    } else { '(none)' }
    $unmapList = if ($Script:Stats.UnmappedAuthors.Count -gt 0) {
        $Script:Stats.UnmappedAuthors -join ', '
    } else { '(none)' }
    $orphList  = if ($Script:Stats.OrphanedBranches.Count -gt 0) {
        $Script:Stats.OrphanedBranches -join ', '
    } else { '(none)' }

    Write-Host ''
    Write-Host '═══════════════════════════════════════════════════════' -ForegroundColor Green
    Write-Host ' Migration complete.' -ForegroundColor Green
    Write-Host "   Refs:                       $($Script:Stats.TotalBranches) branches, $($Script:Stats.TotalTags) tags"
    Write-Host "   Commits:                    $($Script:Stats.TotalCommits)"
    Write-Host "   SVN revisions processed:    $($Script:Stats.SvnRevisions)"
    Write-Host "   Skipped (empty after filter): $($Script:Stats.SkippedEmpty)"
    Write-Host "   Dirty tags → branches:      $dirtyList"
    Write-Host "   Unmapped SVN authors:        $unmapList"
    Write-Host "   Orphaned branches:           $orphList"
    Write-Host ''
    Write-Host ' Next steps:'
    Write-Host "   git remote add origin <remote-url>"
    Write-Host "   git push --all origin"
    Write-Host "   git push --tags origin"
    Write-Host ''
    Write-Host ' To strip git-svn-id trailers from all commits (irreversible):'
    Write-Host "   git filter-repo --message-callback 'return re.sub(rb""\ngit-svn-id:.*"", b"""", message)'"
    Write-Host '═══════════════════════════════════════════════════════' -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────────────────────
# PREREQUISITE CHECK
# ─────────────────────────────────────────────────────────────────────────────

function Assert-Prerequisites {
    $missing = @()
    if (-not (Get-Command svn -ErrorAction SilentlyContinue)) { $missing += 'svn' }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { $missing += 'git' }
    if ($missing) {
        Write-Log "Missing required tools: $($missing -join ', ')" -Level ERROR
        Write-Log 'Install svn (SlikSVN/TortoiseSVN) and git 2.x, ensure both are on PATH.' -Level ERROR
        exit 1
    }

    # git version check ≥ 2.x
    $gv = (& git --version 2>&1) -replace '[^\d\.]',''
    $major = [int](($gv -split '\.')[0])
    if ($major -lt 2) {
        Write-Log "git 2.x required (found: $gv)" -Level ERROR
        exit 1
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN — ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

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
