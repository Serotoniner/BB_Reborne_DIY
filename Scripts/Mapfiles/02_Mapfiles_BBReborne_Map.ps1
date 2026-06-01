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
    02_Mapfiles_BBReborne_Map.ps1

    MSB JSON patch applier for the BBReborne map tab.

    Pipeline:
    - Read per-MSB portable git patches from:
          <ProjectRoot>\Diffs\map\mapstudio\_patches\files\*.patch
      or directly from:
          <ProjectRoot>\Diffs\map\mapstudio\_patches\*.patch
    - Filter the patch set to the requested map, for example M21 -> m21_00_00_00.
    - Match the patch to the original game MSB DCX in:
          <GameRoot>\map\mapstudio\m21_00_00_00.msb.dcx
    - Copy originals into a safe work folder under OutputDir.
    - Decompress copied *.msb.dcx files with WitchyBND v2.14.4.5.
    - Dump MSB JSON to the path expected by git apply -p1.
    - Apply the matching patch with git apply -p1.
    - Rebuild JSON -> MSB with MsbbJsonTool.
    - Recompress *.msb -> *.msb.dcx with WitchyBND.
    - Copy the patched/recompressed DCX files into OutputDir, preserving the relative
      path from OriginalDir.

    Important:
    - OriginalDir is read-only input and is never cleaned or overwritten.
    - PatchDir is read-only input and is never cleaned.
    - OutputDir receives the patched files and owns the scratch work folder.
    - Only a folder whose leaf is exactly "_msb_patch_apply_work" may be deleted/recreated.
#>

[CmdletBinding()]
param(
    # Tool/GUI-level inputs. These are the parameters the BBReborne DIY Tool should pass.
    [string]$ToolPathsPs1 = "",
    [string]$GameRoot = "",
    [string]$OutputRoot = "",
    [string]$MapCode = "",
    [string]$MapFolder = "",
    [string]$CpuThrottle = "",

    # Low-level/direct inputs. Kept so manual calls can still work.
    [string]$PatchDir = "",
    [string]$OriginalDir = "",
    [string]$OutputDir = "",
    [string]$WitchyBND = "",

    [Alias("MsbTool")]
    [string]$MsbJsonToolExe = "",

    [string]$GitExe = "git",

    [int]$WitchyBatchSize = 50,
    [int]$ThrottleLimit = [Math]::Max(1, [Math]::Min(6, [int]([Environment]::ProcessorCount / 4))),

    [switch]$RecurseOriginal = $false,
    [switch]$DryRun,
    [switch]$KeepWork,

    [string]$WorkDirName = "_msb_patch_apply_work",
    [string]$DumpCommand = "dump",
    [string]$RebuildCommand = "rebuild"
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

function ConvertTo-WindowsRelPath([string]$Path) {
    return (($Path -replace '/', '\').TrimStart('\'))
}

function ConvertTo-PosixPath([string]$Path) {
    return (($Path -replace '\\','/').TrimStart('/'))
}

function Test-IsSameOrUnderPath([string]$Child, [string]$Parent) {
    $childFull = [IO.Path]::GetFullPath($Child).TrimEnd('\', '/')
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')

    if ($childFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }

    $parentWithSlash = $parentFull + [IO.Path]::DirectorySeparatorChar
    $parentWithAltSlash = $parentFull + [IO.Path]::AltDirectorySeparatorChar

    return (
        $childFull.StartsWith($parentWithSlash, [StringComparison]::OrdinalIgnoreCase) -or
        $childFull.StartsWith($parentWithAltSlash, [StringComparison]::OrdinalIgnoreCase)
    )
}

function Get-RelPath([string]$Root, [string]$Full) {
    $rootN = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $fullN = [IO.Path]::GetFullPath($Full)
    if (-not $fullN.StartsWith($rootN, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is not under root. Root='$rootN' Full='$fullN'"
    }
    return $fullN.Substring($rootN.Length)
}

function Convert-MapCodeToMapFolder([string]$Code) {
    $clean = ($Code.Trim()).ToLowerInvariant()
    if ($clean -match '^m\d{2}_\d{2}_\d{2}_\d{2}$') { return $clean }
    if ($clean -match '^m\d{2}$') { return ("{0}_00_00_00" -f $clean) }
    throw "Unsupported MapCode '$Code'. Expected values like M21 or m21_00_00_00."
}

function Get-MapFoldersForMapCode([string]$Code) {
    $clean = ($Code.Trim()).ToLowerInvariant()
    switch ($clean) {
        'm21' { return @('m21_00_00_00','m21_01_00_00') }
        'm24' { return @('m24_00_00_00','m24_01_00_00','m24_02_00_00') }
        default {
            if ($clean -match '^m\d{2}_\d{2}_\d{2}_\d{2}$') { return @($clean) }
            if ($clean -match '^m\d{2}$') { return @(("{0}_00_00_00" -f $clean)) }
            throw "Unsupported MapCode '$Code'. Expected values like M21 or m21_00_00_00."
        }
    }
}

function Test-TargetMapFolder([string]$BaseName, [string[]]$Targets) {
    foreach ($target in @($Targets)) {
        if ($BaseName.Equals($target, [StringComparison]::OrdinalIgnoreCase)) { return $true }

        # Mapstudio MSB patches can target numbered mapstudio files such as:
        #   m24_00_00_01.patch -> m24_00_00_01.msb.dcx
        # while the map selector/submap list is keyed by:
        #   m24_00_00_00
        # So match by the stable three-part mapstudio prefix, e.g. m24_00_00_.
        $targetPrefix = $target -replace '_[^_]+$', '_'
        if ($BaseName.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
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

function Test-IsGeneratedScratchPath([string]$Path) {
    $p = ([IO.Path]::GetFullPath($Path) -replace '\\','/')
    return ($p -match '(^|/)(_msb_patch_apply_work|_msb_patch_work|_normalized_patches)(/|$)')
}

function Get-MsbBaseFromLeaf([string]$Leaf) {
    if ([string]::IsNullOrWhiteSpace($Leaf)) { return "" }
    $x = $Leaf
    $x = $x -replace '(?i)\.patch$', ''
    $x = $x -replace '(?i)\.dcx$', ''
    $x = $x -replace '(?i)\.msb\.json$', ''
    $x = $x -replace '(?i)\.msb$', ''
    return $x
}

function Get-APathFromPatchHeader([string]$patchPath) {
    $lines = Get-Content -LiteralPath $patchPath -TotalCount 50
    foreach ($line in $lines) {
        if ($line -notmatch '^diff --git\s+') { continue }
        $m = [regex]::Match($line, '^diff --git\s+("([^"]+)"|(\S+))\s+("([^"]+)"|(\S+))\s*$')
        if (-not $m.Success) { return $null }
        if ($m.Groups[2].Success) { return $m.Groups[2].Value }
        return $m.Groups[3].Value
    }
    return $null
}

function Get-JsonRelFromPatch([string]$patchPath) {
    $aToken = Get-APathFromPatchHeader $patchPath
    if (-not $aToken) { return $null }

    $aToken = ConvertTo-PosixPath $aToken

    # Historical generator output may have a doubled prefix, such as a/a/m21.msb.json.
    if ($aToken.StartsWith('a/')) { $aToken = $aToken.Substring(2) }
    if ($aToken.StartsWith('a/')) { $aToken = $aToken.Substring(2) }
    while ($aToken -match '//') { $aToken = $aToken -replace '//', '/' }
    $aToken = $aToken.TrimStart('/')

    # Minimal mapstudio compatibility: some older/generated MSB patches use
    # plain .json in the git header instead of .msb.json. Normalize only that
    # case and leave the rest of the patch pipeline untouched.
    if ($aToken.EndsWith('.msb.json', [StringComparison]::OrdinalIgnoreCase)) { return $aToken }
    if ($aToken.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) {
        return ($aToken -replace '(?i)\.json$', '.msb.json')
    }

    return $null
}

function Write-NormalizedPatch([string]$srcPatch, [string]$dstPatch) {
    $lines = Get-Content -LiteralPath $srcPatch
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        if ($ln -match '^(diff --git|--- |\+\+\+ )') {
            if ($ln -notmatch '/dev/null') {
                $ln = $ln -replace '\\', '/'
                $ln = $ln -replace '("a/)a/', '$1'
                $ln = $ln -replace '("b/)b/', '$1'
                $ln = $ln -replace '(\sa/)a/', '$1'
                $ln = $ln -replace '(\sb/)b/', '$1'
                while ($ln -match '//') { $ln = $ln -replace '//', '/' }

                # Minimal mapstudio compatibility: some older MSB patches use
                # .json in the git header, while this applier dumps/rebuilds
                # the MSB JSON as .msb.json. Keep the pipeline untouched and
                # normalize only patch header path lines so git apply targets
                # the JSON file this script actually writes.
                $ln = $ln -replace '(?i)(?<!\.msb)\.json(?=$|\s|")', '.msb.json'
            }
        }
        $lines[$i] = $ln
    }
    Set-Content -LiteralPath $dstPatch -Value $lines -Encoding UTF8
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
        & $Exe @Arguments | Out-Null
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
        [int]$BatchSize = 50,
        [string]$Label = "WitchyBND"
    )

    $total = $Paths.Count
    if ($total -eq 0) { return }

    for ($start = 0; $start -lt $total; $start += $BatchSize) {
        $endExclusive = [Math]::Min($start + $BatchSize, $total)
        $batch = @($Paths[$start..($endExclusive - 1)])
        $batchNum = [int]([Math]::Floor($start / $BatchSize) + 1)
        Write-Host ("  {0} batch {1}: files {2}-{3} ({4} files)" -f $Label, $batchNum, ($start + 1), $endExclusive, $batch.Count)
        Invoke-NativeChecked -Exe $Exe -Arguments $batch -Label "$Label batch $batchNum"
    }
}

function Find-MsbPatchFiles([string]$Root) {
    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($dir in @((Join-Path $Root 'files'), $Root)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $dir -File -Filter "*.patch" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Length -gt 0 -and $_.Name -ine 'all_changed_msb_json.patch' -and -not (Test-IsGeneratedScratchPath $_.FullName)) {
                [void]$result.Add($_)
            }
        }
    }

    return @($result | Sort-Object FullName -Unique)
}

# ------------------------------------------------------------
# Resolve tool/GUI-level inputs into the low-level patcher inputs.
# ------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($ToolPathsPs1)) {
    Assert-File $ToolPathsPs1 "ToolPathsPs1"
    . $ToolPathsPs1
}

$projectRoot = Get-BBReborneProjectRoot -ToolPathsFile $ToolPathsPs1
$explicitMapFolder = -not [string]::IsNullOrWhiteSpace($MapFolder)

if ([string]::IsNullOrWhiteSpace($MapFolder) -and -not [string]::IsNullOrWhiteSpace($MapCode)) {
    $MapFolder = Convert-MapCodeToMapFolder $MapCode
}
if ([string]::IsNullOrWhiteSpace($MapCode) -and -not [string]::IsNullOrWhiteSpace($MapFolder)) {
    $MapCode = (($MapFolder -split '_')[0]).ToUpperInvariant()
}

$TargetMapFolders = @()
if ($explicitMapFolder -and -not [string]::IsNullOrWhiteSpace($MapFolder)) {
    $TargetMapFolders = @($MapFolder.ToLowerInvariant())
}
elseif (-not [string]::IsNullOrWhiteSpace($MapCode)) {
    $TargetMapFolders = @(Get-MapFoldersForMapCode -Code $MapCode)
}
elseif (-not [string]::IsNullOrWhiteSpace($MapFolder)) {
    $TargetMapFolders = @($MapFolder.ToLowerInvariant())
}

if ([string]::IsNullOrWhiteSpace($GameRoot) -and (Test-Path variable:BBR_GameRoot)) { $GameRoot = $BBR_GameRoot }
if ([string]::IsNullOrWhiteSpace($OutputRoot) -and (Test-Path variable:BBR_OutputRoot)) { $OutputRoot = $BBR_OutputRoot }

# MSB map patching uses WitchyBND v2.14.4.5.
if ([string]::IsNullOrWhiteSpace($WitchyBND) -and (Test-Path variable:BBR_WitchyBND_v2_14_4_5)) { $WitchyBND = $BBR_WitchyBND_v2_14_4_5 }
if ([string]::IsNullOrWhiteSpace($MsbJsonToolExe) -and (Test-Path variable:BBR_MsbbJsonToolExe)) { $MsbJsonToolExe = $BBR_MsbbJsonToolExe }
if (($GitExe -eq "git" -or [string]::IsNullOrWhiteSpace($GitExe)) -and (Test-Path variable:BBR_GitExe) -and -not [string]::IsNullOrWhiteSpace($BBR_GitExe)) { $GitExe = $BBR_GitExe }

if (-not [string]::IsNullOrWhiteSpace($CpuThrottle)) {
    $parsedThrottle = 0
    if ([int]::TryParse($CpuThrottle, [ref]$parsedThrottle) -and $parsedThrottle -gt 0) {
        $ThrottleLimit = $parsedThrottle
    }
}

if (-not [string]::IsNullOrWhiteSpace($MapFolder)) {
    if ([string]::IsNullOrWhiteSpace($PatchDir)) {
        $PatchDir = Join-Path (Join-Path (Join-Path $projectRoot 'Diffs') 'map') (Join-Path 'mapstudio' '_patches')
    }
    if ([string]::IsNullOrWhiteSpace($OriginalDir)) {
        if ([string]::IsNullOrWhiteSpace($GameRoot)) { throw 'GameRoot is required when OriginalDir is not provided.' }
        $OriginalDir = Join-Path (Join-Path $GameRoot 'map') 'mapstudio'
    }
    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        if ([string]::IsNullOrWhiteSpace($OutputRoot)) { throw 'OutputRoot is required when OutputDir is not provided.' }
        $OutputDir = Join-Path (Join-Path (Join-Path $OutputRoot 'BBReborne_map') 'map') 'mapstudio'
    }
}

foreach ($required in @(
    [pscustomobject]@{ Name='PatchDir'; Value=$PatchDir },
    [pscustomobject]@{ Name='OriginalDir'; Value=$OriginalDir },
    [pscustomobject]@{ Name='OutputDir'; Value=$OutputDir },
    [pscustomobject]@{ Name='WitchyBND'; Value=$WitchyBND },
    [pscustomobject]@{ Name='MsbJsonToolExe'; Value=$MsbJsonToolExe }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
        throw "$($required.Name) is required. Pass it directly or pass ToolPathsPs1/GameRoot/OutputRoot/MapCode so it can be resolved."
    }
}

if (@($TargetMapFolders).Count -eq 0) {
    throw "MapFolder or MapCode is required for this map-tab step, so the global mapstudio patch folder is filtered to one map."
}

if (-not [string]::IsNullOrWhiteSpace($MapCode)) { Write-Host ("MapCode:     {0}" -f $MapCode) }
Write-Host ("MapFolder:   {0}" -f $MapFolder)
Write-Host ("Target MSBs:  {0}" -f ((@($TargetMapFolders) -join ', ')))
Write-Host ("ProjectRoot: {0}" -f $projectRoot)

$timer = [Diagnostics.Stopwatch]::StartNew()
$hadFailure = $false
$completed = $false

$patchRoot = [IO.Path]::GetFullPath($PatchDir)
$origRoot  = [IO.Path]::GetFullPath($OriginalDir)
$outRoot   = [IO.Path]::GetFullPath($OutputDir)

Assert-Dir  $patchRoot "PatchDir"
Assert-Dir  $origRoot "OriginalDir"
Assert-File $WitchyBND "WitchyBND"
Assert-File $MsbJsonToolExe "MsbJsonToolExe"

Write-Host ("PatchDir:    {0}" -f $patchRoot)
Write-Host ("OriginalDir: {0}" -f $origRoot)
Write-Host ("OutputDir:   {0}" -f $outRoot)

if (Test-IsSameOrUnderPath -Child $outRoot -Parent $patchRoot) {
    throw "OutputDir must not be the PatchDir or inside PatchDir. PatchDir is an input patch repository: $patchRoot"
}
if (Test-IsSameOrUnderPath -Child $outRoot -Parent $origRoot) {
    throw "OutputDir must not be the OriginalDir or inside OriginalDir. This safe applier does not patch in place: $origRoot"
}

$workRoot = Join-Path $outRoot $WorkDirName
$normPatchDir = Join-Path $workRoot "_normalized_patches"

$patchCandidates = @(Find-MsbPatchFiles -Root $patchRoot)
Write-Host ("Found {0} non-empty MSB patch candidate file(s)." -f $patchCandidates.Count)
if ($patchCandidates.Count -eq 0) { Write-Host "Nothing to do."; return }

try {
    if (-not $DryRun) {
        Ensure-Dir $outRoot
        Reset-ScratchFolder -Path $workRoot -ExpectedLeaf $WorkDirName
        Ensure-Dir $normPatchDir
    }

    # ------------------------------------------------------------
    # Stage #0: match patches to the requested original MSB DCX file
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #0: matching patches -> original .msb.dcx files..."

    $origByBase = @{}
    $allOrig = @()
    if ($RecurseOriginal) {
        $allOrig = @(Get-ChildItem -LiteralPath $origRoot -File -Filter "*.msb.dcx" -Recurse | Sort-Object FullName)
    } else {
        $allOrig = @(Get-ChildItem -LiteralPath $origRoot -File -Filter "*.msb.dcx" | Sort-Object FullName)
    }
    foreach ($f in $allOrig) {
        $base = Get-MsbBaseFromLeaf $f.Name
        if (-not $origByBase.ContainsKey($base)) { $origByBase[$base] = $f.FullName }
    }
    Write-Host ("  Scanned originals: {0}" -f $allOrig.Count)

    $jobs = [System.Collections.Generic.List[object]]::new()
    $seenPatchJsonRel = @{}
    foreach ($pf in $patchCandidates) {
        $jsonRelPosix = Get-JsonRelFromPatch $pf.FullName
        $baseName = ""

        if ($jsonRelPosix) {
            $baseName = Get-MsbBaseFromLeaf (Split-Path -Leaf $jsonRelPosix)
        } else {
            $baseName = Get-MsbBaseFromLeaf $pf.Name
            if ([string]::IsNullOrWhiteSpace($baseName)) {
                Write-Host ("  SKIP: {0} (could not parse .msb.json path from patch header)" -f $pf.Name) -ForegroundColor Yellow
                continue
            }
            $jsonRelPosix = ("{0}.msb.json" -f $baseName)
        }

        if (-not (Test-TargetMapFolder -BaseName $baseName -Targets $TargetMapFolders)) {
            continue
        }

        $jsonKey = $jsonRelPosix.ToLowerInvariant()
        if ($seenPatchJsonRel.ContainsKey($jsonKey)) {
            Write-Host ("  SKIP duplicate patch for {0}: {1}" -f $jsonRelPosix, $pf.FullName) -ForegroundColor Yellow
            continue
        }
        $seenPatchJsonRel[$jsonKey] = $pf.FullName

        $dcxRelPosix = $jsonRelPosix -replace '\.msb\.json$', '.msb.dcx'
        $dcxRelWin = ConvertTo-WindowsRelPath $dcxRelPosix
        $origDcx = $null

        $candidate = Join-Path $origRoot $dcxRelWin
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $origDcx = $candidate }

        if (-not $origDcx -and $origByBase.ContainsKey($baseName)) {
            $origDcx = $origByBase[$baseName]
        }

        if (-not $origDcx) {
            Write-Host ("  MISS: {0} -> {1}" -f $pf.Name, $dcxRelWin) -ForegroundColor Yellow
            continue
        }

        # Final output mirrors the matched original relative path, not necessarily the patch header path.
        $finalDcxRelWin = Get-RelPath -Root $origRoot -Full $origDcx

        [void]$jobs.Add([pscustomobject]@{
            PatchPath       = $pf.FullName
            PatchLeaf       = $pf.Name
            MsbBase         = $baseName
            JsonRelPosix    = $jsonRelPosix
            JsonRelWin      = ConvertTo-WindowsRelPath $jsonRelPosix
            SourceDcxRelWin = $finalDcxRelWin
            OutputDcxRelWin = $finalDcxRelWin
            OrigDcx         = $origDcx
        })
    }

    Write-Host ("  Matched patches for {0}: {1}" -f ((@($TargetMapFolders) -join ', '), $jobs.Count))
    if ($jobs.Count -eq 0) { Write-Host "No matched patches; stopping."; return }

    if ($DryRun) {
        foreach ($j in $jobs) {
            $dest = Join-Path $outRoot $j.OutputDcxRelWin
            Write-Host ("  DRY: would patch {0}" -f $j.OrigDcx)
            Write-Host ("       -> {0}" -f $dest)
            Write-Host ("       using {0}" -f $j.PatchPath)
        }
        $completed = $true
        return
    }

    # ------------------------------------------------------------
    # Stage #1: copy originals into safe work folder
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #1: copying original MSB DCX files into work folder..."

    foreach ($j in $jobs) {
        $destDcx = Join-Path $workRoot $j.SourceDcxRelWin
        Ensure-Dir (Split-Path -Parent $destDcx)
        Copy-Item -LiteralPath $j.OrigDcx -Destination $destDcx -Force
    }

    # ------------------------------------------------------------
    # Stage #2: decompress with WitchyBND
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #2: decompressing MSB DCX with WitchyBND, batchSize={0}..." -f $WitchyBatchSize)

    $dcxList = @($jobs | ForEach-Object { Join-Path $workRoot $_.SourceDcxRelWin })
    Invoke-WitchyBatchSimple -Exe $WitchyBND -Paths $dcxList -BatchSize $WitchyBatchSize -Label "WitchyBND decompress"

    $missingMsb = @()
    foreach ($j in $jobs) {
        $dcxPath = Join-Path $workRoot $j.SourceDcxRelWin
        $msbPath = $dcxPath -replace '\.dcx$', ''
        if (-not (Test-Path -LiteralPath $msbPath -PathType Leaf)) { $missingMsb += $msbPath }
    }
    if ($missingMsb.Count -gt 0) {
        $missingCsv = Join-Path $workRoot "missing_msb_after_witchy.csv"
        $missingMsb | ForEach-Object { [pscustomobject]@{ MissingMsb=$_ } } | Export-Csv -LiteralPath $missingCsv -NoTypeInformation -Encoding UTF8
        throw "Could not locate decompressed MSB for $($missingMsb.Count) file(s). See: $missingCsv"
    }

    # ------------------------------------------------------------
    # Stage #3: dump JSON to exact path expected by git apply -p1
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #3: dumping MSB JSON, throttle={0}..." -f $ThrottleLimit)

    $dumpJobs = @($jobs | ForEach-Object {
        $dcxPath = Join-Path $workRoot $_.SourceDcxRelWin
        $msbPath = $dcxPath -replace '\.dcx$', ''
        $jsonPath = Join-Path $workRoot $_.JsonRelWin
        [pscustomobject]@{ MsbBase=$_.MsbBase; Msb=$msbPath; Json=$jsonPath }
    })

    $dumpResults = @($dumpJobs | ForEach-Object -Parallel {
        $it = $_
        try {
            $exe = $using:MsbJsonToolExe
            $cmd = $using:DumpCommand
            if (-not (Test-Path -LiteralPath $it.Msb -PathType Leaf)) { throw "Missing MSB: $($it.Msb)" }
            $jsonDir = Split-Path -Parent $it.Json
            if (-not (Test-Path -LiteralPath $jsonDir -PathType Container)) { New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null }
            & $exe $cmd $it.Msb $it.Json | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "MsbJsonTool $cmd failed with exit code $LASTEXITCODE" }
            if (-not (Test-Path -LiteralPath $it.Json -PathType Leaf)) { throw "JSON not produced: $($it.Json)" }
            [pscustomobject]@{ MsbBase=$it.MsbBase; Json=$it.Json; Ok=$true; Error="" }
        }
        catch {
            [pscustomobject]@{ MsbBase=$it.MsbBase; Json=$it.Json; Ok=$false; Error=$_.Exception.Message }
        }
    } -ThrottleLimit $ThrottleLimit)

    $dumpManifest = Join-Path $workRoot "dump_manifest.csv"
    $dumpResults | Sort-Object MsbBase | Export-Csv -LiteralPath $dumpManifest -NoTypeInformation -Encoding UTF8
    $failDump = @($dumpResults | Where-Object { -not $_.Ok })
    if ($failDump.Count -gt 0) { throw "MSB JSON dump failed for $($failDump.Count) file(s). See: $dumpManifest" }
    Write-Host ("Stage #3 done. OK={0}" -f $dumpResults.Count)

    # ------------------------------------------------------------
    # Stage #4: apply patches
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #4: applying patches with git apply -p1..."

    Push-Location -LiteralPath $workRoot
    try {
        foreach ($j in $jobs) {
            $normPatch = Join-Path $normPatchDir $j.PatchLeaf
            Write-NormalizedPatch -srcPatch $j.PatchPath -dstPatch $normPatch

            $checkOut = @(& $GitExe apply -p1 --recount --whitespace=nowarn --check -- $normPatch 2>&1)
            if ($LASTEXITCODE -ne 0) {
                $first = ($checkOut | Select-Object -First 1)
                throw "Patch check failed for $($j.PatchLeaf): $first"
            }

            $applyOut = @(& $GitExe apply -p1 --recount --whitespace=nowarn -- $normPatch 2>&1)
            if ($LASTEXITCODE -ne 0) {
                $first = ($applyOut | Select-Object -First 1)
                throw "Patch apply failed for $($j.PatchLeaf): $first"
            }
        }
    }
    finally { Pop-Location }
    Write-Host "Stage #4 done."

    # ------------------------------------------------------------
    # Stage #5: rebuild MSB from patched JSON
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #5: rebuilding MSB from patched JSON, throttle={0}..." -f $ThrottleLimit)

    $rebuildJobs = @($jobs | ForEach-Object {
        $jsonPath = Join-Path $workRoot $_.JsonRelWin
        $msbRelWin = $_.JsonRelWin -replace '\.json$', ''
        $msbPath = Join-Path $workRoot $msbRelWin
        [pscustomobject]@{ MsbBase=$_.MsbBase; Json=$jsonPath; Msb=$msbPath }
    })

    $rebuildResults = @($rebuildJobs | ForEach-Object -Parallel {
        $it = $_
        try {
            $exe = $using:MsbJsonToolExe
            $cmd = $using:RebuildCommand
            if (-not (Test-Path -LiteralPath $it.Json -PathType Leaf)) { throw "Missing JSON: $($it.Json)" }
            $msbDir = Split-Path -Parent $it.Msb
            if (-not (Test-Path -LiteralPath $msbDir -PathType Container)) { New-Item -ItemType Directory -Path $msbDir -Force | Out-Null }
            & $exe $cmd $it.Json $it.Msb | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "MsbJsonTool $cmd failed with exit code $LASTEXITCODE" }
            if (-not (Test-Path -LiteralPath $it.Msb -PathType Leaf)) { throw "MSB not produced: $($it.Msb)" }
            [pscustomobject]@{ MsbBase=$it.MsbBase; Msb=$it.Msb; Ok=$true; Error="" }
        }
        catch {
            [pscustomobject]@{ MsbBase=$it.MsbBase; Msb=$it.Msb; Ok=$false; Error=$_.Exception.Message }
        }
    } -ThrottleLimit $ThrottleLimit)

    $rebuildManifest = Join-Path $workRoot "rebuild_manifest.csv"
    $rebuildResults | Sort-Object MsbBase | Export-Csv -LiteralPath $rebuildManifest -NoTypeInformation -Encoding UTF8
    $failRebuild = @($rebuildResults | Where-Object { -not $_.Ok })
    if ($failRebuild.Count -gt 0) { throw "MSB rebuild failed for $($failRebuild.Count) file(s). See: $rebuildManifest" }
    Write-Host ("Stage #5 done. OK={0}" -f $rebuildResults.Count)

    # ------------------------------------------------------------
    # Stage #6: recompress rebuilt MSB -> DCX
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #6: recompressing rebuilt MSB -> DCX with WitchyBND, batchSize={0}..." -f $WitchyBatchSize)

    $msbList = @($jobs | ForEach-Object {
        $msbRelWin = $_.JsonRelWin -replace '\.json$', ''
        Join-Path $workRoot $msbRelWin
    })
    Invoke-WitchyBatchSimple -Exe $WitchyBND -Paths $msbList -BatchSize $WitchyBatchSize -Label "WitchyBND recompress"

    $missingDcx = @()
    foreach ($j in $jobs) {
        $msbRelWin = $j.JsonRelWin -replace '\.json$', ''
        $dcxPath = (Join-Path $workRoot $msbRelWin) + '.dcx'
        if (-not (Test-Path -LiteralPath $dcxPath -PathType Leaf)) { $missingDcx += $dcxPath }
    }
    if ($missingDcx.Count -gt 0) {
        $missingCsv = Join-Path $workRoot "missing_dcx_after_recompress.csv"
        $missingDcx | ForEach-Object { [pscustomobject]@{ MissingDcx=$_ } } | Export-Csv -LiteralPath $missingCsv -NoTypeInformation -Encoding UTF8
        throw "Recompress did not produce expected DCX files. See: $missingCsv"
    }

    # ------------------------------------------------------------
    # Stage #7: copy patched files into BBReborne_map output
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #7: copying patched MSB DCX files into OutputDir..."

    foreach ($j in $jobs) {
        $msbRelWin = $j.JsonRelWin -replace '\.json$', ''
        $newDcx = (Join-Path $workRoot $msbRelWin) + '.dcx'
        $destDcx = Join-Path $outRoot $j.OutputDcxRelWin
        Ensure-Dir (Split-Path -Parent $destDcx)
        Copy-Item -LiteralPath $newDcx -Destination $destDcx -Force
        Write-Host ("  WROTE: {0}" -f $destDcx)
    }

    Write-Host "Stage #7 done."
    Write-Host ""
    Write-Host "================ FINAL SUMMARY ================"
    Write-Host ("Patches applied: {0}" -f $jobs.Count)
    Write-Host ("OriginalDir:     {0}" -f $origRoot)
    Write-Host ("OutputDir:       {0}" -f $outRoot)
    Write-Host ("Elapsed:         {0}" -f $timer.Elapsed.ToString())
    $completed = $true
}
catch {
    $hadFailure = $true
    throw
}
finally {
    Write-Host ""
    Write-Host "Stage #8: cleanup..."
    if ($DryRun) {
        Write-Host ("  DRY: would remove work folder: {0}" -f $workRoot)
    }
    elseif ($KeepWork -or $hadFailure -or -not $completed) {
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
