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
    02_Global_BBReborne_SFX_M25.ps1

    Harmonized SFX M25 patch script for the BB Reborne DIY Tool.

    This rebuild keeps the WitchyBND calls in the same style as the original
    Patch_SFX_M25.ps1:
        & $FilePath @ArgumentList

    The script only changes input/output handling:
    - copies original game archives into an isolated work folder
    - patches only the copied M25 archive
    - writes final result under:
        <OutputRoot>\BBReborne_sfx\sfx\frpg_sfxbnd_m25.ffxbnd.dcx
    - does not touch original game files
    - does not create backups because the original game files are untouched

    Expected config file from BBReborneDIYTool.ps1:
        <ToolRoot>\BBReborneDIYTool.paths.ps1

    Example direct run:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\02_Global_BBReborne_SFX_M25.ps1 `
            -ToolPathsPs1 "<BBReborneDIYTool>\Tools\BBReborneDIYTool.paths.ps1"
#>

param(
    [string]$ToolPathsPs1,
    [string]$GameRoot,
    [string]$OutputRoot,
    [string]$WitchyBndExe,
    [int]$CpuThrottle = 0,
    [int]$GpuThrottle = 0,

    [string]$M24ArchiveRelativePath = 'sfx\frpg_sfxbnd_m24.ffxbnd.dcx',
    [string]$M25ArchiveRelativePath = 'sfx\frpg_sfxbnd_m25.ffxbnd.dcx',
    [string]$OutputRelativePath = 'sfx\frpg_sfxbnd_m25.ffxbnd.dcx',

    # Same behavior as the original: these are already-extracted folders, not archives.
    [string[]]$ExtraM24ExtractDirs = @(),
    [switch]$IncludeM24Subpacks,

    [switch]$KeepWork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-OptionalVariableValue {
    param([Parameter(Mandatory)] [string]$Name)

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
        Write-Host "Using tool config: $configPath"
        . $configPath
    }
    else {
        Write-Host "No tool config file found. Parameters must provide all required paths."
    }
}

function Resolve-RequiredDirectory {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Label
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
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Label
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
    param([Parameter(Mandatory)] [string]$Path)

    $resolved = Resolve-RequiredDirectory -Path $Path -Label 'Game root'
    $leaf = Split-Path -Leaf ($resolved.TrimEnd('\', '/'))
    if ($leaf -ne 'dvdroot_ps4') {
        throw "Game root must end with dvdroot_ps4. Current path: $resolved"
    }

    return $resolved
}

function Resolve-GameArchive {
    param(
        [Parameter(Mandatory)] [string]$GameRootPath,
        [Parameter(Mandatory)] [string]$RelativeOrAbsolutePath,
        [Parameter(Mandatory)] [string]$Label
    )

    if ([System.IO.Path]::IsPathRooted($RelativeOrAbsolutePath)) {
        $full = Resolve-RequiredFile -Path $RelativeOrAbsolutePath -Label $Label
        return [pscustomobject]@{
            FullPath     = $full
            RelativePath = Split-Path -Leaf $full
        }
    }

    $candidate = Join-Path $GameRootPath $RelativeOrAbsolutePath
    $full = Resolve-RequiredFile -Path $candidate -Label $Label
    return [pscustomobject]@{
        FullPath     = $full
        RelativePath = ($RelativeOrAbsolutePath -replace '/', '\')
    }
}

function Ensure-Dir {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Remove-SafeWorkDir {
    param([Parameter(Mandatory)] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

    $full = [System.IO.Path]::GetFullPath($Path)
    $outputFull = [System.IO.Path]::GetFullPath($script:OutputRoot)
    if (-not $full.StartsWith($outputFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove work directory outside OutputRoot: $full"
    }

    Remove-Item -LiteralPath $full -Recurse -Force
}

# -------------------------------------------------------------------------
# Original Patch_SFX_M25.ps1 helper functions below.
# WitchyBND execution helpers are intentionally kept in their original style.
# -------------------------------------------------------------------------

function Resolve-FullPath {
    param(
        [Parameter(Mandatory)] [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-WitchyExtractDir {
    param(
        [Parameter(Mandatory)] [string]$ArchivePath
    )

    $parent = Split-Path -Parent $ArchivePath
    $leaf   = Split-Path -Leaf $ArchivePath
    $dir    = $leaf -replace '\.', '-'
    return (Join-Path $parent $dir)
}

function Get-RelativeBinderPath {
    param(
        [Parameter(Mandatory)] [string]$RootDir,
        [Parameter(Mandatory)] [string]$FullPath
    )

    $root = $RootDir.TrimEnd('\', '/')
    $full = $FullPath

    if ($full.Length -le $root.Length) {
        throw "Cannot derive relative path. Root='$root' Full='$full'"
    }

    $rel = $full.Substring($root.Length).TrimStart('\', '/')
    return ($rel -replace '/', '\')
}

function Get-PathBucket {
    param(
        [Parameter(Mandatory)] [string]$RelativePath
    )

    $p = $RelativePath.Replace('/', '\')
    if ($p -match '^(?i)effect\\') { return 'effect' }
    if ($p -match '^(?i)tex\\')    { return 'tex' }
    if ($p -match '^(?i)model\\')  { return 'model' }

    return 'other'
}

function Invoke-External {
    param(
        [Parameter(Mandatory)] [string]$Label,
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [object[]]$ArgumentList
    )

    Write-Host ""
    Write-Host $Label -ForegroundColor Cyan
    & $FilePath @ArgumentList
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "$Label failed with exit code $exitCode"
    }
}

function Ensure-ExtractedArchive {
    param(
        [Parameter(Mandatory)] [string]$ArchivePath,
        [Parameter(Mandatory)] [string]$ExtractDir,
        [Parameter(Mandatory)] [string]$Label
    )

    $witchyXml = Join-Path $ExtractDir "_witchy-bnd4.xml"

    if (Test-Path -LiteralPath $ExtractDir) {
        Write-Host "Removing existing extracted folder: $ExtractDir"
        Remove-Item -LiteralPath $ExtractDir -Recurse -Force
    }

    Invoke-External `
        -Label $Label `
        -FilePath $script:WitchyBndExe `
        -ArgumentList @($ArchivePath)

    if (-not (Test-Path -LiteralPath $ExtractDir)) {
        throw "Expected extracted folder was not created: $ExtractDir"
    }

    if (-not (Test-Path -LiteralPath $witchyXml)) {
        throw "Expected WitchyBND index was not created: $witchyXml"
    }
}

function Merge-BinderContent {
    param(
        [Parameter(Mandatory)] [string]$SourceDir,
        [Parameter(Mandatory)] [string]$TargetDir,
        [string[]]$Subdirs = @('effect', 'tex', 'model')
    )

    $copiedPaths = New-Object System.Collections.Generic.List[string]
    $stats = [ordered]@{}

    foreach ($subdir in $Subdirs) {
        $stats[$subdir] = [ordered]@{
            Copied  = 0
            Skipped = 0
        }

        $srcRoot = Join-Path $SourceDir $subdir
        if (-not (Test-Path -LiteralPath $srcRoot)) {
            continue
        }

        Get-ChildItem -LiteralPath $srcRoot -File -Recurse | ForEach-Object {
            $relPath = Get-RelativeBinderPath -RootDir $SourceDir -FullPath $_.FullName
            $destPath = Join-Path $TargetDir $relPath
            $destParent = Split-Path -Parent $destPath

            if (Test-Path -LiteralPath $destPath) {
                $stats[$subdir].Skipped++
                return
            }

            if (-not (Test-Path -LiteralPath $destParent)) {
                New-Item -ItemType Directory -Path $destParent -Force | Out-Null
            }

            Copy-Item -LiteralPath $_.FullName -Destination $destPath -Force
            $stats[$subdir].Copied++
            [void]$copiedPaths.Add($destPath)
        }
    }

    return [pscustomobject]@{
        SourceDir   = $SourceDir
        Stats       = $stats
        CopiedPaths = $copiedPaths
    }
}

function Read-WitchyEntries {
    param(
        [Parameter(Mandatory)] [string]$XmlPath
    )

    if (-not (Test-Path -LiteralPath $XmlPath)) {
        throw "XML not found: $XmlPath"
    }

    [xml]$xml = Get-Content -LiteralPath $XmlPath -Raw -Encoding UTF8
    $entries = @{}

    $fileNodes = @($xml.SelectNodes('//files/file'))
    foreach ($fileNode in $fileNodes) {
        $path  = [string]$fileNode.path
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        $flags = [string]$fileNode.flags
        if ([string]::IsNullOrWhiteSpace($flags)) {
            $flags = "Flag1"
        }

        $idValue = [int]([string]$fileNode.id)

        $entries[$path.ToLowerInvariant()] = [pscustomobject]@{
            Path  = $path
            Flags = $flags
            Id    = $idValue
        }
    }

    return $entries
}

function Get-ExistingBucketMaxId {
    param(
        [Parameter(Mandatory)] $ExistingEntries,
        [Parameter(Mandatory)] [ValidateSet('effect', 'tex', 'model')] [string]$Bucket
    )

    $ids = New-Object System.Collections.Generic.List[int]

    foreach ($entry in $ExistingEntries.Values) {
        if ((Get-PathBucket -RelativePath $entry.Path) -eq $Bucket) {
            [void]$ids.Add([int]$entry.Id)
        }
    }

    if ($ids.Count -eq 0) {
        switch ($Bucket) {
            'effect' { return -1 }
            'tex'    { return 99999 }
            'model'  { return 199999 }
        }
    }

    return (($ids | Measure-Object -Maximum).Maximum)
}

function Get-ActualBinderPathsByBucket {
    param(
        [Parameter(Mandatory)] [string]$RootDir
    )

    $result = [ordered]@{
        effect = New-Object System.Collections.Generic.List[string]
        tex    = New-Object System.Collections.Generic.List[string]
        model  = New-Object System.Collections.Generic.List[string]
    }

    foreach ($bucket in @('effect', 'tex', 'model')) {
        $bucketRoot = Join-Path $RootDir $bucket
        if (-not (Test-Path -LiteralPath $bucketRoot)) {
            continue
        }

        Get-ChildItem -LiteralPath $bucketRoot -File -Recurse |
            Sort-Object FullName |
            ForEach-Object {
                $relPath = Get-RelativeBinderPath -RootDir $RootDir -FullPath $_.FullName
                [void]$result[$bucket].Add($relPath)
            }
    }

    return $result
}

function Rewrite-WitchyFilesBlock {
    param(
        [Parameter(Mandatory)] [string]$XmlPath,
        [Parameter(Mandatory)] [string]$RootDir,
        [Parameter(Mandatory)] $ExistingEntries
    )

    $xmlRaw = Get-Content -LiteralPath $XmlPath -Raw -Encoding UTF8
    $pathsByBucket = Get-ActualBinderPathsByBucket -RootDir $RootDir

    $nextIds = @{
        effect = (Get-ExistingBucketMaxId -ExistingEntries $ExistingEntries -Bucket 'effect') + 1
        tex    = (Get-ExistingBucketMaxId -ExistingEntries $ExistingEntries -Bucket 'tex')    + 1
        model  = (Get-ExistingBucketMaxId -ExistingEntries $ExistingEntries -Bucket 'model')  + 1
    }

    $entryLines = New-Object System.Collections.Generic.List[string]
    $counts = [ordered]@{
        effect = 0
        tex    = 0
        model  = 0
        reused = 0
        new    = 0
    }

    foreach ($bucket in @('effect', 'tex', 'model')) {
        foreach ($relPath in $pathsByBucket[$bucket]) {
            $key = $relPath.ToLowerInvariant()

            if ($ExistingEntries.ContainsKey($key)) {
                $entry = $ExistingEntries[$key]
                $idValue = [int]$entry.Id
                $flagsValue = [string]$entry.Flags
                $counts.reused++
            }
            else {
                $idValue = [int]$nextIds[$bucket]
                $nextIds[$bucket] = $idValue + 1
                $flagsValue = "Flag1"
                $counts.new++
            }

            $counts[$bucket]++

            [void]$entryLines.Add("    <file>")
            [void]$entryLines.Add("      <flags>$flagsValue</flags>")
            [void]$entryLines.Add("      <id>$idValue</id>")
            [void]$entryLines.Add("      <path>$relPath</path>")
            [void]$entryLines.Add("    </file>")
        }
    }

    $newFilesBlock = "  <files>`r`n" + ($entryLines -join "`r`n") + "`r`n  </files>"

    $newXml = [regex]::Replace(
        $xmlRaw,
        '(?s)<files>.*?</files>',
        $newFilesBlock,
        1
    )

    if ($newXml -eq $xmlRaw) {
        throw "Failed to rewrite <files> block in: $XmlPath"
    }

    Set-Content -LiteralPath $XmlPath -Value $newXml -Encoding UTF8

    return [pscustomobject]@{
        Counts = $counts
        NextIds = $nextIds
    }
}

# -------------------- Main --------------------

Import-ToolConfig

if (-not $GameRoot) { $GameRoot = Get-OptionalVariableValue -Name 'BBR_GameRoot' }
if (-not $OutputRoot) { $OutputRoot = Get-OptionalVariableValue -Name 'BBR_OutputRoot' }
if (-not $WitchyBndExe) { $WitchyBndExe = Get-OptionalVariableValue -Name 'BBR_WitchyBND_v2_14_4_5' }
if (-not $WitchyBndExe) { $WitchyBndExe = Get-OptionalVariableValue -Name 'BBR_WitchyBnd_v2_14_4_5' }
if (-not $WitchyBndExe) { $WitchyBndExe = Get-OptionalVariableValue -Name 'BBR_WitchyBND_v21445' }
if (-not $WitchyBndExe) { $WitchyBndExe = Get-OptionalVariableValue -Name 'BBR_WitchyBND_21445' }

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
$script:OutputRoot = $OutputRoot

$WitchyBndExe = Resolve-FullPath $WitchyBndExe
$script:WitchyBndExe = $WitchyBndExe

$m24Source = Resolve-GameArchive -GameRootPath $GameRoot -RelativeOrAbsolutePath $M24ArchiveRelativePath -Label 'M24 SFX archive'
$m25Source = Resolve-GameArchive -GameRootPath $GameRoot -RelativeOrAbsolutePath $M25ArchiveRelativePath -Label 'M25 SFX archive'

$sfxOutputRoot = Join-Path $OutputRoot 'BBReborne_sfx'
$finalArchivePath = Join-Path $sfxOutputRoot $OutputRelativePath
Ensure-Dir (Split-Path -Parent $finalArchivePath)

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$runWorkDir = Join-Path (Join-Path $OutputRoot '_work') "sfx_m25_merge_m24_$stamp"
$workArchiveDir = Join-Path $runWorkDir 'archives'
Ensure-Dir $workArchiveDir

$M24Archive = Join-Path $workArchiveDir (Split-Path -Leaf $m24Source.FullPath)
$M25Archive = Join-Path $workArchiveDir (Split-Path -Leaf $m25Source.FullPath)

$overall = [System.Diagnostics.Stopwatch]::StartNew()
$completed = $false

Write-Host "GameRoot      = $GameRoot"
Write-Host "OutputRoot    = $OutputRoot"
Write-Host "WitchyBND     = $WitchyBndExe"
Write-Host "CpuThrottle   = $CpuThrottle"
Write-Host "GpuThrottle   = $GpuThrottle"
Write-Host "M24Source     = $($m24Source.FullPath)"
Write-Host "M25Source     = $($m25Source.FullPath)"
Write-Host "FinalArchive  = $finalArchivePath"
Write-Host "WorkDir       = $runWorkDir"

try {
    Write-Host ""
    Write-Host "0/5 Copy source archives into isolated work folder..." -ForegroundColor Cyan
    Copy-Item -LiteralPath $m24Source.FullPath -Destination $M24Archive -Force
    Copy-Item -LiteralPath $m25Source.FullPath -Destination $M25Archive -Force

    # From this point on, the workflow mirrors the original script's Witchy calls.
    $M24Archive = Resolve-FullPath $M24Archive
    $M25Archive = Resolve-FullPath $M25Archive

    $m24ExtractDir = Get-WitchyExtractDir $M24Archive
    $m25ExtractDir = Get-WitchyExtractDir $M25Archive

    Write-Host "m24ExtractDir = [$m24ExtractDir]"
    Write-Host "m25ExtractDir = [$m25ExtractDir]"

    Ensure-ExtractedArchive `
        -ArchivePath $M24Archive `
        -ExtractDir $m24ExtractDir `
        -Label "1/5 Extract m24 with WitchyBND"

    Ensure-ExtractedArchive `
        -ArchivePath $M25Archive `
        -ExtractDir $m25ExtractDir `
        -Label "2/5 Extract m25 with WitchyBND"

    $m25Xml = Join-Path $m25ExtractDir "_witchy-bnd4.xml"
    if (-not (Test-Path -LiteralPath $m25Xml)) {
        throw "Target Witchy XML not found: $m25Xml"
    }

    $existingM25Entries = Read-WitchyEntries -XmlPath $m25Xml

    $mergeSources = New-Object System.Collections.Generic.List[string]
    [void]$mergeSources.Add($m24ExtractDir)

    if ($IncludeM24Subpacks) {
        foreach ($dir in $ExtraM24ExtractDirs) {
            if (Test-Path -LiteralPath $dir) {
                [void]$mergeSources.Add((Resolve-Path -LiteralPath $dir).Path)
            }
            else {
                Write-Warning "Optional m24 subpack folder not found, skipping: $dir"
            }
        }
    }

    $allTouchedPaths = New-Object System.Collections.Generic.List[string]

    foreach ($sourceDir in $mergeSources) {
        Write-Host ""
        Write-Host "Merging from source: $sourceDir" -ForegroundColor Yellow

        $mergeResult = Merge-BinderContent -SourceDir $sourceDir -TargetDir $m25ExtractDir

        Write-Host ("  effect  copied={0} skipped={1}" -f $mergeResult.Stats.effect.Copied, $mergeResult.Stats.effect.Skipped)
        Write-Host ("  tex     copied={0} skipped={1}" -f $mergeResult.Stats.tex.Copied,    $mergeResult.Stats.tex.Skipped)
        Write-Host ("  model   copied={0} skipped={1}" -f $mergeResult.Stats.model.Copied,  $mergeResult.Stats.model.Skipped)

        foreach ($copiedPath in $mergeResult.CopiedPaths) {
            [void]$allTouchedPaths.Add($copiedPath)
        }
    }

    Write-Host ""
    Write-Host "Rebuilding _witchy-bnd4.xml from merged m25 contents..." -ForegroundColor Cyan
    $rewriteResult = Rewrite-WitchyFilesBlock `
        -XmlPath $m25Xml `
        -RootDir $m25ExtractDir `
        -ExistingEntries $existingM25Entries

    Write-Host ("  files: effect={0} tex={1} model={2}" -f `
        $rewriteResult.Counts.effect, `
        $rewriteResult.Counts.tex, `
        $rewriteResult.Counts.model)

    Write-Host ("  ids: reused={0} new={1}" -f `
        $rewriteResult.Counts.reused, `
        $rewriteResult.Counts.new)

    # Touch XML and all copied files so Witchy sees newer timestamps
    (Get-Item -LiteralPath $m25Xml).LastWriteTime = Get-Date
    foreach ($p in $allTouchedPaths) {
        if (Test-Path -LiteralPath $p) {
            (Get-Item -LiteralPath $p).LastWriteTime = Get-Date
        }
    }

    Write-Host "Waiting 2 seconds so WitchyBND sees updated timestamps..."
    Start-Sleep -Seconds 2

    $beforeWrite = (Get-Item -LiteralPath $M25Archive).LastWriteTimeUtc

    Invoke-External `
        -Label "4/5 Repack m25 with WitchyBND" `
        -FilePath $WitchyBndExe `
        -ArgumentList @($m25ExtractDir)

    $afterWrite = (Get-Item -LiteralPath $M25Archive).LastWriteTimeUtc

    Write-Host ""
    Write-Host "5/5 Done." -ForegroundColor Green

    if ($afterWrite -gt $beforeWrite) {
        Write-Host "Repacked archive timestamp updated."
    }
    else {
        Write-Warning "Archive timestamp did not change. Verify the repack result."
    }

    Copy-Item -LiteralPath $M25Archive -Destination $finalArchivePath -Force
    $finalInfo = Get-Item -LiteralPath $finalArchivePath
    $finalHash = (Get-FileHash -LiteralPath $finalArchivePath -Algorithm SHA256).Hash

    Write-Host ""
    Write-Host "Patched archive written: $finalArchivePath" -ForegroundColor Green
    Write-Host ("Final size: {0:N0} bytes" -f $finalInfo.Length)
    Write-Host "Final SHA256: $finalHash"

    $completed = $true
}
finally {
    $overall.Stop()

    if ($completed -and -not $KeepWork) {
        try {
            Remove-SafeWorkDir -Path $runWorkDir
            Write-Host "Removed isolated work folder: $runWorkDir"
        }
        catch {
            Write-Warning $_.Exception.Message
        }
    }
    else {
        Write-Host "Kept work folder: $runWorkDir"
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ("Elapsed: {0}" -f $overall.Elapsed)

if (-not $completed) {
    exit 1
}
