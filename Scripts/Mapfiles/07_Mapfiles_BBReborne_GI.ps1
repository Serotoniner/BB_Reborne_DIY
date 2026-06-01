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
    07_Mapfiles_BBReborne_GI.ps1

    GI baked-shadow alpha fixer for the BBReborne map tab.

    Tool-level behavior:
    - Reads original GI archives from:
          <GameRoot>\map\m24\gi_env_m24.tpfbdt
          <GameRoot>\map\m24\gi_env_m24_01.tpfbdt
      and equivalent per-map folders.
    - Copies matching archives into a safe work folder under OutputDir.
    - Extracts the copied archives with WitchyBND v2.14.4.5.
    - Runs the alpha conversion worker on the extracted *-tpfbdt folder using texconv and ImageMagick.
    - Repackages the extracted folder with WitchyBND.
    - Copies both the .tpfbdt and matching .tpfbhd files.
    - Writes final archives under:
          <OutputRoot>\BBReborne_GI\map\m24\gi_env_m24.tpfbdt
          <OutputRoot>\BBReborne_GI\map\m24\gi_env_m24.tpfbhd

    Notes:
    - This script does not edit GameRoot files in place.
    - Only the safe scratch folder whose leaf is exactly _gi_alpha_fix_work is cleaned.
    - The worker script is expected under <ProjectRoot>\Scripts\Textures by default:
          07_Mapfiles_BBReborne_GI_AlphaConst05_BC7.ps1
      It is the existing 02_set_alpha_const_05_bc7_parallel.ps1 logic, standardized for the texture scripts folder.
#>

[CmdletBinding()]
param(
    # Tool/GUI-level inputs.
    [string]$ToolPathsPs1 = "",
    [string]$GameRoot = "",
    [string]$OutputRoot = "",
    [string]$MapCode = "",
    [string]$MapFolder = "",
    [string]$CpuThrottle = "",
    [string]$PwshExe = "",

    # Direct/manual inputs.
    # OriginalDir should be the root containing the short GI map folders, e.g. <GameRoot>\map.
    [string]$OriginalDir = "",
    # OutputDir should be the root that receives the short GI map folders, e.g. <OutputRoot>\BBReborne_GI\map.
    [string]$OutputDir = "",
    [string]$WitchyBND = "",
    [string]$TexconvExe = "",
    [string]$MagickExe = "",
    [string]$AlphaFixScript = "",

    [ValidateRange(0.0, 1.0)]
    [double]$Alpha = 0.5,

    [int]$WitchyBatchSize = 1,
    [int]$ThrottleLimit = [Math]::Max(1, [Math]::Min(6, [int]([Environment]::ProcessorCount - 2))),

    [switch]$DryRun,
    [switch]$KeepWork,
    [switch]$WorkerVerbose,

    [string]$WorkDirName = "_gi_alpha_fix_work"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$global:PSNativeCommandUseErrorActionPreference = $false
$global:PSNativeCommandArgumentPassing = "Standard"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "This script requires PowerShell 7+. Run it with pwsh."
}

function Assert-File([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Name not found: $Path" }
}

function Assert-Dir([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Name not found: $Path" }
}

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Assert-SafeScratchFolder([string]$Path, [string]$ExpectedLeaf) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $leaf = [IO.Path]::GetFileName($full)
    if ($leaf -ne $ExpectedLeaf) {
        throw "Refusing to clean scratch folder because its leaf is not '$ExpectedLeaf': $full"
    }
}

function Reset-ScratchFolder([string]$Path, [string]$ExpectedLeaf) {
    Assert-SafeScratchFolder -Path $Path -ExpectedLeaf $ExpectedLeaf
    if (Test-Path -LiteralPath $Path -PathType Container) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    Ensure-Dir $Path
}

function Get-RelPath([string]$Root, [string]$Full) {
    $rootN = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $fullN = [IO.Path]::GetFullPath($Full)
    if (-not $fullN.StartsWith($rootN, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is not under root. Root='$rootN' Full='$fullN'"
    }
    return $fullN.Substring($rootN.Length)
}

function Get-BBReborneProjectRoot([string]$ToolPathsFile) {
    if (-not [string]::IsNullOrWhiteSpace($ToolPathsFile)) {
        $toolPathsFull = [IO.Path]::GetFullPath($ToolPathsFile)
        $toolRootFromFile = Split-Path -Parent $toolPathsFull
        if ((Split-Path -Leaf $toolRootFromFile) -ieq 'Tools') {
            return (Split-Path -Parent $toolRootFromFile)
        }
    }

    # This script is expected under <ProjectRoot>\Scripts\Mapfiles.
    $scriptsRoot = Split-Path -Parent $PSScriptRoot
    return (Split-Path -Parent $scriptsRoot)
}

function Convert-MapCodeToShortMap([string]$Code) {
    $clean = ($Code.Trim()).ToLowerInvariant()
    if ($clean -match '^m\d{2}$') { return $clean }
    if ($clean -match '^(m\d{2})_\d{2}_\d{2}_\d{2}$') { return $Matches[1] }
    throw "Unsupported MapCode '$Code'. Expected values like M21 or m21_00_00_00."
}

function Get-GiArchiveLeafFromMapFolder([string]$Folder) {
    $clean = ($Folder.Trim()).ToLowerInvariant()
    if ($clean -notmatch '^(m\d{2})_(\d{2})_\d{2}_\d{2}$') {
        throw "Unsupported MapFolder '$Folder'. Expected values like m24_01_00_00."
    }

    $short = $Matches[1]
    $sub   = $Matches[2]

    if ($sub -eq '00') { return "gi_env_$short.tpfbdt" }
    return "gi_env_${short}_$sub.tpfbdt"
}

function Get-GiArchiveTargets {
    param(
        [Parameter(Mandatory=$true)][string]$SourceRoot,
        [string]$MapCodeValue,
        [string]$MapFolderValue
    )

    $targets = [System.Collections.Generic.List[object]]::new()

    if (-not [string]::IsNullOrWhiteSpace($MapFolderValue)) {
        $short = Convert-MapCodeToShortMap $MapFolderValue
        $leaf = Get-GiArchiveLeafFromMapFolder $MapFolderValue
        $path = Join-Path (Join-Path $SourceRoot $short) $leaf
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            [void]$targets.Add((Get-Item -LiteralPath $path))
        }
        return @($targets)
    }

    if (-not [string]::IsNullOrWhiteSpace($MapCodeValue)) {
        $short = Convert-MapCodeToShortMap $MapCodeValue
        $dir = Join-Path $SourceRoot $short
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }

        # GI naming uses the short map folder, with m24 carrying the extra _01 archive.
        # Discovery keeps this compatible with any future gi_env_mXX_NN file without
        # hardcoding nonexistent regular sub-map folders.
        return @(Get-ChildItem -LiteralPath $dir -File -Filter ("gi_env_{0}*.tpfbdt" -f $short) -ErrorAction SilentlyContinue | Sort-Object FullName)
    }

    return @(Get-ChildItem -LiteralPath $SourceRoot -File -Filter "gi_env_*.tpfbdt" -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)
}

function Get-GiHeaderRelPath([string]$ArchiveRelPath) {
    if ($ArchiveRelPath -notmatch '\.tpfbdt$') {
        throw "Expected a .tpfbdt relative path, got: $ArchiveRelPath"
    }
    return ($ArchiveRelPath -replace '\.tpfbdt$', '.tpfbhd').TrimStart()
}

function Get-ExtractFolderForArchive([string]$ArchivePath) {
    $dir = Split-Path -Parent $ArchivePath
    $leaf = Split-Path -Leaf $ArchivePath
    $base = [IO.Path]::GetFileNameWithoutExtension($leaf)
    $ext = [IO.Path]::GetExtension($leaf).TrimStart('.')
    return (Join-Path $dir ("{0}-{1}" -f $base, $ext))
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [string]$WorkingDirectory = "",
        [int[]]$AllowedExitCodes = @(0),
        [string]$Label = "native command"
    )

    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        & $Exe @Arguments
        $code = $LASTEXITCODE
        if ($AllowedExitCodes -notcontains $code) {
            throw "$Label failed with exit code $code. Command: $Exe $($Arguments -join ' ')"
        }
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { Pop-Location }
    }
}

function Invoke-WitchyBatchSimple {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string[]]$Paths,
        [int]$BatchSize = 1,
        [string]$Label = "WitchyBND"
    )

    $total = $Paths.Count
    if ($total -eq 0) { return }

    for ($start = 0; $start -lt $total; $start += $BatchSize) {
        $endExclusive = [Math]::Min($start + $BatchSize, $total)
        $batch = @($Paths[$start..($endExclusive - 1)])
        $batchNum = [int]([Math]::Floor($start / $BatchSize) + 1)
        Write-Host ("  {0} batch {1}: files {2}-{3} ({4} item(s))" -f $Label, $batchNum, ($start + 1), $endExclusive, $batch.Count)
        Invoke-NativeChecked -Exe $Exe -Arguments $batch -Label "$Label batch $batchNum"
    }
}

$timer = [Diagnostics.Stopwatch]::StartNew()
$hadFailure = $false
$completed = $false

# ------------------------------------------------------------
# Resolve optional BBReborne tool-level inputs.
# ------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($ToolPathsPs1)) {
    Assert-File $ToolPathsPs1 "ToolPathsPs1"
    . $ToolPathsPs1
}

$projectRoot = Get-BBReborneProjectRoot -ToolPathsFile $ToolPathsPs1

if ([string]::IsNullOrWhiteSpace($GameRoot) -and (Test-Path variable:BBR_GameRoot)) { $GameRoot = $BBR_GameRoot }
if ([string]::IsNullOrWhiteSpace($OutputRoot) -and (Test-Path variable:BBR_OutputRoot)) { $OutputRoot = $BBR_OutputRoot }
if ([string]::IsNullOrWhiteSpace($WitchyBND) -and (Test-Path variable:BBR_WitchyBND_v2_14_4_5)) { $WitchyBND = $BBR_WitchyBND_v2_14_4_5 }
if ([string]::IsNullOrWhiteSpace($TexconvExe) -and (Test-Path variable:BBR_TexconvExe)) { $TexconvExe = $BBR_TexconvExe }
if ([string]::IsNullOrWhiteSpace($MagickExe) -and (Test-Path variable:BBR_ImageMagickExe)) { $MagickExe = $BBR_ImageMagickExe }
if ([string]::IsNullOrWhiteSpace($PwshExe) -and (Test-Path variable:BBR_Pwsh7Exe)) { $PwshExe = $BBR_Pwsh7Exe }
if ([string]::IsNullOrWhiteSpace($PwshExe)) { $PwshExe = "pwsh" }

if (-not [string]::IsNullOrWhiteSpace($CpuThrottle)) {
    $parsedThrottle = 0
    if ([int]::TryParse($CpuThrottle, [ref]$parsedThrottle) -and $parsedThrottle -gt 0) { $ThrottleLimit = $parsedThrottle }
}
elseif ((Test-Path variable:BBR_CpuThrottle) -and $BBR_CpuThrottle -gt 0) {
    $ThrottleLimit = [int]$BBR_CpuThrottle
}
if ($ThrottleLimit -lt 1) { $ThrottleLimit = 1 }

if ([string]::IsNullOrWhiteSpace($AlphaFixScript)) {
    $texturesRoot = Join-Path (Split-Path -Parent $PSScriptRoot) "Textures"
    $candidate = Join-Path $texturesRoot "07_Mapfiles_BBReborne_GI_AlphaConst05_BC7.ps1"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $AlphaFixScript = $candidate }
    else {
        # Manual/development fallback only. The packaged tool should use Scripts\Textures.
        $legacyBesideWrapper = Join-Path $PSScriptRoot "07_Mapfiles_BBReborne_GI_AlphaConst05_BC7.ps1"
        $legacyOriginalName = Join-Path $PSScriptRoot "02_set_alpha_const_05_bc7_parallel.ps1"
        if (Test-Path -LiteralPath $legacyBesideWrapper -PathType Leaf) { $AlphaFixScript = $legacyBesideWrapper }
        elseif (Test-Path -LiteralPath $legacyOriginalName -PathType Leaf) { $AlphaFixScript = $legacyOriginalName }
    }
}

if ([string]::IsNullOrWhiteSpace($OriginalDir)) {
    if ([string]::IsNullOrWhiteSpace($GameRoot)) { throw 'GameRoot is required when OriginalDir is not provided.' }
    $OriginalDir = Join-Path $GameRoot 'map'
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { throw 'OutputRoot is required when OutputDir is not provided.' }
    $OutputDir = Join-Path (Join-Path $OutputRoot 'BBReborne_GI') 'map'
}

foreach ($required in @(
    [pscustomobject]@{ Name='OriginalDir'; Value=$OriginalDir },
    [pscustomobject]@{ Name='OutputDir'; Value=$OutputDir },
    [pscustomobject]@{ Name='WitchyBND'; Value=$WitchyBND },
    [pscustomobject]@{ Name='TexconvExe'; Value=$TexconvExe },
    [pscustomobject]@{ Name='MagickExe'; Value=$MagickExe },
    [pscustomobject]@{ Name='AlphaFixScript'; Value=$AlphaFixScript }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
        throw "$($required.Name) is required. Pass it directly or pass ToolPathsPs1/GameRoot/OutputRoot/MapCode so it can be resolved."
    }
}

$origRoot = [IO.Path]::GetFullPath($OriginalDir)
$outRoot  = [IO.Path]::GetFullPath($OutputDir)
$workRoot = Join-Path $outRoot $WorkDirName

Assert-Dir  $origRoot "OriginalDir"
Assert-File $WitchyBND "WitchyBND"
Assert-File $TexconvExe "TexconvExe"
Assert-File $MagickExe "MagickExe"
Assert-File $AlphaFixScript "AlphaFixScript"

if (-not [string]::IsNullOrWhiteSpace($MapCode)) { Write-Host ("MapCode:       {0}" -f $MapCode) }
if (-not [string]::IsNullOrWhiteSpace($MapFolder)) { Write-Host ("MapFolder:     {0}" -f $MapFolder) }
Write-Host ("ProjectRoot:   {0}" -f $projectRoot)
Write-Host ("OriginalDir:   {0}" -f $origRoot)
Write-Host ("OutputDir:     {0}" -f $outRoot)
Write-Host ("WorkDir:       {0}" -f $workRoot)
Write-Host ("WitchyBND:     {0}" -f $WitchyBND)
Write-Host ("TexconvExe:    {0}" -f $TexconvExe)
Write-Host ("MagickExe:     {0}" -f $MagickExe)
Write-Host ("AlphaFixScript:{0}" -f $AlphaFixScript)
Write-Host ("Alpha:         {0}" -f $Alpha)
Write-Host ("ThrottleLimit: {0}" -f $ThrottleLimit)

$targets = @(Get-GiArchiveTargets -SourceRoot $origRoot -MapCodeValue $MapCode -MapFolderValue $MapFolder)
Write-Host ("Found {0} GI archive(s) for this selection." -f $targets.Count)
if ($targets.Count -eq 0) {
    Write-Host "Nothing to do."
    return
}

$jobs = @($targets | ForEach-Object {
    $rel = Get-RelPath -Root $origRoot -Full $_.FullName
    $headerRel = Get-GiHeaderRelPath $rel
    $sourceHeader = Join-Path $origRoot $headerRel
    [pscustomobject]@{
        SourcePath = $_.FullName
        RelativePath = $rel
        SourceHeaderPath = $sourceHeader
        HeaderRelativePath = $headerRel
        WorkArchive = Join-Path $workRoot $rel
        WorkHeader = Join-Path $workRoot $headerRel
        OutputArchive = Join-Path $outRoot $rel
        OutputHeader = Join-Path $outRoot $headerRel
        ExtractFolder = Get-ExtractFolderForArchive (Join-Path $workRoot $rel)
    }
})

$missingHeaders = @($jobs | Where-Object { -not (Test-Path -LiteralPath $_.SourceHeaderPath -PathType Leaf) })
if ($missingHeaders.Count -gt 0) {
    $list = ($missingHeaders | ForEach-Object { $_.SourceHeaderPath }) -join "`n"
    throw "Missing required GI header file(s) (.tpfbhd) next to .tpfbdt archive(s):`n$list"
}

if ($DryRun) {
    foreach ($j in $jobs) {
        Write-Host ("  DRY: {0}" -f $j.SourcePath)
        Write-Host ("       header:  {0}" -f $j.SourceHeaderPath)
        Write-Host ("       work:    {0}" -f $j.WorkArchive)
        Write-Host ("       workhdr: {0}" -f $j.WorkHeader)
        Write-Host ("       extract: {0}" -f $j.ExtractFolder)
        Write-Host ("       output:  {0}" -f $j.OutputArchive)
        Write-Host ("       outhdr:  {0}" -f $j.OutputHeader)
    }
    return
}

try {
    Reset-ScratchFolder -Path $workRoot -ExpectedLeaf $WorkDirName

    # ------------------------------------------------------------
    # Stage #1: copy originals into safe work folder
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #1: copying original GI archives into work folder..."
    foreach ($j in $jobs) {
        Ensure-Dir (Split-Path -Parent $j.WorkArchive)
        Copy-Item -LiteralPath $j.SourcePath -Destination $j.WorkArchive -Force
        Copy-Item -LiteralPath $j.SourceHeaderPath -Destination $j.WorkHeader -Force
    }

    # ------------------------------------------------------------
    # Stage #2: extract copied archives with WitchyBND
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #2: extracting GI archives with WitchyBND, batchSize={0}..." -f $WitchyBatchSize)
    Invoke-WitchyBatchSimple -Exe $WitchyBND -Paths @($jobs | ForEach-Object { $_.WorkArchive }) -BatchSize $WitchyBatchSize -Label "WitchyBND extract"

    $missingExtracts = @($jobs | Where-Object { -not (Test-Path -LiteralPath $_.ExtractFolder -PathType Container) })
    if ($missingExtracts.Count -gt 0) {
        $csv = Join-Path $workRoot "missing_gi_extract_folders.csv"
        $missingExtracts | Select-Object SourcePath,WorkArchive,ExtractFolder | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
        throw "Some GI archives did not extract to expected folders. See: $csv"
    }

    # ------------------------------------------------------------
    # Stage #3: run alpha worker on each extracted TPFBDT folder
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #3: applying alpha conversion to extracted DDS files..."

    $n = 0
    foreach ($j in $jobs) {
        $n++
        Write-Host ("  [{0}/{1}] {2}" -f $n, $jobs.Count, $j.ExtractFolder)

        $args = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $AlphaFixScript,
            '-RootDir', $j.ExtractFolder,
            '-TexconvExe', $TexconvExe,
            '-MagickExe', $MagickExe,
            '-Alpha', ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Alpha)),
            '-ThrottleLimit', ([string]$ThrottleLimit),
            '-Recurse',
            '-Apply'
        )
        if ($WorkerVerbose) { $args += '-Verbose' }

        Invoke-NativeChecked -Exe $PwshExe -Arguments $args -Label "GI alpha worker"
    }

    # ------------------------------------------------------------
    # Stage #4: repack extracted folders with WitchyBND
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #4: repacking GI folders with WitchyBND, batchSize={0}..." -f $WitchyBatchSize)
    Invoke-WitchyBatchSimple -Exe $WitchyBND -Paths @($jobs | ForEach-Object { $_.ExtractFolder }) -BatchSize $WitchyBatchSize -Label "WitchyBND repack"

    $missingRepacked = @($jobs | Where-Object { -not (Test-Path -LiteralPath $_.WorkArchive -PathType Leaf) -or -not (Test-Path -LiteralPath $_.WorkHeader -PathType Leaf) })
    if ($missingRepacked.Count -gt 0) {
        $csv = Join-Path $workRoot "missing_gi_repacked_archives.csv"
        $missingRepacked | Select-Object SourcePath,SourceHeaderPath,WorkArchive,WorkHeader,ExtractFolder | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
        throw "Some GI archive/header pairs were not present after repack. See: $csv"
    }

    # ------------------------------------------------------------
    # Stage #5: copy final archives into BBReborne_GI output
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #5: copying patched GI archives into OutputDir..."
    foreach ($j in $jobs) {
        Ensure-Dir (Split-Path -Parent $j.OutputArchive)
        Copy-Item -LiteralPath $j.WorkArchive -Destination $j.OutputArchive -Force
        Copy-Item -LiteralPath $j.WorkHeader -Destination $j.OutputHeader -Force
        Write-Host ("  WROTE: {0}" -f $j.OutputArchive)
        Write-Host ("  WROTE: {0}" -f $j.OutputHeader)
    }

    Write-Host ""
    Write-Host "================ FINAL SUMMARY ================"
    Write-Host ("GI archives processed: {0}" -f $jobs.Count)
    Write-Host ("OriginalDir:           {0}" -f $origRoot)
    Write-Host ("OutputDir:             {0}" -f $outRoot)
    Write-Host ("Elapsed:               {0}" -f $timer.Elapsed.ToString())
    $completed = $true
}
catch {
    $hadFailure = $true
    throw
}
finally {
    Write-Host ""
    Write-Host "Stage #6: cleanup..."
    if ($KeepWork -or $hadFailure -or -not $completed) {
        Write-Host ("  Keeping work folder: {0}" -f $workRoot)
        if ($hadFailure -or -not $completed) { Write-Host "  Kept because the run did not complete successfully." -ForegroundColor Yellow }
    }
    else {
        Assert-SafeScratchFolder -Path $workRoot -ExpectedLeaf $WorkDirName
        if (Test-Path -LiteralPath $workRoot -PathType Container) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force
            Write-Host ("  Removed: {0}" -f $workRoot)
        }
    }
}
