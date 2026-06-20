#Requires -Version 5.1
<#
.SYNOPSIS
  Scan VCC-registered Unity projects for duplicate package registrations
  that crash VCC with "An item with the same key has already been added".

.DESCRIPTION
  Read-only. For each project (from VCC settings.json or -ProjectPath):
    - Parses Packages/vpm-manifest.json (locked + dependencies)
    - Parses Packages/manifest.json     (UPM dependencies)
    - Walks  Packages/<dir>/package.json (embedded), keyed by the "name" field
  Flags:
    [DUP-JSON-KEY]   a JSON file literally contains the same key twice
                     (ConvertFrom-Json throws on this; now surfaced correctly)
    [DUP-CROSS]      same package across different source kinds (excluding the
                     normal vpm+embedded install pattern)
    [DUP-EMBEDDED]   same package "name" found in 2+ embedded folders
                     (the case that crashes VCC, regardless of folder names)
    [NAME-MISMATCH]  folder name != package.json "name" (informational; this is
                     how a stray folder can shadow a real package)
    [PARSE-ERROR]    other JSON parse failures

.PARAMETER SettingsPath  Path to VCC settings.json. Auto-detected if omitted.
.PARAMETER ProjectPath   One or more project paths to scan instead of settings.

.EXAMPLE
  .\Scan-VccDuplicates.ps1
  .\Scan-VccDuplicates.ps1 -ProjectPath 'D:\UnityProjects\MyAvatarProject'
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string[]]$ProjectPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VccDuplicates.Common.ps1')

$settingsFile = Resolve-VccSettingsPath -Override $SettingsPath
$projects     = Get-VccProjectList -Override $ProjectPath -SettingsFile $settingsFile

if ($settingsFile) { Write-Host "VCC settings : $settingsFile" -ForegroundColor Cyan }
Write-Host "Projects     : $($projects.Count)" -ForegroundColor Cyan
Write-Host ""

$total = 0
foreach ($proj in $projects) {
    $scan = Get-VccProjectScan -Project $proj

    if (-not $scan.Exists)      { Write-Host "[MISS] $proj" -ForegroundColor DarkYellow; continue }
    if (-not $scan.HasPackages) { Write-Host "[SKIP] $proj  (no Packages/)" -ForegroundColor DarkYellow; continue }

    $issues = Find-VccDuplicateIssues -Scan $scan
    $clean  = ($issues.Count -eq 0 -and $scan.DupKeyFiles.Count -eq 0 -and
               $scan.NameMismatch.Count -eq 0 -and $scan.ParseErrors.Count -eq 0)
    if ($clean) { Write-Host "[OK]   $proj" -ForegroundColor Green; continue }

    Write-Host "[CHK]  $proj" -ForegroundColor Yellow

    foreach ($df in $scan.DupKeyFiles) {
        $total++
        Write-Host "  [DUP-JSON-KEY]  $($df.File)  ->  key '$($df.Key)'" -ForegroundColor Red
    }
    foreach ($iss in $issues) {
        $total++
        Write-Host "  [$($iss.Severity)] $($iss.Package)" -ForegroundColor Red
        foreach ($e in $iss.Entries) {
            $v = if ($e.Version) { "  v=$($e.Version)" } else { '' }
            Write-Host "      - [$($e.Kind)] $($e.Source)$v"
        }
    }
    foreach ($nm in $scan.NameMismatch) { Write-Host "  [NAME-MISMATCH] $nm" -ForegroundColor DarkYellow }
    foreach ($pe in $scan.ParseErrors)  { Write-Host "  [PARSE-ERROR]   $pe" -ForegroundColor DarkYellow }
}

Write-Host ""
if ($total -gt 0) {
    Write-Host "Duplicate issues: $total  (read-only; no files modified)" -ForegroundColor Red
    Write-Host "Run .\Fix-VccDuplicates.ps1 (dry-run) to preview auto-quarantine." -ForegroundColor Yellow
} else {
    Write-Host "No duplicate package issues detected." -ForegroundColor Green
}
