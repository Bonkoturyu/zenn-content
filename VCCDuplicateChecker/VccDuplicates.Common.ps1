#Requires -Version 5.1
<#
.SYNOPSIS
  Shared helpers for VCC duplicate-package detection.
  Dot-source from Scan-VccDuplicates.ps1 / Fix-VccDuplicates.ps1.
  All three files must live in the same folder.

.NOTES
  Detection is NAME-BASED (package.json "name"), not folder-name based,
  so it catches duplicates regardless of how the stray folder is named
  ("com.x (1)", "com.x - コピー", or an unrelated folder name whose
  package.json declares an existing package name).
#>

$ErrorActionPreference = 'Stop'

function Resolve-VccSettingsPath {
    param([string]$Override)
    if ($Override) { return $Override }
    foreach ($c in @(
        (Join-Path $env:LOCALAPPDATA 'VRChatCreatorCompanion\settings.json'),
        (Join-Path $env:APPDATA      'VRChatCreatorCompanion\settings.json')
    )) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Get-VccProjectList {
    param([string[]]$Override, [string]$SettingsFile)
    if ($Override) { return $Override }
    if (-not $SettingsFile) { throw "VCC settings.json not found. Pass -SettingsPath or -ProjectPath." }
    $s = Get-Content -Raw -LiteralPath $SettingsFile | ConvertFrom-Json
    if (-not $s.userProjects) { return @() }
    return @($s.userProjects)
}

function Read-JsonFile {
    # Returns @{ Ok; Data; DuplicateKey; Error }.
    # ConvertFrom-Json THROWS on duplicate object keys (both PS 5.1 and 7),
    # so we detect that case explicitly instead of silently misreporting it.
    param([string]$Path)
    $out = [pscustomobject]@{ Ok = $false; Data = $null; DuplicateKey = $null; Error = $null }
    try {
        $raw = Get-Content -Raw -LiteralPath $Path
        $out.Data = $raw | ConvertFrom-Json
        $out.Ok = $true
    } catch {
        $msg = $_.Exception.Message
        $m = [regex]::Match($msg, "duplicate keys?\s+'([^']+)'")
        if ($m.Success) { $out.DuplicateKey = $m.Groups[1].Value }
        $out.Error = $msg
    }
    return $out
}

function Add-ScanEntry {
    param($Map, [string]$Name, [string]$Kind, [string]$Source, $Version)
    if (-not $Map.ContainsKey($Name)) { $Map[$Name] = New-Object System.Collections.ArrayList }
    [void]$Map[$Name].Add([pscustomobject]@{ Kind = $Kind; Source = $Source; Version = $Version })
}

function Get-VccProjectScan {
    param([string]$Project)

    $result = [pscustomobject]@{
        Project      = $Project
        Exists       = (Test-Path -LiteralPath $Project)
        HasPackages  = $false
        Map          = @{}   # name -> ArrayList of {Kind;Source;Version}
        Embedded     = @{}   # name -> ArrayList of {FolderName;FullPath;Version}
        ParseErrors  = New-Object System.Collections.ArrayList
        DupKeyFiles  = New-Object System.Collections.ArrayList  # {File;Key}
        NameMismatch = New-Object System.Collections.ArrayList
    }
    if (-not $result.Exists) { return $result }

    $pkgDir = Join-Path $Project 'Packages'
    if (-not (Test-Path -LiteralPath $pkgDir)) { return $result }
    $result.HasPackages = $true

    # 1. vpm-manifest.json (VCC)
    $vpmPath = Join-Path $pkgDir 'vpm-manifest.json'
    if (Test-Path -LiteralPath $vpmPath) {
        $r = Read-JsonFile -Path $vpmPath
        if ($r.Ok) {
            if ($r.Data.locked) {
                foreach ($p in $r.Data.locked.PSObject.Properties) {
                    Add-ScanEntry $result.Map $p.Name 'vpm-locked' 'Packages/vpm-manifest.json#locked' $p.Value.version
                }
            }
            if ($r.Data.dependencies) {
                foreach ($p in $r.Data.dependencies.PSObject.Properties) {
                    Add-ScanEntry $result.Map $p.Name 'vpm-dep' 'Packages/vpm-manifest.json#dependencies' $p.Value.version
                }
            }
        } elseif ($r.DuplicateKey) {
            [void]$result.DupKeyFiles.Add([pscustomobject]@{ File = 'Packages/vpm-manifest.json'; Key = $r.DuplicateKey })
        } else {
            [void]$result.ParseErrors.Add("vpm-manifest.json: $($r.Error)")
        }
    }

    # 2. manifest.json (Unity UPM)
    $upmPath = Join-Path $pkgDir 'manifest.json'
    if (Test-Path -LiteralPath $upmPath) {
        $r = Read-JsonFile -Path $upmPath
        if ($r.Ok) {
            if ($r.Data.dependencies) {
                foreach ($p in $r.Data.dependencies.PSObject.Properties) {
                    Add-ScanEntry $result.Map $p.Name 'upm' 'Packages/manifest.json#dependencies' $p.Value
                }
            }
        } elseif ($r.DuplicateKey) {
            [void]$result.DupKeyFiles.Add([pscustomobject]@{ File = 'Packages/manifest.json'; Key = $r.DuplicateKey })
        } else {
            [void]$result.ParseErrors.Add("manifest.json: $($r.Error)")
        }
    }

    # 3. Embedded packages (Packages/<dir>/package.json) -- keyed by package.json name
    Get-ChildItem -LiteralPath $pkgDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $dir = $_
        $pj  = Join-Path $dir.FullName 'package.json'
        if (-not (Test-Path -LiteralPath $pj)) { return }
        $r = Read-JsonFile -Path $pj
        if (-not $r.Ok) {
            if ($r.DuplicateKey) {
                [void]$result.DupKeyFiles.Add([pscustomobject]@{ File = "Packages/$($dir.Name)/package.json"; Key = $r.DuplicateKey })
            } else {
                [void]$result.ParseErrors.Add("Packages/$($dir.Name)/package.json: $($r.Error)")
            }
            return
        }
        $name = $r.Data.name
        if (-not $name) { return }
        if ($name -ne $dir.Name) {
            [void]$result.NameMismatch.Add("Folder 'Packages/$($dir.Name)/' declares name '$name'")
        }
        Add-ScanEntry $result.Map $name 'embedded' "Packages/$($dir.Name)/package.json" $r.Data.version

        if (-not $result.Embedded.ContainsKey($name)) { $result.Embedded[$name] = New-Object System.Collections.ArrayList }
        [void]$result.Embedded[$name].Add([pscustomobject]@{
            FolderName = $dir.Name
            FullPath   = $dir.FullName
            Version    = $r.Data.version
        })
    }

    return $result
}

function Find-VccDuplicateIssues {
    # Reporting-level duplicate classification (read-only).
    param($Scan)
    $issues = New-Object System.Collections.ArrayList

    foreach ($name in $Scan.Map.Keys) {
        $entries = @($Scan.Map[$name])

        # Collapse vpm-locked / vpm-dep into 'vpm' for cross-kind comparison.
        $simpleKinds = @(
            $entries | ForEach-Object { if ($_.Kind -like 'vpm-*') { 'vpm' } else { $_.Kind } } |
                Sort-Object -Unique
        )
        # vpm + embedded is the normal VPM install pattern -> not an issue.
        $normalPair = ($simpleKinds.Count -eq 2 -and ($simpleKinds -contains 'vpm') -and ($simpleKinds -contains 'embedded'))

        if ($simpleKinds.Count -ge 2 -and -not $normalPair) {
            [void]$issues.Add([pscustomobject]@{ Severity = 'DUP-CROSS'; Package = $name; Entries = $entries })
            continue
        }
        $embeddedCount = @($entries | Where-Object { $_.Kind -eq 'embedded' }).Count
        if ($embeddedCount -ge 2) {
            [void]$issues.Add([pscustomobject]@{ Severity = 'DUP-EMBEDDED'; Package = $name; Entries = $entries })
        }
    }
    return $issues
}

function Get-VccEmbeddedDuplicateGroups {
    # Action-level grouping used by the Fix script.
    # For each package name with >= 2 embedded folders, identify the canonical
    # folder (folder name == package name) and the others.
    param($Scan)
    $groups = New-Object System.Collections.ArrayList
    foreach ($name in $Scan.Embedded.Keys) {
        $folders = @($Scan.Embedded[$name])
        if ($folders.Count -lt 2) { continue }
        $canon  = @($folders | Where-Object { $_.FolderName -eq $name })   # -eq is case-insensitive (matches NTFS)
        $others = @($folders | Where-Object { $_.FolderName -ne $name })
        [void]$groups.Add([pscustomobject]@{
            Name      = $name
            Canonical = if ($canon.Count -eq 1) { $canon[0] } else { $null }
            All       = $folders
            Others    = $others
        })
    }
    return $groups
}
