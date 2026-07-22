# Phase 0 — Preflight + Config

## Purpose

Create the state directory, write `config.json` with all migration options, copy `lib\core.pslib` to the state directory, and run `Invoke-Preflight` to verify that `svn` can reach the repository and (optionally) that the authors file is valid. This phase loads `lib\core.pslib` from the **skill directory** — the state directory does not exist yet.

## Inputs

All values must be filled in from the user's interview answers before running:

| Variable | Description |
|----------|-------------|
| `$skillDir` | Absolute path to the `svn-to-git-migration` skill directory |
| `$svnUrl` | SVN repository URL |
| `$target` | Where the git repo will be created |
| `$stdLayout` | `$true` if the repo has `trunk/branches/tags` at root |
| `$trunk` | Custom trunk path (empty string when `$stdLayout = $true`) |
| `$branches` | Array of custom branch paths (empty array when `$stdLayout = $true`) |
| `$tags` | Array of custom tag paths (empty array when `$stdLayout = $true`) |
| `$authorsFile` | Path to `authors.txt`, or empty string if none |
| `$noMetadata` | `$true` to omit `git-svn-id` trailers |
| `$ignorePaths` | Regex string for paths to exclude, or empty |
| `$includePaths` | Regex string for paths to include (whitelist), or empty |
| `$revision` | Revision range e.g. `'1:HEAD'` |
| `$noSkipEmpty` | `$true` to keep empty commits |
| `$defaultBranch` | Name for the trunk in git (e.g. `'main'`) |
| `$tagsAsBranch` | `$true` to force all SVN tags to become branches |
| `$noCreateIgnore` | `$true` to skip `svn:ignore` → `.gitignore` conversion |
| `$encoding` | Source encoding e.g. `'windows-1252'`, or empty |

## PowerShell snippet

```powershell
$skillDir = 'C:\Users\jande\.copilot\skills\svn-to-git-migration'  # agent fills in actual path
$svnUrl   = '<SVN_URL>'
$target   = '<TARGET_PATH>'   # MUST be an absolute path — subagents run in unknown CWD
# Normalize path — remove trailing slashes and canonicalize separators (subagents run in unknown CWD)
$target = [System.IO.Path]::GetFullPath($target.TrimEnd('\/'))

# ── Guard: require absolute path ─────────────────────────────────────────────
if (-not [System.IO.Path]::IsPathRooted($target)) {
    throw "'\$target' must be an absolute path (got: '$target'). Relative paths are unreliable because subagents run in an unknown working directory. Resolve the path before passing it."
}

# Options from interview (agent fills these in):
$stdLayout      = $true      # $true or $false
$trunk          = ''         # custom trunk path, empty if stdLayout
$branches       = @()        # custom branch paths
$tags           = @()        # custom tag paths
$authorsFile    = ''         # path to authors.txt, empty if none
$noMetadata     = $false
$ignorePaths    = ''
$includePaths   = ''
$revision       = '1:HEAD'
$noSkipEmpty    = $false
$defaultBranch  = 'main'
$tagsAsBranch   = $false
$noCreateIgnore = $false     # FALSE = create .gitignore files (default); TRUE = skip creation
$encoding       = ''         # e.g. 'windows-1252' or empty

# ── Load core functions inline — bypasses ExecutionPolicy entirely ──────────
$_coreContent = [System.IO.File]::ReadAllText("$skillDir\lib\core.pslib")
. ([scriptblock]::Create($_coreContent))

$ErrorActionPreference = 'Stop'
$Script:ShaIndex = [System.Collections.Generic.Dictionary[string,
    [System.Collections.Generic.SortedDictionary[int,string]]]]::new()
$Script:Stats = New-StatsObject

# ── Create state dir ─────────────────────────────────────────────────────────
$stateDir = Join-Path $target '.svn2git'
$null = New-Item -ItemType Directory -Path $stateDir -Force

# Resolve target to absolute path (PS 5.1 compatible)
$resolvedTarget = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($target)

# ── Write config ─────────────────────────────────────────────────────────────
$config = [ordered]@{
    SvnUrl             = $svnUrl
    RepoUuid           = (Invoke-SvnXml -SvnArgs @('info', '--xml', $svnUrl)).SelectSingleNode('//repository/uuid').InnerText
    StdLayout          = [bool]$stdLayout
    Trunk              = $trunk
    Branches           = $branches
    Tags               = $tags
    AuthorsFile        = $authorsFile
    NoMetadata         = [bool]$noMetadata
    IgnorePaths        = $ignorePaths
    IncludePaths       = $includePaths
    Revision           = $revision
    NoSkipEmptyCommits = [bool]$noSkipEmpty
    DefaultBranch      = $defaultBranch
    TagsAsBranches     = [bool]$tagsAsBranch
    NoCreateIgnore     = [bool]$noCreateIgnore
    Encoding           = $encoding
    Target             = $resolvedTarget
}
$config | ConvertTo-Json -Depth 4 | Set-Content "$stateDir\config.json" -Encoding UTF8

# ── Copy scripts to state dir so later phases load from there ────────────────
Copy-Item "$skillDir\lib\core.pslib" "$stateDir\core.pslib" -Force

# ── Run preflight ─────────────────────────────────────────────────────────────
try {
    $preflight = Invoke-Preflight -SvnUrl $svnUrl -AuthorsFilePath $authorsFile `
                                  -SourceEncoding $encoding
    if (-not $preflight) { throw "Preflight checks failed." }
    Save-MigrationState -StateDir $stateDir
    Write-Host "Phase 0 complete. State dir: $stateDir"
    Write-Host "CANONICAL_STATEDIR=$stateDir"
    Write-Host "CANONICAL_TARGET=$resolvedTarget"
}
catch {
    throw
}
```

## Success check

- `config.json` exists at `$target\.svn2git\config.json`
- `core.pslib` exists at `$target\.svn2git\core.pslib`
- No `Preflight checks failed` error
- Output ends with `Phase 0 complete`

## On error

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `$target must be an absolute path` | Orchestrator passed a relative path | Resolve to absolute before passing: use the CWD returned by detect and join it with the relative target |
| `Cannot find path … core.pslib` | `$skillDir` is wrong | Verify the skill directory path; `lib\core.pslib` must exist |
| `Preflight checks failed` | SVN unreachable or authors file missing | Check SVN URL and credentials; verify `$authorsFile` path exists |
| `Access denied` creating `$stateDir` | Permissions on `$target` | Choose a different target directory or run as Administrator |
