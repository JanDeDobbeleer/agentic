---
applyTo: "**/*.ps1, **/*.psm1, **/*.psd1"
---

# PowerShell

Refer to `skills/powershell/SKILL.md` for the full PowerShell coding standards.

Key rules to always apply:

- **Verb-Noun** naming with approved PS verbs (`Get-Verb`); PascalCase; singular nouns
- Use `[CmdletBinding()]` and typed, named parameters; never `Read-Host` in scripts
- Use `[switch]` for boolean flags; avoid `$true`/`$false` parameters
- Return rich objects (`PSCustomObject`), never formatted text; use `Write-Output` not `Write-Host`
- Implement `Begin`/`Process`/`End` blocks for pipeline-capable functions
- Use `SupportsShouldProcess` with appropriate `ConfirmImpact` for state-changing cmdlets
- Use `Write-Verbose`/`Write-Warning`/`Write-Error`/`throw` for the correct streams; no `Write-Host` for data
- Full cmdlet names only — no aliases (`Get-ChildItem` not `gci`, `Where-Object` not `?`)
- Include comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`, `.OUTPUTS`) on all public functions
- Indentation: 4 spaces; opening braces on same line
