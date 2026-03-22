#Requires -Version 5.1
<#
.SYNOPSIS
  Copies media from a local "incoming" folder to cloud sync folders, then removes the source copy.

  This script does NOT pull files from an iPhone. Import photos/videos to -SourcePath first
  (Explorer, Photos app, 3uTools, etc.), then run this script.
#>
param(
    [string]$SourcePath = "D:\iPhone_CloudBackup\incoming",
    [switch]$DryRun,
    [switch]$SkipGoogleDrive
)

$ErrorActionPreference = 'Stop'
$source = $SourcePath

$clouds = [System.Collections.Generic.List[string]]::new()
$clouds.Add("G:\iPhoneMedia") | Out-Null
$clouds.Add((Join-Path $env:USERPROFILE 'OneDrive\iPhoneMedia')) | Out-Null
$googleDriveDefault = Join-Path $env:USERPROFILE 'Google Drive\iPhoneMedia'
if (-not $SkipGoogleDrive) {
    $clouds.Add($googleDriveDefault) | Out-Null
}

# Supported media extensions
$mediaExtensions = @(".jpg", ".jpeg", ".png", ".heic", ".mov", ".mp4", ".m4v", ".avi")

function Write-DesignWarnings {
    param(
        [bool]$SkipGoogleDrive,
        [string]$GoogleDrivePath
    )
    Write-Host ""
    Write-Host "=== Design limits (read once) ===" -ForegroundColor Yellow
    Write-Host "  - iPhone: This script only processes the PC folder -SourcePath. Copy media from the phone into that folder yourself; nothing here talks to iOS."
    Write-Host "  - OneDrive: Free space checked is the local disk (e.g. C:). It is NOT your Microsoft 365 storage quota. Sync can still fail if you are over quota."
    if ($SkipGoogleDrive) {
        Write-Host "  - Google Drive: Not used (-SkipGoogleDrive). Default would be: $GoogleDrivePath"
    } else {
        Write-Host "  - Google Drive: Files go to $GoogleDrivePath (typical 'Google Drive' desktop folder). If your client uses another letter/path, use -SkipGoogleDrive and add that path to `$clouds in the script."
    }
    Write-Host "  - Duplicates: Skips when the same relative path already exists under a destination. Same filename in different subfolders is kept distinct."
    if ($DryRun) {
        Write-Host "  - DRY RUN: No files copied, no folders created, no source files deleted." -ForegroundColor Cyan
    }
    Write-Host "=================================" -ForegroundColor Yellow
    Write-Host ""
}

function Get-RelativePathFromRoot {
    param(
        [string]$RootResolved,
        [string]$FileFullPath
    )
    $root = $RootResolved.TrimEnd('\')
    if (-not $FileFullPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    # Reject prefix collisions: e.g. D:\incoming vs D:\incoming_extra\file.jpg
    if ($FileFullPath.Length -gt $root.Length -and $FileFullPath[$root.Length] -ne [char]'\') {
        return $null
    }
    return $FileFullPath.Substring($root.Length).TrimStart('\')
}

function Get-FreeBytesForPath {
    param([string]$Path)
    try {
        $p = $Path.Trim()
        if ($p -match '^\\\\') {
            $parts = $p.Trim('\').Split('\')
            if ($parts.Length -ge 2) {
                $uncRoot = '\\' + $parts[0] + '\' + $parts[1]
                return ([System.IO.DriveInfo]::new($uncRoot)).AvailableFreeSpace
            }
            return $null
        }
        if ($p -match '^([A-Za-z]):') {
            return ([System.IO.DriveInfo]::new($Matches[1] + ':\')).AvailableFreeSpace
        }
    } catch {
        return $null
    }
    return $null
}

Write-DesignWarnings -SkipGoogleDrive:$SkipGoogleDrive -GoogleDrivePath $googleDriveDefault

if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    Write-Error "Source folder missing: $source - create it and add media (from iPhone via PC), then run again."
}

foreach ($cloud in $clouds) {
    if (-not (Test-Path -LiteralPath $cloud -PathType Container)) {
        if ($DryRun) {
            Write-Host "[DRY RUN] Would create destination folder: $cloud"
        } else {
            try {
                New-Item -ItemType Directory -Path $cloud -Force | Out-Null
                Write-Host "Created destination: $cloud"
            } catch {
                Write-Warning "Could not create destination folder (check drive letter / permissions): $cloud - $_"
            }
        }
    }
}

$srcRootResolved = (Resolve-Path -LiteralPath $source).Path

# One recursive scan per cloud at startup - index by path relative to each cloud root (preserves subfolders)
$nameIndex = @{}
foreach ($cloud in $clouds) {
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $cloud -PathType Container) {
        $cloudResolved = (Resolve-Path -LiteralPath $cloud).Path.TrimEnd('\')
        Get-ChildItem -LiteralPath $cloud -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = Get-RelativePathFromRoot -RootResolved $cloudResolved -FileFullPath $_.FullName
            if ($rel) { [void]$set.Add($rel) }
        }
    }
    $nameIndex[$cloud] = $set
}

$files = @(Get-ChildItem -LiteralPath $source -Recurse -File -ErrorAction Stop | Where-Object {
    $mediaExtensions -contains $_.Extension.ToLower()
})

if ($files.Count -eq 0) {
    Write-Host "No media files found under $source (extensions: $($mediaExtensions -join ', '))."
    return
}

foreach ($file in $files) {
    $relFromIncoming = Get-RelativePathFromRoot -RootResolved $srcRootResolved -FileFullPath $file.FullName
    if (-not $relFromIncoming) {
        Write-Warning "Skipping file outside source tree: $($file.FullName)"
        continue
    }

    $copied = $false

    foreach ($cloud in $clouds) {
        $names = $nameIndex[$cloud]

        if ($names.Contains($relFromIncoming)) {
            if ($DryRun) {
                Write-Host "[DRY RUN] Would skip upload (already exists): $relFromIncoming @ $cloud"
                Write-Host "[DRY RUN] Would remove source to free space: $($file.FullName)"
            } else {
                Write-Host "Skipped duplicate (path match): $relFromIncoming @ $cloud"
            }
            $copied = $true
            break
        }

        $free = Get-FreeBytesForPath $cloud
        if ($null -eq $free) {
            Write-Warning "Could not read free space for $cloud - skipping this destination."
            continue
        }

        if ($free -le $file.Length) {
            continue
        }

        $destPath = Join-Path $cloud $relFromIncoming
        $destDir = [System.IO.Path]::GetDirectoryName($destPath)
        if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
            if ($DryRun) {
                Write-Host "[DRY RUN] Would create directory: $destDir"
            } else {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
        }

        if ($DryRun) {
            Write-Host "[DRY RUN] Would copy: $($file.FullName) -> $destPath"
            Write-Host "[DRY RUN] Would remove source after verify: $($file.FullName)"
            $copied = $true
            break
        }

        try {
            Copy-Item -LiteralPath $file.FullName -Destination $destPath -Force
        } catch {
            Write-Warning "Copy failed for $relFromIncoming to $cloud : $_"
            continue
        }

        $destItem = Get-Item -LiteralPath $destPath -ErrorAction SilentlyContinue
        if (-not $destItem -or $destItem.Length -ne $file.Length) {
            Write-Warning "Copy verification failed for $relFromIncoming - not removing source."
            if ($destItem) { Remove-Item -LiteralPath $destPath -Force -ErrorAction SilentlyContinue }
            continue
        }

        [void]$names.Add($relFromIncoming)
        Write-Host "Uploaded: $relFromIncoming to $cloud"
        $copied = $true
        break
    }

    if ($copied) {
        if (-not $DryRun) {
            Remove-Item -LiteralPath $file.FullName -Force
        }
    } else {
        if ($DryRun) {
            Write-Host "[DRY RUN] No space or all destinations failed for: $relFromIncoming"
        } else {
            Write-Host "No space or all destinations failed for: $relFromIncoming"
        }
    }
}
