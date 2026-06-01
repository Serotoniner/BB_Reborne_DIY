# BB Reborne DIY Tool
# Copyright (C) 2026 Greg Pitta
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# See the LICENSE file for details.

<#
    Patch-Sfx_RemovePlayerLight_BBReborne.ps1

    Harmonized SFX patch script for the BB Reborne DIY Tool.

    Purpose:
    - Copy frpg_sfxbnd_commoneffects.ffxbnd.dcx from the configured game folder.
    - Patch only the copied archive inside the configured output/work folders.
    - Never modify the original game files.
    - Produce the patched archive under:
        <OutputRoot>\BBReborne_sfx\<relative source path>

    Patch performed:
    - In the extracted common SFX archive, replace:
        effect\f000000210.fxr
      with a copy of:
        effect\f000000192.fxr

    Expected config file from BBReborneDIYTool.ps1:
        <ToolRoot>\BBReborneDIYTool.paths.ps1

    Example direct run:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\Patch-Sfx_RemovePlayerLight_BBReborne.ps1 `
            -ToolPathsPs1 "C:\Users\Sero\BBReborneDIYTool\Tools\BBReborneDIYTool.paths.ps1"

    Notes:
    - WitchyBND v3.0.0.1 is used because this archive type needs that version.
    - CpuThrottle/GpuThrottle are accepted for tool-wide parameter consistency, but this specific
      WitchyBND interaction is sequential and does not use them internally.
#>

param(
    [string]$ToolPathsPs1,
    [string]$GameRoot,
    [string]$OutputRoot,
    [string]$WitchyBndExe,
    [int]$CpuThrottle = 0,
    [int]$GpuThrottle = 0,
    [string]$SourceArchiveRelativePath = 'sfx\frpg_sfxbnd_commoneffects.ffxbnd.dcx',
    [switch]$KeepWork,
    [int]$WitchyTimeoutSeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Stage {
    param([AllowNull()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-Host ''
        return
    }
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Info {
    param([AllowNull()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    Write-Host $Message
}

function Get-OptionalVariableValue {
    param([Parameter(Mandatory)][string]$Name)

    $var = Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $var) { return $null }
    return $var.Value
}

function Resolve-OptionalConfigPath {
    if ($ToolPathsPs1) {
        if (-not (Test-Path -LiteralPath $ToolPathsPs1 -PathType Leaf)) {
            throw "Tool paths file not found: $ToolPathsPs1"
        }
        return (Resolve-Path -LiteralPath $ToolPathsPs1).Path
    }

    $candidates = @(
        (Join-Path $PSScriptRoot '..\..\Tools\BBReborneDIYTool.paths.ps1'),
        (Join-Path $PSScriptRoot '..\Tools\BBReborneDIYTool.paths.ps1'),
        (Join-Path $PSScriptRoot 'Tools\BBReborneDIYTool.paths.ps1'),
        (Join-Path $PSScriptRoot 'BBReborneDIYTool.paths.ps1')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Import-ToolConfig {
    $configPath = Resolve-OptionalConfigPath
    if ($configPath) {
        Write-Info "Using tool config: $configPath"

        # Dot-sourcing from inside a function creates variables in function scope.
        # Copy BBR_* variables back to script scope so standalone runs with only
        # -ToolPathsPs1 can resolve saved paths reliably.
        . $configPath
        Get-Variable -Scope Local -Name 'BBR_*' -ErrorAction SilentlyContinue | ForEach-Object {
            Set-Variable -Name $_.Name -Value $_.Value -Scope Script
        }
    } else {
        Write-Info 'No tool config file found. Parameters must provide all required paths.'
    }
}

function Resolve-RequiredDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label is empty."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-RequiredFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label is empty."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-GameRoot {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-RequiredDirectory -Path $Path -Label 'Game root'
    $leaf = Split-Path -Leaf ($resolved.TrimEnd('\', '/'))
    if ($leaf -ne 'dvdroot_ps4') {
        throw "Game root must end with dvdroot_ps4. Current path: $resolved"
    }

    return $resolved
}

function Resolve-SourceArchive {
    param(
        [Parameter(Mandatory)][string]$GameRootPath,
        [Parameter(Mandatory)][string]$RelativeOrAbsolutePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativeOrAbsolutePath)) {
        $archive = Resolve-RequiredFile -Path $RelativeOrAbsolutePath -Label 'Source SFX archive'
        return [pscustomobject]@{
            FullPath     = $archive
            RelativePath = Split-Path -Leaf $archive
        }
    }

    $primaryCandidate = Join-Path $GameRootPath $RelativeOrAbsolutePath
    $candidateRelativePaths = New-Object System.Collections.Generic.List[string]
    $candidateRelativePaths.Add($RelativeOrAbsolutePath)

    foreach ($fallback in @(
        'sfx\frpg_sfxbnd_commoneffects.ffxbnd.dcx',
        'effect\frpg_sfxbnd_commoneffects.ffxbnd.dcx',
        'frpg_sfxbnd_commoneffects.ffxbnd.dcx'
    )) {
        if (-not $candidateRelativePaths.Contains($fallback)) {
            $candidateRelativePaths.Add($fallback)
        }
    }

    foreach ($relative in $candidateRelativePaths) {
        $candidate = Join-Path $GameRootPath $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [pscustomobject]@{
                FullPath     = (Resolve-Path -LiteralPath $candidate).Path
                RelativePath = $relative
            }
        }
    }

    throw "Source SFX archive not found. Tried primary path $primaryCandidate and fallback locations under $GameRootPath."
}

function Get-ExpectedExtractDirNamePrefix {
    param([Parameter(Mandatory)][string]$ArchivePath)

    $leaf = Split-Path -Leaf $ArchivePath
    return ($leaf -replace '\.', '-')
}

function Wait-ForExtractedFolder {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [int]$TimeoutSeconds = 90
    )

    $parent = Split-Path -Parent $ArchivePath
    $prefix = Get-ExpectedExtractDirNamePrefix -ArchivePath $ArchivePath
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $match = Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$prefix*" } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($null -ne $match) {
            return $match.FullName
        }

        Start-Sleep -Milliseconds 250
    }

    throw "Timed out waiting for extracted folder for archive: $ArchivePath"
}

function Wait-ForAnyMarkerFile {
    param(
        [Parameter(Mandatory)][string]$ExtractDir,
        [int]$TimeoutSeconds = 200
    )

    $candidateNames = @(
        '_witchy-ffxbnd.xml',
        '_witchy-bnd4.xml'
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        foreach ($name in $candidateNames) {
            $p = Join-Path $ExtractDir $name
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                return $p
            }
        }

        Start-Sleep -Milliseconds 250
    }

    throw "Timed out waiting for Witchy marker XML in: $ExtractDir"
}

function Start-WitchyExtract {
    param([Parameter(Mandatory)][string]$ArchivePath)

    $p = Start-Process -FilePath $script:WitchyBndExe -ArgumentList @($ArchivePath) -PassThru

    # WitchyBND v3 can stop at the same interactive menu during extraction.
    # Send the same menu sequence immediately after launching it, before waiting for output files.
    Send-WitchyMenuSequence -Process $p -RepeatCount 3

    $extractDir = Wait-ForExtractedFolder -ArchivePath $ArchivePath -TimeoutSeconds $script:WitchyTimeoutSeconds
    $markerXml = Wait-ForAnyMarkerFile -ExtractDir $extractDir -TimeoutSeconds $script:WitchyTimeoutSeconds

    Start-Sleep -Milliseconds 800

    [pscustomobject]@{
        Process    = $p
        ExtractDir = $extractDir
        MarkerXml  = $markerXml
    }
}

function Start-WitchyRepack {
    param([Parameter(Mandatory)][string]$ExtractDir)

    Start-Process -FilePath $script:WitchyBndExe -ArgumentList @($ExtractDir) -PassThru
}

function Send-WitchyMenuSequence {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [int]$RepeatCount = 3,
        [int]$DelayMsBeforeStart = 1500,
        [int]$DelayMsBetweenKeys = 350,
        [int]$DelayMsBetweenRepeats = 1200
    )

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $wshell = New-Object -ComObject WScript.Shell

    Start-Sleep -Milliseconds $DelayMsBeforeStart
    $null = $wshell.AppActivate($Process.Id)
    Start-Sleep -Milliseconds 500

    for ($i = 1; $i -le $RepeatCount; $i++) {
        Start-Sleep -Milliseconds $DelayMsBetweenKeys
		$wshell.SendKeys('{DOWN}')
        Start-Sleep -Milliseconds $DelayMsBetweenKeys

        $wshell.SendKeys('{DOWN}')
        Start-Sleep -Milliseconds $DelayMsBetweenKeys

        $wshell.SendKeys('~')
        Start-Sleep -Milliseconds $DelayMsBetweenRepeats
    }
}

function Stop-ProcessSafe {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)

    try {
        if (-not $Process.HasExited) {
            $Process.CloseMainWindow() | Out-Null
            Start-Sleep -Milliseconds 800
        }
    } catch {}

    try {
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force
            Start-Sleep -Milliseconds 500
        }
    } catch {}
}

function Remove-SafeWorkDir {
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

    $full = [System.IO.Path]::GetFullPath($Path)
    $outputFull = [System.IO.Path]::GetFullPath($script:OutputRoot)
    if (-not $full.StartsWith($outputFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove work directory outside OutputRoot: $full"
    }

    Remove-Item -LiteralPath $full -Recurse -Force
}

# -------------------- Main --------------------

Import-ToolConfig

if (-not $GameRoot) { $GameRoot = Get-OptionalVariableValue -Name 'BBR_GameRoot' }
if (-not $OutputRoot) { $OutputRoot = Get-OptionalVariableValue -Name 'BBR_OutputRoot' }
if (-not $WitchyBndExe) { $WitchyBndExe = Get-OptionalVariableValue -Name 'BBR_WitchyBND_v3_0_0_1' }
if ($CpuThrottle -le 0) {
    $configuredCpuThrottle = Get-OptionalVariableValue -Name 'BBR_CpuThrottle'
    if ($configuredCpuThrottle) { $CpuThrottle = [int]$configuredCpuThrottle }
}
if ($GpuThrottle -le 0) {
    $configuredGpuThrottle = Get-OptionalVariableValue -Name 'BBR_GpuThrottle'
    if ($configuredGpuThrottle) { $GpuThrottle = [int]$configuredGpuThrottle }
}

$GameRoot = Resolve-GameRoot -Path $GameRoot
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$WitchyBndExe = Resolve-RequiredFile -Path $WitchyBndExe -Label 'WitchyBND v3 executable'
$script:OutputRoot = $OutputRoot
$script:WitchyBndExe = $WitchyBndExe
$script:WitchyTimeoutSeconds = $WitchyTimeoutSeconds

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

$sourceArchive = Resolve-SourceArchive -GameRootPath $GameRoot -RelativeOrAbsolutePath $SourceArchiveRelativePath
$sfxOutputRoot = Join-Path $OutputRoot 'BBReborne_sfx'
$finalArchivePath = Join-Path $sfxOutputRoot $sourceArchive.RelativePath
$finalArchiveDir = Split-Path -Parent $finalArchivePath
New-Item -ItemType Directory -Path $finalArchiveDir -Force | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$workRoot = Join-Path $OutputRoot '_work'
$runWorkDir = Join-Path $workRoot "sfx_remove_player_light_$stamp"
New-Item -ItemType Directory -Path $runWorkDir -Force | Out-Null

$workingArchivePath = Join-Path $runWorkDir (Split-Path -Leaf $sourceArchive.FullPath)

Write-Info "GameRoot      = $GameRoot"
Write-Info "OutputRoot    = $OutputRoot"
Write-Info "WitchyBND     = $WitchyBndExe"
Write-Info "CpuThrottle   = $CpuThrottle"
Write-Info "GpuThrottle   = $GpuThrottle"
Write-Info "SourceArchive = $($sourceArchive.FullPath)"
Write-Info "FinalArchive  = $finalArchivePath"
Write-Info "WorkDir       = $runWorkDir"

$overall = [System.Diagnostics.Stopwatch]::StartNew()
$completed = $false

try {
    Write-Stage ''
    Write-Stage '1/5 Copy source archive into isolated work folder...'
    Copy-Item -LiteralPath $sourceArchive.FullPath -Destination $workingArchivePath -Force

    Write-Stage ''
    Write-Stage '2/5 Extract working archive with WitchyBND...'
    $extractResult = Start-WitchyExtract -ArchivePath $workingArchivePath

    $extractProc = $extractResult.Process
    $extractDir = $extractResult.ExtractDir
    $markerXml = $extractResult.MarkerXml

    Write-Info "ExtractDir = $extractDir"
    Write-Info "MarkerXml  = $markerXml"

    $srcFxr = Join-Path $extractDir 'effect\f000000192.fxr'
    $dstFxr = Join-Path $extractDir 'effect\f000000210.fxr'

    if (-not (Test-Path -LiteralPath $srcFxr -PathType Leaf)) {
        throw "Source FXR not found: $srcFxr"
    }

    Write-Stage ''
    Write-Stage '3/5 Replace f000000210 with a copy of f000000192...'

    if (Test-Path -LiteralPath $dstFxr -PathType Leaf) {
        Remove-Item -LiteralPath $dstFxr -Force
        Write-Info "Deleted existing target inside work extract: $dstFxr"
    }

    Copy-Item -LiteralPath $srcFxr -Destination $dstFxr -Force
    Write-Info 'Copied 192 -> 210 inside work extract.'

    (Get-Item -LiteralPath $dstFxr).LastWriteTime = Get-Date
    (Get-Item -LiteralPath $markerXml).LastWriteTime = Get-Date

    Write-Stage ''
    Write-Stage 'Closing extraction WitchyBND window before repack...'
    Stop-ProcessSafe -Process $extractProc

    Start-Sleep -Seconds 1
    $beforeWrite = (Get-Item -LiteralPath $workingArchivePath).LastWriteTimeUtc

    Write-Stage ''
    Write-Stage '4/5 Repack working archive with WitchyBND interactive sequence...'
    $repackProc = Start-WitchyRepack -ExtractDir $extractDir
    Send-WitchyMenuSequence -Process $repackProc -RepeatCount 3

    Start-Sleep -Seconds 5
    try { Stop-ProcessSafe -Process $repackProc } catch {}

    $afterWrite = (Get-Item -LiteralPath $workingArchivePath).LastWriteTimeUtc
    if ($afterWrite -gt $beforeWrite) {
        Write-Info 'Archive timestamp updated: repack appears to have completed.'
    } else {
        Write-Warning 'Archive timestamp did not change. Repack key timing may need adjustment.'
    }

    Write-Stage ''
    Write-Stage '5/5 Copy patched archive to output folder...'
    Copy-Item -LiteralPath $workingArchivePath -Destination $finalArchivePath -Force
    Write-Info "Patched archive written: $finalArchivePath"

    $completed = $true
}
finally {
    $overall.Stop()
    if ($completed -and -not $KeepWork) {
        try {
            Remove-SafeWorkDir -Path $runWorkDir
            Write-Info "Removed isolated work folder: $runWorkDir"
        } catch {
            Write-Warning $_.Exception.Message
        }
    } else {
        Write-Info "Kept work folder: $runWorkDir"
    }
}

Write-Stage ''
Write-Stage 'Done.'
Write-Info ('Elapsed: {0}' -f $overall.Elapsed)
