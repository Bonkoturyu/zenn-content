#Requires -Version 5.1
<#
.SYNOPSIS
  Quarantine duplicate embedded package folders that crash VCC
  ("An item with the same key has already been added").

.DESCRIPTION
  NAME-BASED detection (not folder-name patterns). For each project, finds any
  package "name" that exists in 2+ embedded folders. The folder whose name
  equals the package name is treated as CANONICAL and kept; the others are
  candidates for quarantine.

  Safety rules:
    - A non-canonical folder is moved only if its "version" matches the
      canonical folder's version (a true duplicate). Otherwise -> KEEP (manual).
    - If no folder matches the package name (no clear canonical) -> AMBIGUOUS
      (manual). The script never guesses which copy to remove.
    - Folders are MOVED to a quarantine dir OUTSIDE the Unity project (a sibling
      directory, same volume) so neither Unity nor the project's git sees them.
    - Default is dry-run. Pass -Apply to actually move.

.PARAMETER SettingsPath    Path to VCC settings.json. Auto-detected if omitted.
.PARAMETER ProjectPath     One or more project paths instead of settings.
.PARAMETER Apply           Actually move. Without it, report only (dry-run).
.PARAMETER QuarantineBase  Override quarantine root (e.g. another drive/folder).

.EXAMPLE
  .\Fix-VccDuplicates.ps1                 # dry-run
  .\Fix-VccDuplicates.ps1 -Apply          # perform the quarantine
  .\Fix-VccDuplicates.ps1 -Apply -QuarantineBase 'E:\vcc_quarantine'
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string[]]$ProjectPath,
    [switch]$Apply,
    [string]$QuarantineBase
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VccDuplicates.Common.ps1')

$settingsFile = Resolve-VccSettingsPath -Override $SettingsPath
$projects     = Get-VccProjectList -Override $ProjectPath -SettingsFile $settingsFile
$timestamp    = Get-Date -Format 'yyyyMMdd-HHmmss'

if ($settingsFile) { Write-Host "VCC settings : $settingsFile" -ForegroundColor Cyan }
Write-Host "Projects     : $($projects.Count)" -ForegroundColor Cyan
Write-Host "Mode         : $(if ($Apply) { 'APPLY (folders will be moved)' } else { 'DRY-RUN (no changes)' })" -ForegroundColor Cyan
Write-Host ""

$moved = 0; $kept = 0; $ambiguous = 0

foreach ($proj in $projects) {
    $scan = Get-VccProjectScan -Project $proj
    if (-not $scan.HasPackages) { continue }

    $groups = Get-VccEmbeddedDuplicateGroups -Scan $scan
    if ($groups.Count -eq 0) { continue }

    Write-Host "[$proj]" -ForegroundColor Yellow

    # Quarantine outside the Unity project so Unity/git never pick it up.
    $projLeaf = Split-Path $proj -Leaf
    $qBase = if ($QuarantineBase) {
        Join-Path $QuarantineBase "$projLeaf-$timestamp"
    } else {
        Join-Path (Split-Path $proj -Parent) "_vcc_quarantine_$timestamp\$projLeaf"
    }

    foreach ($g in $groups) {
        if (-not $g.Canonical) {
            $ambiguous++
            Write-Host "  AMBIGUOUS  '$($g.Name)' in $($g.All.Count) folders, none matches the package name:" -ForegroundColor Red
            foreach ($f in $g.All) { Write-Host "               - Packages/$($f.FolderName)/  v=$($f.Version)" }
            Write-Host "             -> resolve manually (cannot pick canonical safely)." -ForegroundColor Red
            continue
        }

        Write-Host "  CANONICAL  Packages/$($g.Canonical.FolderName)/  v=$($g.Canonical.Version)" -ForegroundColor Green

        foreach ($o in $g.Others) {
            if ($o.Version -ne $g.Canonical.Version) {
                $kept++
                Write-Host "  KEEP       Packages/$($o.FolderName)/  (version differs: $($o.Version) vs canonical $($g.Canonical.Version)) -> manual" -ForegroundColor Red
                continue
            }

            $dest = Join-Path $qBase $o.FolderName
            if ($Apply) {
                if (-not (Test-Path -LiteralPath $qBase)) { New-Item -ItemType Directory -Path $qBase -Force | Out-Null }
                try {
                    Move-Item -LiteralPath $o.FullPath -Destination $dest -ErrorAction Stop
                    Write-Host "  MOVED      Packages/$($o.FolderName)/  ->  $dest" -ForegroundColor Green
                    $moved++
                } catch {
                    Write-Host "  FAIL       Packages/$($o.FolderName)/  ($($_.Exception.Message))" -ForegroundColor Red
                }
            } else {
                $moved++
                Write-Host "  WOULD-MOVE Packages/$($o.FolderName)/  ->  $dest" -ForegroundColor Cyan
            }
        }
    }
}

Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  Moved / would-move : $moved"
Write-Host "  Kept (manual)      : $kept"
Write-Host "  Ambiguous (manual) : $ambiguous"
Write-Host ""
if (-not $Apply -and $moved -gt 0) {
    Write-Host "Re-run with -Apply to perform the quarantine." -ForegroundColor Yellow
} elseif ($Apply -and $moved -gt 0) {
    Write-Host "Done. Launch VCC/ALCOM and confirm it opens. After verifying, you may delete the _vcc_quarantine_* folders." -ForegroundColor Green
} elseif ($moved -eq 0 -and ($kept -gt 0 -or $ambiguous -gt 0)) {
    Write-Host "Nothing auto-moved; see KEEP/AMBIGUOUS entries above for manual handling." -ForegroundColor Yellow
} else {
    Write-Host "Nothing to do." -ForegroundColor Green
}
