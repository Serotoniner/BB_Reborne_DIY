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
    04_Mapfiles_BBReborne_Maplight_BTPB.ps1

    BTPB JSON patch applier for the BBReborne map tab.

    Tool-level behavior:
    - Resolves M21 -> m21_00_00_00 when -MapCode is provided.
    - Reads patches from:
          <ProjectRoot>\Diffs\map\m21_00_00_00\_patches\*.btpb.patch
    - Reads originals from:
          <GameRoot>\map\m21_00_00_00\*.btpb.dcx
    - Writes patched files to:
          <OutputRoot>\BBReborne_maplight\map\m21_00_00_00\*.btpb.dcx
    - Uses WitchyBND v2.14.4.5 and BBR_BtpbJsonToolExe from the paths file when not passed directly.

    Pipeline:
    - Match each *.btpb.patch to an original *.btpb.dcx.
    - Copy originals into a safe work folder under OutputDir.
    - Batch decompress copied *.btpb.dcx files with WitchyBND.
    - Dump BTPB JSON to the path expected by git apply -p1.
    - Apply each patch with git apply -p1.
    - Rebuild JSON -> BTPB with BtlJsonTool.
    - Batch recompress *.btpb -> *.btpb.dcx with WitchyBND.
    - Copy the patched/recompressed DCX files into OutputDir, preserving the relative path from OriginalDir.

    Important:
    - OriginalDir is read-only input and is never cleaned or overwritten.
    - PatchDir is read-only input and is never cleaned.
    - OutputDir receives the patched files and owns the scratch work folder.
    - Only a folder whose leaf is exactly "_btpb_patch_apply_work" may be deleted/recreated.
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

    [Alias("BtlTool")]
    [string]$BtpbJsonToolExe = "",

    [string]$GitExe = "git",

    [int]$WitchyBatchSize = 50,
    [int]$ThrottleLimit = [Math]::Max(1, [Math]::Min(6, [int]([Environment]::ProcessorCount / 4))),

    [switch]$RecurseOriginal = $false,
    [switch]$DryRun,
    [switch]$KeepWork,

    [string]$WorkDirName = "_btpb_patch_apply_work",
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
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
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

function Get-BBReborneKnownMapFolders {
    return @(
        "m21_00_00_00",
        "m21_01_00_00",
        "m22_00_00_00",
        "m23_00_00_00",
        "m24_00_00_00",
        "m24_01_00_00",
        "m24_02_00_00",
        "m25_00_00_00",
        "m26_00_00_00",
        "m27_00_00_00",
        "m28_00_00_00",
        "m32_00_00_00",
        "m33_00_00_00",
        "m34_00_00_00",
        "m35_00_00_00",
        "m36_00_00_00"
    )
}

function Convert-MapCodeToMapFolder([string]$Code) {
    $clean = ($Code.Trim()).ToLowerInvariant()
    if ($clean -match '^m\d{2}_\d{2}_\d{2}_\d{2}$') { return $clean }
    if ($clean -match '^m\d{2}_\d{2}$') { return ("{0}_00_00" -f $clean) }
    if ($clean -match '^m\d{2}$') { return ("{0}_00_00_00" -f $clean) }
    throw "Unsupported MapCode '$Code'. Expected values like M21, m21_01, or m21_01_00_00."
}

function Resolve-BBReborneTargetMapFolders([string]$MapCode, [string]$MapFolder) {
    if (-not [string]::IsNullOrWhiteSpace($MapFolder)) {
        return @((Convert-MapCodeToMapFolder $MapFolder))
    }

    if ([string]::IsNullOrWhiteSpace($MapCode)) { return @() }

    $clean = $MapCode.Trim().ToLowerInvariant()
    if ($clean -match '^m\d{2}_\d{2}(?:_\d{2}_\d{2})?$') {
        return @((Convert-MapCodeToMapFolder $clean))
    }

    if ($clean -match '^m\d{2}$') {
        $prefix = $clean + '_'
        $matches = @(Get-BBReborneKnownMapFolders | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
        if ($matches.Count -gt 0) { return $matches }
        return @((Convert-MapCodeToMapFolder $clean))
    }

    return @((Convert-MapCodeToMapFolder $clean))
}

function Test-PatchBelongsToTargetMapFolders([object]$PatchFile, [string[]]$TargetMapFolders) {
    $targets = @($TargetMapFolders | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($targets.Count -eq 0) { return $true }

    $leaf = $PatchFile.Name
    $full = ($PatchFile.FullName -replace '\\','/').ToLowerInvariant()
    $jsonRel = Get-JsonRelFromPatch $PatchFile.FullName
    $jsonNorm = ""
    if ($jsonRel) { $jsonNorm = (ConvertTo-PosixPath $jsonRel).ToLowerInvariant() }

    foreach ($folder in $targets) {
        $f = $folder.ToLowerInvariant()
        if ($leaf.StartsWith($folder, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($full.Contains('/' + $f + '/_patches/')) { return $true }
        if ($jsonNorm.StartsWith($f + '/')) { return $true }
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

function Get-BtpbBaseFromLeaf([string]$Leaf) {
    if ([string]::IsNullOrWhiteSpace($Leaf)) { return "" }
    if ($Leaf.EndsWith('.patch', [StringComparison]::OrdinalIgnoreCase)) {
        $Leaf = $Leaf.Substring(0, $Leaf.Length - 6)
    }
    if ($Leaf.EndsWith('.dcx', [StringComparison]::OrdinalIgnoreCase)) {
        $Leaf = $Leaf.Substring(0, $Leaf.Length - 4)
    }
    if ($Leaf.EndsWith('.btpb', [StringComparison]::OrdinalIgnoreCase)) {
        $Leaf = $Leaf.Substring(0, $Leaf.Length - 4)
    }
    if ($Leaf.EndsWith('.btpb.json', [StringComparison]::OrdinalIgnoreCase)) {
        $Leaf = $Leaf.Substring(0, $Leaf.Length - 9)
    }
    return $Leaf
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

    # Historical generator output may have a doubled prefix, such as a/a/m21.btpb.json.
    if ($aToken.StartsWith('a/')) { $aToken = $aToken.Substring(2) }
    if ($aToken.StartsWith('a/')) { $aToken = $aToken.Substring(2) }
    while ($aToken -match '//') { $aToken = $aToken -replace '//', '/' }
    $aToken = $aToken.TrimStart('/')

    if (-not $aToken.EndsWith('.btpb.json', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $aToken
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

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [string]$WorkingDirectory = ""
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add($arg) }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    return [pscustomobject]@{
        ExitCode = [int]$p.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
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


function Find-BtpbPatchFiles([string]$Root) {
    $rootFull = [IO.Path]::GetFullPath($Root)
    $found = [System.Collections.Generic.List[object]]::new()

    function Add-PatchesFromDir([string]$Dir, [bool]$Recursive) {
        if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
        $gci = @{ LiteralPath=$Dir; File=$true; Filter="*.btpb.patch"; ErrorAction="SilentlyContinue" }
        if ($Recursive) { $gci.Recurse = $true }
        Get-ChildItem @gci |
            Where-Object { $_.Length -gt 0 } |
            ForEach-Object { [void]$found.Add($_) }
    }

    # Case 1: PatchDir itself is an _patches folder. Prefer direct files, but
    # also accept the older _patches\files layout.
    if ((Split-Path -Leaf $rootFull) -eq "_patches") {
        Add-PatchesFromDir -Dir $rootFull -Recursive $false
        Add-PatchesFromDir -Dir (Join-Path $rootFull "files") -Recursive $true
    }

    # Case 2: PatchDir is one final map folder containing _patches.
    $childPatches = Join-Path $rootFull "_patches"
    if (Test-Path -LiteralPath $childPatches -PathType Container) {
        Add-PatchesFromDir -Dir $childPatches -Recursive $false
        Add-PatchesFromDir -Dir (Join-Path $childPatches "files") -Recursive $true
    }

    # Case 3: PatchDir is a higher root such as repository\map. Find every
    # final-folder _patches directory and read direct .btpb.patch files.
    Get-ChildItem -LiteralPath $rootFull -Directory -Filter "_patches" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Add-PatchesFromDir -Dir $_.FullName -Recursive $false
        Add-PatchesFromDir -Dir (Join-Path $_.FullName "files") -Recursive $true
    }

    # Fallback for hand-copied patch files directly below PatchDir.
    if ($found.Count -eq 0) {
        Add-PatchesFromDir -Dir $rootFull -Recursive $true
    }

    return @($found | Sort-Object FullName -Unique)
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

$explicitMapFolder = -not [string]::IsNullOrWhiteSpace($MapFolder)
$targetMapFolders = @(Resolve-BBReborneTargetMapFolders -MapCode $MapCode -MapFolder $MapFolder)

if ([string]::IsNullOrWhiteSpace($MapFolder) -and $targetMapFolders.Count -eq 1) {
    $MapFolder = $targetMapFolders[0]
}
if ([string]::IsNullOrWhiteSpace($MapCode) -and -not [string]::IsNullOrWhiteSpace($MapFolder)) {
    $MapCode = (($MapFolder -split '_')[0]).ToUpperInvariant()
}

if ([string]::IsNullOrWhiteSpace($GameRoot) -and (Test-Path variable:BBR_GameRoot)) { $GameRoot = $BBR_GameRoot }
if ([string]::IsNullOrWhiteSpace($OutputRoot) -and (Test-Path variable:BBR_OutputRoot)) { $OutputRoot = $BBR_OutputRoot }

# BTPB patching uses WitchyBND v2.14.4.5.
if ([string]::IsNullOrWhiteSpace($WitchyBND) -and (Test-Path variable:BBR_WitchyBND_v2_14_4_5)) { $WitchyBND = $BBR_WitchyBND_v2_14_4_5 }
if ([string]::IsNullOrWhiteSpace($BtpbJsonToolExe) -and (Test-Path variable:BBR_BtpbJsonToolExe)) { $BtpbJsonToolExe = $BBR_BtpbJsonToolExe }
if (($GitExe -eq "git" -or [string]::IsNullOrWhiteSpace($GitExe)) -and (Test-Path variable:BBR_GitExe) -and -not [string]::IsNullOrWhiteSpace($BBR_GitExe)) { $GitExe = $BBR_GitExe }

if (-not [string]::IsNullOrWhiteSpace($CpuThrottle)) {
    $parsedThrottle = 0
    if ([int]::TryParse($CpuThrottle, [ref]$parsedThrottle) -and $parsedThrottle -gt 0) {
        $ThrottleLimit = $parsedThrottle
    }
}

if ($targetMapFolders.Count -gt 0) {
    $useExactMapFolder = ($explicitMapFolder -and $targetMapFolders.Count -eq 1)
    if ([string]::IsNullOrWhiteSpace($PatchDir)) {
        if ($useExactMapFolder) {
            $PatchDir = Join-Path (Join-Path (Join-Path $projectRoot 'Diffs') 'map') (Join-Path $targetMapFolders[0] '_patches')
        } else {
            $PatchDir = Join-Path (Join-Path $projectRoot 'Diffs') 'map'
        }
    }
    if ([string]::IsNullOrWhiteSpace($OriginalDir)) {
        if ([string]::IsNullOrWhiteSpace($GameRoot)) { throw 'GameRoot is required when OriginalDir is not provided.' }
        if ($useExactMapFolder) {
            $OriginalDir = Join-Path (Join-Path $GameRoot 'map') $targetMapFolders[0]
        } else {
            $OriginalDir = Join-Path $GameRoot 'map'
            $RecurseOriginal = $true
        }
    }
    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        if ([string]::IsNullOrWhiteSpace($OutputRoot)) { throw 'OutputRoot is required when OutputDir is not provided.' }
        if ($useExactMapFolder) {
            $OutputDir = Join-Path (Join-Path (Join-Path $OutputRoot 'BBReborne_maplight') 'map') $targetMapFolders[0]
        } else {
            $OutputDir = Join-Path (Join-Path $OutputRoot 'BBReborne_maplight') 'map'
        }
    }
}

foreach ($required in @(
    [pscustomobject]@{ Name='PatchDir'; Value=$PatchDir },
    [pscustomobject]@{ Name='OriginalDir'; Value=$OriginalDir },
    [pscustomobject]@{ Name='OutputDir'; Value=$OutputDir },
    [pscustomobject]@{ Name='WitchyBND'; Value=$WitchyBND },
    [pscustomobject]@{ Name='BtpbJsonToolExe'; Value=$BtpbJsonToolExe }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
        throw "$($required.Name) is required. Pass it directly or pass ToolPathsPs1/GameRoot/OutputRoot/MapCode so it can be resolved."
    }
}

if ($targetMapFolders.Count -eq 0) {
    throw "MapFolder or MapCode is required for this map-tab BTPB step."
}

if (-not [string]::IsNullOrWhiteSpace($MapCode)) { Write-Host ("MapCode:     {0}" -f $MapCode) }
if (-not [string]::IsNullOrWhiteSpace($MapFolder)) { Write-Host ("MapFolder:   {0}" -f $MapFolder) }
Write-Host ("TargetMaps:  {0}" -f ($targetMapFolders -join ', '))
Write-Host ("ProjectRoot: {0}" -f $projectRoot)

$patchRoot = [IO.Path]::GetFullPath($PatchDir)
$origRoot  = [IO.Path]::GetFullPath($OriginalDir)
$outRoot   = [IO.Path]::GetFullPath($OutputDir)

Assert-Dir  $patchRoot "PatchDir"
Assert-Dir  $origRoot "OriginalDir"
Assert-File $WitchyBND "WitchyBND"
Assert-File $BtpbJsonToolExe "BtpbJsonToolExe"

Write-Host ("PatchDir:    {0}" -f $patchRoot)
Write-Host ("OriginalDir: {0}" -f $origRoot)
Write-Host ("OutputDir:   {0}" -f $outRoot)

if (Test-IsSameOrUnderPath -Child $outRoot -Parent $patchRoot) {
    throw "OutputDir must not be the PatchDir or inside PatchDir. PatchDir is an input patch repository: $patchRoot"
}
if (Test-IsSameOrUnderPath -Child $outRoot -Parent $origRoot) {
    throw "OutputDir must not be the OriginalDir or inside OriginalDir. This safe applier does not patch in place: $origRoot"
}

$patches = @(Find-BtpbPatchFiles -Root $patchRoot)
if ($targetMapFolders.Count -gt 0) {
    $beforeTargetFilter = $patches.Count
    $patches = @($patches | Where-Object { Test-PatchBelongsToTargetMapFolders -PatchFile $_ -TargetMapFolders $targetMapFolders })
    Write-Host ("Filtered BTPB patches by TargetMaps: {0} -> {1}" -f $beforeTargetFilter, $patches.Count)
}

Write-Host ("Found {0} non-empty BTPB patch file(s) for this map." -f $patches.Count)
if ($patches.Count -eq 0) { Write-Host "Nothing to do."; return }

$workRoot = Join-Path $outRoot $WorkDirName
$normPatchDir = Join-Path $workRoot "_normalized_patches"

try {
    if (-not $DryRun) {
        Reset-ScratchFolder -Path $workRoot -ExpectedLeaf $WorkDirName
        Ensure-Dir $normPatchDir
    }

    # ------------------------------------------------------------
    # Stage #0: match patches to original BTPB DCX files
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #0: matching patches -> original .btpb.dcx files..."

    $origByBase = @{}
    $allOrig = @()
    if ($RecurseOriginal) {
        $allOrig = @(Get-ChildItem -LiteralPath $origRoot -File -Filter "*.btpb.dcx" -Recurse | Sort-Object FullName)
    } else {
        $allOrig = @(Get-ChildItem -LiteralPath $origRoot -File -Filter "*.btpb.dcx" | Sort-Object FullName)
    }
    foreach ($f in $allOrig) {
        $base = Get-BtpbBaseFromLeaf $f.Name
        if (-not $origByBase.ContainsKey($base)) { $origByBase[$base] = $f.FullName }
    }
    Write-Host ("  Scanned originals: {0}" -f $allOrig.Count)

    $jobs = [System.Collections.Generic.List[object]]::new()
    foreach ($pf in $patches) {
        $jsonRelPosix = Get-JsonRelFromPatch $pf.FullName
        if (-not $jsonRelPosix) {
            Write-Host ("  SKIP: {0} (could not parse .btpb.json path from patch header)" -f $pf.Name) -ForegroundColor Yellow
            continue
        }

        $dcxRelPosix = $jsonRelPosix -replace '\.btpb\.json$', '.btpb.dcx'
        $dcxRelWin = ConvertTo-WindowsRelPath $dcxRelPosix
        $origDcx = $null

        $candidate = Join-Path $origRoot $dcxRelWin
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $origDcx = $candidate }

        $baseName = Get-BtpbBaseFromLeaf (Split-Path -Leaf $jsonRelPosix)
        if (-not $origDcx -and $origByBase.ContainsKey($baseName)) {
            # Keep the JSON/DCX relative path from the patch header for the work tree,
            # but use the basename match as the real destination to replace. This lets
            # the same patch apply whether OriginalDir is the map root or the specific map folder.
            $origDcx = $origByBase[$baseName]
        }

        if (-not $origDcx) {
            Write-Host ("  MISS: {0} -> {1}" -f $pf.Name, $dcxRelWin) -ForegroundColor Yellow
            continue
        }

        $sourceDcxRelWin = Get-RelPath -Root $origRoot -Full $origDcx
        $outputDcxRelWin = $sourceDcxRelWin

        [void]$jobs.Add([pscustomobject]@{
            PatchPath       = $pf.FullName
            PatchLeaf       = $pf.Name
            BtpbBase         = $baseName
            JsonRelPosix    = $jsonRelPosix
            JsonRelWin      = ConvertTo-WindowsRelPath $jsonRelPosix
            DcxRelWin       = $dcxRelWin
            SourceDcxRelWin = $sourceDcxRelWin
            OutputDcxRelWin = $outputDcxRelWin
            OrigDcx         = $origDcx
        })
    }

    Write-Host ("  Matched patches: {0} / {1}" -f $jobs.Count, $patches.Count)
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
    Write-Host "Stage #1: copying original BTPB DCX files into work folder..."

    foreach ($j in $jobs) {
        $destDcx = Join-Path $workRoot $j.DcxRelWin
        Ensure-Dir (Split-Path -Parent $destDcx)
        Copy-Item -LiteralPath $j.OrigDcx -Destination $destDcx -Force
    }

    # ------------------------------------------------------------
    # Stage #2: decompress with WitchyBND
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #2: decompressing BTPB DCX with WitchyBND, batchSize={0}..." -f $WitchyBatchSize)

    $dcxList = @($jobs | ForEach-Object { Join-Path $workRoot $_.DcxRelWin })
    Invoke-WitchyBatchSimple -Exe $WitchyBND -Paths $dcxList -BatchSize $WitchyBatchSize -Label "WitchyBND decompress"

    $missingBtl = @()
    foreach ($j in $jobs) {
        $dcxPath = Join-Path $workRoot $j.DcxRelWin
        $btpbPath = $dcxPath -replace '\.dcx$', ''
        if (-not (Test-Path -LiteralPath $btpbPath -PathType Leaf)) { $missingBtl += $btpbPath }
    }
    if ($missingBtl.Count -gt 0) {
        $missingCsv = Join-Path $workRoot "missing_btpb_after_witchy.csv"
        $missingBtl | ForEach-Object { [pscustomobject]@{ MissingBtl=$_ } } | Export-Csv -LiteralPath $missingCsv -NoTypeInformation -Encoding UTF8
        throw "Could not locate decompressed BTPB for $($missingBtl.Count) file(s). See: $missingCsv"
    }

    # ------------------------------------------------------------
    # Stage #3: dump JSON to exact path expected by git apply -p1
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #3: dumping BTPB JSON, throttle={0}..." -f $ThrottleLimit)
    Write-Host "  Using captured native process output so parser exceptions are logged per file."

    $dumpJobs = @($jobs | ForEach-Object {
        $dcxPath = Join-Path $workRoot $_.DcxRelWin
        $btpbPath = $dcxPath -replace '\.dcx$', ''
        $jsonPath = Join-Path $workRoot $_.JsonRelWin
        [pscustomobject]@{ BtpbBase=$_.BtpbBase; Btl=$btpbPath; Json=$jsonPath }
    })

    $dumpResultsList = [System.Collections.Generic.List[object]]::new()
    $dumpN = 0
    foreach ($it in $dumpJobs) {
        $dumpN++
        Write-Progress -Activity "Dump BTPB JSON" -Status ("{0}/{1}: {2}" -f $dumpN, $dumpJobs.Count, $it.BtpbBase) -PercentComplete ([int](100.0 * $dumpN / $dumpJobs.Count))

        $ok = $false
        $err = ""
        $stdout = ""
        $stderr = ""
        try {
            if (-not (Test-Path -LiteralPath $it.Btl -PathType Leaf)) { throw "Missing BTPB: $($it.Btl)" }
            Ensure-Dir (Split-Path -Parent $it.Json)
            $res = Invoke-NativeCapture -Exe $BtpbJsonToolExe -Arguments @($DumpCommand, $it.Btl, $it.Json)
            $stdout = $res.StdOut
            $stderr = $res.StdErr
            if ($res.ExitCode -ne 0) {
                $detail = ($stderr + "`n" + $stdout).Trim()
                if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "BtlJsonTool produced no stderr/stdout." }
                throw "BtlJsonTool $DumpCommand failed with exit code $($res.ExitCode): $detail"
            }
            if (-not (Test-Path -LiteralPath $it.Json -PathType Leaf)) { throw "JSON not produced: $($it.Json)" }
            $ok = $true
        }
        catch { $err = $_.Exception.Message }

        [void]$dumpResultsList.Add([pscustomobject]@{ BtpbBase=$it.BtpbBase; Json=$it.Json; Ok=[bool]$ok; Error=$err; StdErr=$stderr; StdOut=$stdout })
    }
    Write-Progress -Activity "Dump BTPB JSON" -Completed

    $dumpResults = @($dumpResultsList)
    $dumpManifest = Join-Path $workRoot "dump_manifest.csv"
    $dumpResults | Sort-Object BtpbBase | Export-Csv -LiteralPath $dumpManifest -NoTypeInformation -Encoding UTF8
    $failDump = @($dumpResults | Where-Object { -not $_.Ok })
    if ($failDump.Count -gt 0) {
        $failDump | Select-Object -First 20 | ForEach-Object {
            Write-Host ("  FAIL dump: {0}" -f $_.BtpbBase) -ForegroundColor Red
            Write-Host ("             {0}" -f (($_.Error -split "`r?`n") | Select-Object -First 1)) -ForegroundColor Red
        }
        throw "BTPB JSON dump failed for $($failDump.Count) file(s). See: $dumpManifest"
    }
    Write-Host ("Stage #3 done. OK={0}" -f $dumpResults.Count)

    # ------------------------------------------------------------
    # Stage #4: apply patches
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #4: applying patches with git apply -p1..."
    Write-Host "  If a strict context match fails, this tries whitespace-tolerant and 3-way modes."
    Write-Host "  Each JSON is restored from a pre-patch backup before every retry."

    $patchApplyManifestPath = Join-Path $workRoot "patch_apply_manifest.csv"
    $patchApplyRows = [System.Collections.Generic.List[object]]::new()

    Push-Location -LiteralPath $workRoot
    try {
        foreach ($j in $jobs) {
            $normPatch = Join-Path $normPatchDir $j.PatchLeaf
            Write-NormalizedPatch -srcPatch $j.PatchPath -dstPatch $normPatch

            $targetJson = Join-Path $workRoot $j.JsonRelWin
            if (-not (Test-Path -LiteralPath $targetJson -PathType Leaf)) {
                throw "Patch target JSON is missing for $($j.PatchLeaf): $targetJson"
            }

            $backupJson = "$targetJson.__prepatch__"
            Copy-Item -LiteralPath $targetJson -Destination $backupJson -Force

            $attempts = @(
                [pscustomobject]@{
                    Name = "strict"
                    Args = @("apply", "-p1", "--recount", "--whitespace=nowarn", "--", $normPatch)
                },
                [pscustomobject]@{
                    Name = "ignore-space"
                    Args = @("apply", "-p1", "--recount", "--whitespace=nowarn", "--ignore-space-change", "--ignore-whitespace", "--", $normPatch)
                },
                [pscustomobject]@{
                    Name = "3way"
                    Args = @("apply", "-p1", "--3way", "--recount", "--whitespace=nowarn", "--", $normPatch)
                },
                [pscustomobject]@{
                    Name = "reject-diagnostic"
                    Args = @("apply", "-p1", "--reject", "--recount", "--whitespace=nowarn", "--", $normPatch)
                }
            )

            $applied = $false
            $lastExit = $null
            $lastFirstLine = ""
            $lastAttemptName = ""

            foreach ($attempt in $attempts) {
                # Always start this attempt from the original dumped JSON, so failed
                # partial applications or conflict markers cannot leak into the next try.
                Copy-Item -LiteralPath $backupJson -Destination $targetJson -Force

                $oldRejects = @(Get-ChildItem -LiteralPath $workRoot -Recurse -File -Filter "*.rej" -ErrorAction SilentlyContinue)
                foreach ($r in $oldRejects) { Remove-Item -LiteralPath $r.FullName -Force -ErrorAction SilentlyContinue }

                $out = @(& $GitExe @($attempt.Args) 2>&1)
                $exit = $LASTEXITCODE
                $rejects = @(Get-ChildItem -LiteralPath $workRoot -Recurse -File -Filter "*.rej" -ErrorAction SilentlyContinue)
                $firstLine = [string](($out | Select-Object -First 1))

                $lastExit = $exit
                $lastFirstLine = $firstLine
                $lastAttemptName = $attempt.Name

                if (($exit -eq 0) -and ($rejects.Count -eq 0)) {
                    $applied = $true
                    [void]$patchApplyRows.Add([pscustomobject]@{
                        Patch      = $j.PatchLeaf
                        JsonRel     = $j.JsonRelPosix
                        Applied     = $true
                        Attempt     = $attempt.Name
                        ExitCode    = $exit
                        RejectFiles = 0
                        Message     = ""
                    })
                    if ($attempt.Name -ne "strict") {
                        Write-Host ("  OK with {0}: {1}" -f $attempt.Name, $j.PatchLeaf) -ForegroundColor Yellow
                    }
                    break
                }

                # Reject mode is diagnostic only here. If it produced rejects or failed,
                # restore the JSON and treat the patch as failed instead of rebuilding a partial file.
                Copy-Item -LiteralPath $backupJson -Destination $targetJson -Force
            }

            if (Test-Path -LiteralPath $backupJson -PathType Leaf) {
                if ($applied) { Remove-Item -LiteralPath $backupJson -Force }
            }

            if (-not $applied) {
                $rejects = @(Get-ChildItem -LiteralPath $workRoot -Recurse -File -Filter "*.rej" -ErrorAction SilentlyContinue)
                [void]$patchApplyRows.Add([pscustomobject]@{
                    Patch      = $j.PatchLeaf
                    JsonRel     = $j.JsonRelPosix
                    Applied     = $false
                    Attempt     = $lastAttemptName
                    ExitCode    = $lastExit
                    RejectFiles = $rejects.Count
                    Message     = $lastFirstLine
                })
                $patchApplyRows | Export-Csv -LiteralPath $patchApplyManifestPath -NoTypeInformation -Encoding UTF8

                Write-Host ("  FAIL: {0}" -f $j.PatchLeaf) -ForegroundColor Red
                Write-Host ("        Target JSON: {0}" -f $targetJson) -ForegroundColor DarkGray
                if ($rejects.Count -gt 0) {
                    Write-Host ("        Reject files: {0}" -f $rejects.Count) -ForegroundColor Red
                    $rejects | Select-Object -First 10 | ForEach-Object { Write-Host ("          {0}" -f $_.FullName) -ForegroundColor Red }
                }
                Write-Host ("        Last git message: {0}" -f $lastFirstLine) -ForegroundColor Red
                throw "Patch apply failed for $($j.PatchLeaf). See: $patchApplyManifestPath"
            }
        }
    }
    finally {
        Pop-Location
        if ($patchApplyRows.Count -gt 0) {
            $patchApplyRows | Export-Csv -LiteralPath $patchApplyManifestPath -NoTypeInformation -Encoding UTF8
        }
    }
    Write-Host ("Stage #4 done. Applied={0}. Manifest: {1}" -f $patchApplyRows.Count, $patchApplyManifestPath)

    # ------------------------------------------------------------
    # Stage #5: rebuild BTPB from patched JSON
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #5: rebuilding BTPB from patched JSON, throttle={0}..." -f $ThrottleLimit)
    Write-Host "  Using captured native process output so rebuild exceptions are logged per file."

    $rebuildJobs = @($jobs | ForEach-Object {
        $jsonPath = Join-Path $workRoot $_.JsonRelWin
        $btpbRelWin = $_.JsonRelWin -replace '\.json$', ''
        $btpbPath = Join-Path $workRoot $btpbRelWin
        [pscustomobject]@{ BtpbBase=$_.BtpbBase; Json=$jsonPath; Btl=$btpbPath }
    })

    $rebuildResultsList = [System.Collections.Generic.List[object]]::new()
    $rebN = 0
    foreach ($it in $rebuildJobs) {
        $rebN++
        Write-Progress -Activity "Rebuild BTPB" -Status ("{0}/{1}: {2}" -f $rebN, $rebuildJobs.Count, $it.BtpbBase) -PercentComplete ([int](100.0 * $rebN / $rebuildJobs.Count))

        $ok = $false
        $err = ""
        $stdout = ""
        $stderr = ""
        try {
            if (-not (Test-Path -LiteralPath $it.Json -PathType Leaf)) { throw "Missing JSON: $($it.Json)" }
            $res = Invoke-NativeCapture -Exe $BtpbJsonToolExe -Arguments @($RebuildCommand, $it.Json, $it.Btl)
            $stdout = $res.StdOut
            $stderr = $res.StdErr
            if ($res.ExitCode -ne 0) {
                $detail = ($stderr + "`n" + $stdout).Trim()
                if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "BtlJsonTool produced no stderr/stdout." }
                throw "BtlJsonTool $RebuildCommand failed with exit code $($res.ExitCode): $detail"
            }
            if (-not (Test-Path -LiteralPath $it.Btl -PathType Leaf)) { throw "BTPB not produced: $($it.Btl)" }
            $ok = $true
        }
        catch { $err = $_.Exception.Message }

        [void]$rebuildResultsList.Add([pscustomobject]@{ BtpbBase=$it.BtpbBase; Btl=$it.Btl; Ok=[bool]$ok; Error=$err; StdErr=$stderr; StdOut=$stdout })
    }
    Write-Progress -Activity "Rebuild BTPB" -Completed

    $rebuildResults = @($rebuildResultsList)
    $rebuildManifest = Join-Path $workRoot "rebuild_manifest.csv"
    $rebuildResults | Sort-Object BtpbBase | Export-Csv -LiteralPath $rebuildManifest -NoTypeInformation -Encoding UTF8
    $failRebuild = @($rebuildResults | Where-Object { -not $_.Ok })
    if ($failRebuild.Count -gt 0) {
        $failRebuild | Select-Object -First 20 | ForEach-Object {
            Write-Host ("  FAIL rebuild: {0}" -f $_.BtpbBase) -ForegroundColor Red
            Write-Host ("                {0}" -f (($_.Error -split "`r?`n") | Select-Object -First 1)) -ForegroundColor Red
        }
        throw "BTPB rebuild failed for $($failRebuild.Count) file(s). See: $rebuildManifest"
    }
    Write-Host ("Stage #5 done. OK={0}" -f $rebuildResults.Count)

    # ------------------------------------------------------------
    # Stage #6: recompress BTPB -> DCX
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #6: recompressing BTPB -> DCX with WitchyBND, batchSize={0}..." -f $WitchyBatchSize)

    $btpbList = @($jobs | ForEach-Object {
        $dcxPath = Join-Path $workRoot $_.DcxRelWin
        $dcxPath -replace '\.dcx$', ''
    })
    Invoke-WitchyBatchSimple -Exe $WitchyBND -Paths $btpbList -BatchSize $WitchyBatchSize -Label "WitchyBND recompress"

    $missingDcx = @()
    foreach ($j in $jobs) {
        $dcxPath = Join-Path $workRoot $j.DcxRelWin
        if (-not (Test-Path -LiteralPath $dcxPath -PathType Leaf)) { $missingDcx += $dcxPath }
    }
    if ($missingDcx.Count -gt 0) {
        $missingCsv = Join-Path $workRoot "missing_dcx_after_recompress.csv"
        $missingDcx | ForEach-Object { [pscustomobject]@{ MissingDcx=$_ } } | Export-Csv -LiteralPath $missingCsv -NoTypeInformation -Encoding UTF8
        throw "Recompress did not produce expected DCX files. See: $missingCsv"
    }

    # ------------------------------------------------------------
    # Stage #7: copy patched files into BBReborne_maplight output
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #7: copying patched BTPB DCX files into OutputDir..."

    foreach ($j in $jobs) {
        $newDcx = Join-Path $workRoot $j.DcxRelWin
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
