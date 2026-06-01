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
    01_Mapfiles_BBReborne_FLVER.ps1

    FLVER JSON patch applier.

    Pipeline:
    - Read per-FLVER portable git patches from either:
          <PatchRoot>\<map folder>\_patches\*.flver.patch
          <PatchRoot>\files\<map folder>\_patches\*.flver.patch
          <PatchRoot>\_patches\*.flver.patch
          <PatchRoot>\*.flver.patch
      Legacy <_patches>\files\*.flver.patch is also accepted.
      This supports both the staged generator output (<NewDir>\files\...) and
      the final repository layout where each map folder owns its _patches folder.
    - Match each patch to an original *.flver.dcx in OriginalDir.
    - Copy originals into a safe work folder.
    - Batch decompress copied *.flver.dcx files with WitchyBND:
          m21_00_00_00\m21_00_00_00_0000.flver.dcx -> m21_00_00_00\m21_00_00_00_0000.flver
    - Dump FLVER JSON to the path expected by git apply -p1.
    - Apply each patch with git apply -p1.
    - Rebuild JSON -> FLVER with FlverJsonTool.
    - Batch recompress *.flver -> *.flver.dcx with WitchyBND.
    - Copy patched/recompressed DCX files into OutputDir only after successful rebuild/recompress.
    - Cleanup the safe work folder unless -KeepWork is used.

    Important:
    - OriginalDir is read-only input and is never cleaned or overwritten.
    - PatchDir is read-only input and is never cleaned.
    - OutputDir receives the patched files and owns the scratch work folder.
    - Only a folder whose leaf is exactly "_patch_apply_work" may be deleted/recreated.
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

    # Low-level/direct inputs. Kept so existing manual calls can still work.
    [string]$PatchDir = "",
    [string]$OriginalDir = "",
    [string]$OutputDir = "",
    [string]$WitchyBND = "",

    [Alias("FlverTool")]
    [string]$FlverJsonToolExe = "",

    [string]$GitExe = "git",

    [int]$WitchyBatchSize = 100,
    [int]$ThrottleLimit = [Math]::Max(1, [Math]::Min(4, [int]([Environment]::ProcessorCount / 4))),

    [switch]$RecurseOriginal = $true,
    [switch]$DryRun,
    [switch]$KeepWork,

    [ValidateSet("AutoDedup","FinalRepoOnly","StagedFilesOnly","DirectPatchDirOnly")]
    [string]$PatchSearchMode = "AutoDedup",

    [switch]$PreferThreeWay,

    [string]$WorkDirName = "_patch_apply_work",
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

if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
    Import-Module ThreadJob -ErrorAction Stop
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

    if ($childFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

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

function Test-IsGeneratedScratchPath([string]$Path) {
    $p = ([IO.Path]::GetFullPath($Path) -replace '\\','/')
    return ($p -match '(^|/)(_patch_apply_work|_patch_work|_normalized_patches)(/|$)')
}

function Get-PatchSelectionRank([string]$PatchPath, [string]$Root) {
    # Lower rank wins.
    # Prefer final repository layout:
    #   <map>/_patches/*.flver.patch
    # over temporary staged layout:
    #   files/<map>/_patches/*.flver.patch
    $rel = ([IO.Path]::GetRelativePath($Root, $PatchPath) -replace '\\','/')
    if ($rel -match '(^|/)(_patch_apply_work|_patch_work|_normalized_patches)(/|$)') { return 1000 }
    if ($rel -match '(^|/)files/') { return 20 }
    if ($rel -match '(^|/)_patches/') { return 10 }
    if ($rel -match '/_patches/') { return 10 }
    return 50
}

function Get-FlverBaseFromLeaf([string]$Leaf) {
    if ([string]::IsNullOrWhiteSpace($Leaf)) { return "" }
    $x = $Leaf
    $x = $x -replace '(?i)\.patch$', ''
    $x = $x -replace '(?i)\.dcx$', ''
    $x = $x -replace '(?i)\.flver\.json$', ''
    $x = $x -replace '(?i)\.flver$', ''
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

    # Historical generator output may have a doubled prefix, such as a/a/m21.flver.json.
    if ($aToken.StartsWith('a/')) { $aToken = $aToken.Substring(2) }
    if ($aToken.StartsWith('a/')) { $aToken = $aToken.Substring(2) }
    while ($aToken -match '//') { $aToken = $aToken -replace '//', '/' }
    $aToken = $aToken.TrimStart('/')

    if (-not $aToken.EndsWith('.flver.json', [StringComparison]::OrdinalIgnoreCase)) { return $null }
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


function Find-FlverPatchFiles {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [ValidateSet("AutoDedup","FinalRepoOnly","StagedFilesOnly","DirectPatchDirOnly")]
        [string]$Mode = "AutoDedup"
    )

    $rootFull = [IO.Path]::GetFullPath($Root)
    $found = [System.Collections.Generic.List[object]]::new()

    function Add-PatchesFromDir([string]$Dir, [bool]$Recursive) {
        if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
        $gci = @{ LiteralPath=$Dir; File=$true; Filter="*.flver.patch"; ErrorAction="SilentlyContinue" }
        if ($Recursive) { $gci.Recurse = $true }

        Get-ChildItem @gci |
            Where-Object { $_.Length -gt 0 } |
            Where-Object { -not (Test-IsGeneratedScratchPath $_.FullName) } |
            ForEach-Object { [void]$found.Add($_) }
    }

    function Add-FinalRepoPatchesFromRoot([string]$Dir) {
        if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }

        # If PatchDir itself is one _patches folder.
        if ((Split-Path -Leaf $Dir) -eq "_patches") {
            Add-PatchesFromDir -Dir $Dir -Recursive $false
            return
        }

        # If PatchDir is one final map folder containing _patches.
        $childPatches = Join-Path $Dir "_patches"
        if (Test-Path -LiteralPath $childPatches -PathType Container) {
            Add-PatchesFromDir -Dir $childPatches -Recursive $false
        }

        # If PatchDir is a higher root such as repository\map.
        Get-ChildItem -LiteralPath $Dir -Directory -Filter "_patches" -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $rel = ([IO.Path]::GetRelativePath($Dir, $_.FullName) -replace '\\','/')
                # Final repo mode deliberately ignores staged generator output:
                #   files/<map>/_patches/*.flver.patch
                $rel -notmatch '(^|/)files/'
            } |
            ForEach-Object {
                Add-PatchesFromDir -Dir $_.FullName -Recursive $false
            }
    }

    function Add-StagedFilesPatchesFromRoot([string]$Dir) {
        if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }

        $leaf = Split-Path -Leaf $Dir
        $filesRoot = if ($leaf -eq "files") { $Dir } else { Join-Path $Dir "files" }

        if (Test-Path -LiteralPath $filesRoot -PathType Container) {
            # Staged generator output lives below:
            #   <root>\files\<map>\_patches\*.flver.patch
            Add-PatchesFromDir -Dir $filesRoot -Recursive $true
        }
    }

    switch ($Mode) {
        "DirectPatchDirOnly" {
            Add-PatchesFromDir -Dir $rootFull -Recursive $false
        }

        "FinalRepoOnly" {
            Add-FinalRepoPatchesFromRoot -Dir $rootFull
        }

        "StagedFilesOnly" {
            Add-StagedFilesPatchesFromRoot -Dir $rootFull
        }

        "AutoDedup" {
            # Historical permissive mode:
            # - direct _patches
            # - one map folder with _patches
            # - repository root with many _patches
            # - staged files\<map>\_patches
            # Duplicates are resolved later by JSON target path.
            if ((Split-Path -Leaf $rootFull) -eq "_patches") {
                Add-PatchesFromDir -Dir $rootFull -Recursive $false
                Add-PatchesFromDir -Dir (Join-Path $rootFull "files") -Recursive $true
            }

            $childPatches = Join-Path $rootFull "_patches"
            if (Test-Path -LiteralPath $childPatches -PathType Container) {
                Add-PatchesFromDir -Dir $childPatches -Recursive $false
                Add-PatchesFromDir -Dir (Join-Path $childPatches "files") -Recursive $true
            }

            Get-ChildItem -LiteralPath $rootFull -Directory -Filter "_patches" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                Add-PatchesFromDir -Dir $_.FullName -Recursive $false
                Add-PatchesFromDir -Dir (Join-Path $_.FullName "files") -Recursive $true
            }

            # Staged generator root:
            Add-StagedFilesPatchesFromRoot -Dir $rootFull

            # Fallback for hand-copied patch files directly below PatchDir.
            if ($found.Count -eq 0) {
                Add-PatchesFromDir -Dir $rootFull -Recursive $true
            }
        }
    }

    return @($found | Sort-Object FullName -Unique)
}



# ------------------------------------------------------------
# Resolve tool/GUI-level inputs into the original low-level patcher inputs.
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

# FLVER map patching uses WitchyBND v2.14.4.5.
if ([string]::IsNullOrWhiteSpace($WitchyBND) -and (Test-Path variable:BBR_WitchyBND_v2_14_4_5)) { $WitchyBND = $BBR_WitchyBND_v2_14_4_5 }
if ([string]::IsNullOrWhiteSpace($FlverJsonToolExe) -and (Test-Path variable:BBR_FlverJsonToolExe)) { $FlverJsonToolExe = $BBR_FlverJsonToolExe }
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
            $OutputDir = Join-Path (Join-Path (Join-Path $OutputRoot 'BBReborne_flver') 'map') $targetMapFolders[0]
        } else {
            $OutputDir = Join-Path (Join-Path $OutputRoot 'BBReborne_flver') 'map'
        }
    }
}

foreach ($required in @(
    [pscustomobject]@{ Name='PatchDir'; Value=$PatchDir },
    [pscustomobject]@{ Name='OriginalDir'; Value=$OriginalDir },
    [pscustomobject]@{ Name='OutputDir'; Value=$OutputDir },
    [pscustomobject]@{ Name='WitchyBND'; Value=$WitchyBND },
    [pscustomobject]@{ Name='FlverJsonToolExe'; Value=$FlverJsonToolExe }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
        throw "$($required.Name) is required. Pass it directly or pass ToolPathsPs1/GameRoot/OutputRoot/MapCode so it can be resolved."
    }
}

if (-not [string]::IsNullOrWhiteSpace($MapCode)) { Write-Host ("MapCode:     {0}" -f $MapCode) }
if (-not [string]::IsNullOrWhiteSpace($MapFolder)) { Write-Host ("MapFolder:   {0}" -f $MapFolder) }
if ($targetMapFolders.Count -gt 0) { Write-Host ("TargetMaps:  {0}" -f ($targetMapFolders -join ', ')) }
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
Assert-File $FlverJsonToolExe "FlverJsonToolExe"

$patchRootCmp = $patchRoot.TrimEnd('\')
$origRootCmp  = $origRoot.TrimEnd('\')
$outRootCmp   = $outRoot.TrimEnd('\')

Write-Host ("PatchDir:    {0}" -f $patchRoot)
Write-Host ("OriginalDir: {0}" -f $origRoot)
Write-Host ("OutputDir:   {0}" -f $outRoot)

if (Test-IsSameOrUnderPath -Child $outRoot -Parent $patchRoot) {
    throw "OutputDir must not be the PatchDir or inside PatchDir. PatchDir is an input patch repository: $patchRoot"
}
if (Test-IsSameOrUnderPath -Child $outRoot -Parent $origRoot) {
    throw "OutputDir must not be the OriginalDir or inside OriginalDir. This safe applier does not patch in place: $origRoot"
}

Write-Host ("PatchSearchMode: {0}" -f $PatchSearchMode)
if ($PreferThreeWay) {
    Write-Host "PreferThreeWay: enabled" -ForegroundColor Yellow
}

$patchCandidates = @(Find-FlverPatchFiles -Root $patchRoot -Mode $PatchSearchMode | Where-Object { -not (Test-IsGeneratedScratchPath $_.FullName) })
if ($targetMapFolders.Count -gt 0) {
    $beforeTargetFilter = $patchCandidates.Count
    $patchCandidates = @($patchCandidates | Where-Object { Test-PatchBelongsToTargetMapFolders -PatchFile $_ -TargetMapFolders $targetMapFolders })
    Write-Host ("Filtered FLVER patches by TargetMaps: {0} -> {1}" -f $beforeTargetFilter, $patchCandidates.Count)
}

Write-Host ("Found {0} non-empty FLVER patch candidate file(s)." -f $patchCandidates.Count)
if ($patchCandidates.Count -eq 0) { Write-Host "Nothing to do."; return }

if ($PatchSearchMode -eq "AutoDedup") {
    # De-duplicate patches by the JSON path inside the git header.
    # This prevents staged patches under files\... and final repository patches under map\...
    # from both being applied when PatchDir points at a mixed/staging root.
    $patchByJsonRel = @{}
    $duplicatePatchRows = [System.Collections.Generic.List[object]]::new()

    foreach ($pf in $patchCandidates) {
        $jsonRel = Get-JsonRelFromPatch $pf.FullName
        if (-not $jsonRel) {
            # Keep unparseable candidates so the normal Stage #0 skip message can report them.
            $jsonRel = "__unparsed__/{0}" -f $pf.FullName.ToLowerInvariant()
        }

        if (-not $patchByJsonRel.ContainsKey($jsonRel)) {
            $patchByJsonRel[$jsonRel] = [System.Collections.Generic.List[object]]::new()
        }
        [void]$patchByJsonRel[$jsonRel].Add($pf)
    }

    $selectedPatches = [System.Collections.Generic.List[object]]::new()
    foreach ($jsonRel in ($patchByJsonRel.Keys | Sort-Object)) {
        $group = @($patchByJsonRel[$jsonRel])
        if ($group.Count -gt 1 -and -not $jsonRel.StartsWith("__unparsed__/")) {
            $winner = @($group | Sort-Object @{ Expression = { Get-PatchSelectionRank -PatchPath $_.FullName -Root $patchRoot } }, FullName | Select-Object -First 1)[0]
            foreach ($dupe in $group) {
                [void]$duplicatePatchRows.Add([pscustomobject]@{
                    JsonRel = $jsonRel
                    Selected = ($dupe.FullName -eq $winner.FullName)
                    Rank = Get-PatchSelectionRank -PatchPath $dupe.FullName -Root $patchRoot
                    PatchPath = $dupe.FullName
                })
            }
            [void]$selectedPatches.Add($winner)
        } else {
            foreach ($pf in $group) { [void]$selectedPatches.Add($pf) }
        }
    }

    $patches = @($selectedPatches | Sort-Object FullName)

    if ($duplicatePatchRows.Count -gt 0) {
        Write-Host ("  De-duplicated {0} duplicate patch candidate entries. Using {1} unique patch target(s)." -f $duplicatePatchRows.Count, $patches.Count) -ForegroundColor Yellow
        $dupePreview = @($duplicatePatchRows | Where-Object { -not $_.Selected } | Select-Object -First 12)
        foreach ($d in $dupePreview) {
            Write-Host ("    SKIP duplicate: {0}" -f $d.PatchPath) -ForegroundColor DarkYellow
        }
    }
}
else {
    $patches = @($patchCandidates | Sort-Object FullName -Unique)
}

Write-Host ("Using {0} FLVER patch file(s)." -f $patches.Count)
if ($patches.Count -eq 0) { Write-Host "Nothing to do."; return }

$workRoot = Join-Path $outRoot $WorkDirName
$normPatchDir = Join-Path $workRoot "_normalized_patches"
Write-Host ("WorkDir:     {0}" -f $workRoot)

try {
    if (-not $DryRun) {
        Ensure-Dir $outRoot
        Reset-ScratchFolder -Path $workRoot -ExpectedLeaf $WorkDirName
        Ensure-Dir $normPatchDir
    }

    # ------------------------------------------------------------
    # Stage #0: match patches to original FLVER DCX files
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #0: matching patches -> original .flver.dcx files..."

    $origByBase = @{}
    $allOrig = @()
    if ($RecurseOriginal) {
        $allOrig = @(Get-ChildItem -LiteralPath $origRoot -File -Filter "*.flver.dcx" -Recurse | Sort-Object FullName)
    } else {
        $allOrig = @(Get-ChildItem -LiteralPath $origRoot -File -Filter "*.flver.dcx" | Sort-Object FullName)
    }
    foreach ($f in $allOrig) {
        $base = Get-FlverBaseFromLeaf $f.Name
        if (-not $origByBase.ContainsKey($base)) { $origByBase[$base] = $f.FullName }
    }
    Write-Host ("  Scanned originals: {0}" -f $allOrig.Count)

    $jobs = [System.Collections.Generic.List[object]]::new()
    foreach ($pf in $patches) {
        $jsonRelPosix = Get-JsonRelFromPatch $pf.FullName
        if (-not $jsonRelPosix) {
            Write-Host ("  SKIP: {0} (could not parse .flver.json path from patch header)" -f $pf.Name) -ForegroundColor Yellow
            continue
        }

        $dcxRelPosix = $jsonRelPosix -replace '\.flver\.json$', '.flver.dcx'
        $dcxRelWin = ConvertTo-WindowsRelPath $dcxRelPosix
        $origDcx = $null

        $candidate = Join-Path $origRoot $dcxRelWin
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $origDcx = $candidate }

        $baseName = Get-FlverBaseFromLeaf (Split-Path -Leaf $jsonRelPosix)
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

        $outputRelWin = ConvertTo-WindowsRelPath (Get-RelPath -Root $origRoot -Full $origDcx)

        [void]$jobs.Add([pscustomobject]@{
            PatchPath    = $pf.FullName
            PatchLeaf    = $pf.Name
            FlverBase    = $baseName
            JsonRelPosix = $jsonRelPosix
            JsonRelWin   = ConvertTo-WindowsRelPath $jsonRelPosix
            DcxRelWin    = $dcxRelWin
            OutputRelWin = $outputRelWin
            OrigDcx      = $origDcx
        })
    }

    Write-Host ("  Matched patches: {0} / {1}" -f $jobs.Count, $patches.Count)
    if ($jobs.Count -eq 0) { Write-Host "No matched patches; stopping."; return }

    if ($DryRun) {
        foreach ($j in $jobs) { Write-Host ("  DRY: would read {0}, apply {1}, and write to {2}" -f $j.OrigDcx, $j.PatchLeaf, (Join-Path $outRoot $j.OutputRelWin)) }
        $completed = $true
        return
    }

    # ------------------------------------------------------------
    # Stage #1: copy originals into safe work folder
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #1: copying original FLVER DCX files into work folder..."

    foreach ($j in $jobs) {
        $destDcx = Join-Path $workRoot $j.DcxRelWin
        Ensure-Dir (Split-Path -Parent $destDcx)
        Copy-Item -LiteralPath $j.OrigDcx -Destination $destDcx -Force
    }

    # ------------------------------------------------------------
    # Stage #2: decompress with WitchyBND
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #2: decompressing FLVER DCX with WitchyBND, batchSize={0}..." -f $WitchyBatchSize)

    $dcxList = @($jobs | ForEach-Object { Join-Path $workRoot $_.DcxRelWin })
    Invoke-WitchyBatchSimple -Exe $WitchyBND -Paths $dcxList -BatchSize $WitchyBatchSize -Label "WitchyBND decompress"

    $missingFlver = @()
    foreach ($j in $jobs) {
        $dcxPath = Join-Path $workRoot $j.DcxRelWin
        $flverPath = $dcxPath -replace '\.dcx$', ''
        if (-not (Test-Path -LiteralPath $flverPath -PathType Leaf)) { $missingFlver += $flverPath }
    }
    if ($missingFlver.Count -gt 0) {
        $missingCsv = Join-Path $workRoot "missing_flver_after_witchy.csv"
        $missingFlver | ForEach-Object { [pscustomobject]@{ MissingFlver=$_ } } | Export-Csv -LiteralPath $missingCsv -NoTypeInformation -Encoding UTF8
        throw "Could not locate decompressed FLVER for $($missingFlver.Count) file(s). See: $missingCsv"
    }

    # ------------------------------------------------------------
    # Stage #3: dump JSON to exact path expected by git apply -p1
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #3: dumping FLVER JSON, throttle={0}..." -f $ThrottleLimit)
    Write-Host "  Using captured native process output so parser exceptions are logged per file."

    $dumpJobs = @($jobs | ForEach-Object {
        $dcxPath = Join-Path $workRoot $_.DcxRelWin
        $flverPath = $dcxPath -replace '\.dcx$', ''
        $jsonPath = Join-Path $workRoot $_.JsonRelWin
        [pscustomobject]@{ FlverBase=$_.FlverBase; Flver=$flverPath; Json=$jsonPath }
    })

    # Parallel dump stage. Each FLVER dump is independent, so this mirrors the
    # faster concurrent strategy from Patch-Flvers_Batch_v12 while still capturing
    # stdout/stderr per file for diagnostics.
    $dumpResultsList = [System.Collections.Generic.List[object]]::new()
    $dumpQueue = [System.Collections.Queue]::new()
    foreach ($it in $dumpJobs) { [void]$dumpQueue.Enqueue($it) }

    $dumpRunning = @()
    $dumpTotal = $dumpJobs.Count
    $dumpDone = 0

    Write-Progress -Activity "Dump FLVER JSON" -Status ("0/{0}: starting..." -f $dumpTotal) -PercentComplete 0

    while ($dumpQueue.Count -gt 0 -or $dumpRunning.Count -gt 0) {
        while ($dumpRunning.Count -lt $ThrottleLimit -and $dumpQueue.Count -gt 0) {
            $jobItem = $dumpQueue.Dequeue()
            $dumpRunning += Start-ThreadJob -ArgumentList $jobItem, $FlverJsonToolExe, $DumpCommand -ScriptBlock {
                param($it, $toolExe, $dumpCmd)

                $ok = $false
                $err = ""
                $stdout = ""
                $stderr = ""

                try {
                    if (-not (Test-Path -LiteralPath $it.Flver -PathType Leaf)) { throw "Missing FLVER: $($it.Flver)" }
                    $jsonDir = Split-Path -Parent $it.Json
                    if (-not [string]::IsNullOrWhiteSpace($jsonDir)) {
                        [System.IO.Directory]::CreateDirectory($jsonDir) | Out-Null
                    }

                    $psi = [System.Diagnostics.ProcessStartInfo]::new()
                    $psi.FileName = $toolExe
                    foreach ($arg in @($dumpCmd, $it.Flver, $it.Json)) { [void]$psi.ArgumentList.Add([string]$arg) }
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

                    if ($p.ExitCode -ne 0) {
                        $detail = ($stderr + "`n" + $stdout).Trim()
                        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "FlverJsonTool produced no stderr/stdout." }
                        throw "FlverJsonTool $dumpCmd failed with exit code $($p.ExitCode): $detail"
                    }
                    if (-not (Test-Path -LiteralPath $it.Json -PathType Leaf)) { throw "JSON not produced: $($it.Json)" }
                    $ok = $true
                }
                catch {
                    $err = $_.Exception.Message
                }

                [pscustomobject]@{ FlverBase=$it.FlverBase; Json=$it.Json; Ok=[bool]$ok; Error=$err; StdErr=$stderr; StdOut=$stdout }
            }
        }

        $finished = @($dumpRunning | Where-Object { $_.State -in @("Completed","Failed","Stopped") })
        if ($finished.Count -eq 0) {
            $pct = if ($dumpTotal -gt 0) { [int](100.0 * $dumpDone / $dumpTotal) } else { 100 }
            Write-Progress -Activity "Dump FLVER JSON" -Status ("{0}/{1} done, {2} running..." -f $dumpDone, $dumpTotal, $dumpRunning.Count) -PercentComplete $pct
            Start-Sleep -Milliseconds 200
            continue
        }

        foreach ($job in $finished) {
            try {
                $received = @(Receive-Job -Job $job -ErrorAction Stop)
                if ($received.Count -eq 0) {
                    [void]$dumpResultsList.Add([pscustomobject]@{ FlverBase=""; Json=""; Ok=$false; Error="Thread job produced no result. State=$($job.State)"; StdErr=""; StdOut="" })
                } else {
                    foreach ($row in $received) { [void]$dumpResultsList.Add($row) }
                }
            }
            catch {
                [void]$dumpResultsList.Add([pscustomobject]@{ FlverBase=""; Json=""; Ok=$false; Error="Thread job failed: $($_.Exception.Message)"; StdErr=""; StdOut="" })
            }
            finally {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                $dumpRunning = @($dumpRunning | Where-Object { $_.Id -ne $job.Id })
            }

            $dumpDone++
            $pct = if ($dumpTotal -gt 0) { [int](100.0 * $dumpDone / $dumpTotal) } else { 100 }
            Write-Progress -Activity "Dump FLVER JSON" -Status ("{0}/{1} done..." -f $dumpDone, $dumpTotal) -PercentComplete $pct
        }
    }

    Write-Progress -Activity "Dump FLVER JSON" -Completed
    $dumpResults = @($dumpResultsList)

    $dumpManifest = Join-Path $workRoot "dump_manifest.csv"
    $dumpResults | Sort-Object FlverBase | Export-Csv -LiteralPath $dumpManifest -NoTypeInformation -Encoding UTF8
    $failDump = @($dumpResults | Where-Object { -not $_.Ok })
    if ($failDump.Count -gt 0) {
        $failDump | Select-Object -First 20 | ForEach-Object {
            Write-Host ("  FAIL dump: {0}" -f $_.FlverBase) -ForegroundColor Red
            Write-Host ("             {0}" -f (($_.Error -split "`r?`n") | Select-Object -First 1)) -ForegroundColor Red
        }
        throw "FLVER JSON dump failed for $($failDump.Count) file(s). See: $dumpManifest"
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

    $patchApplyTotal = @($jobs).Count
    $patchApplyN = 0

    Push-Location -LiteralPath $workRoot
    try {
        foreach ($j in $jobs) {
            $patchApplyN++
            $patchApplyPercent = if ($patchApplyTotal -gt 0) { [int](100.0 * $patchApplyN / $patchApplyTotal) } else { 100 }
            Write-Progress `
                -Activity "Apply FLVER JSON patches" `
                -Status ("{0}/{1}: {2}" -f $patchApplyN, $patchApplyTotal, $j.PatchLeaf) `
                -PercentComplete $patchApplyPercent

            $normPatch = Join-Path $normPatchDir $j.PatchLeaf
            Write-NormalizedPatch -srcPatch $j.PatchPath -dstPatch $normPatch

            $targetJson = Join-Path $workRoot $j.JsonRelWin
            if (-not (Test-Path -LiteralPath $targetJson -PathType Leaf)) {
                throw "Patch target JSON is missing for $($j.PatchLeaf): $targetJson"
            }

            $backupJson = "$targetJson.__prepatch__"
            Copy-Item -LiteralPath $targetJson -Destination $backupJson -Force

            if ($PreferThreeWay) {
                $attempts = @(
                    [pscustomobject]@{
                        Name = "3way"
                        Args = @("apply", "-p1", "--3way", "--recount", "--whitespace=nowarn", "--", $normPatch)
                    },
                    [pscustomobject]@{
                        Name = "strict"
                        Args = @("apply", "-p1", "--recount", "--whitespace=nowarn", "--", $normPatch)
                    },
                    [pscustomobject]@{
                        Name = "ignore-space"
                        Args = @("apply", "-p1", "--recount", "--whitespace=nowarn", "--ignore-space-change", "--ignore-whitespace", "--", $normPatch)
                    },
                    [pscustomobject]@{
                        Name = "reject-diagnostic"
                        Args = @("apply", "-p1", "--reject", "--recount", "--whitespace=nowarn", "--", $normPatch)
                    }
                )
            }
            else {
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
            }

            $applied = $false
            $lastExit = $null
            $lastFirstLine = ""
            $lastAttemptName = ""

            foreach ($attempt in $attempts) {
                Write-Progress `
                    -Activity "Apply FLVER JSON patches" `
                    -Status ("{0}/{1}: {2} [{3}]" -f $patchApplyN, $patchApplyTotal, $j.PatchLeaf, $attempt.Name) `
                    -PercentComplete $patchApplyPercent

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
    Write-Progress -Activity "Apply FLVER JSON patches" -Completed
    Write-Host ("Stage #4 done. Applied={0}. Manifest: {1}" -f $patchApplyRows.Count, $patchApplyManifestPath)

    # ------------------------------------------------------------
    # Stage #5: rebuild FLVER from patched JSON
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #5: rebuilding FLVER from patched JSON, throttle={0}..." -f $ThrottleLimit)
    Write-Host "  Using captured native process output so rebuild exceptions are logged per file."

    $rebuildJobs = @($jobs | ForEach-Object {
        $jsonPath = Join-Path $workRoot $_.JsonRelWin
        $flverRelWin = $_.JsonRelWin -replace '\.json$', ''
        $flverPath = Join-Path $workRoot $flverRelWin
        [pscustomobject]@{ FlverBase=$_.FlverBase; Json=$jsonPath; Flver=$flverPath }
    })

    # Parallel rebuild stage. Each JSON -> FLVER rebuild is independent.
    $rebuildResultsList = [System.Collections.Generic.List[object]]::new()
    $rebuildQueue = [System.Collections.Queue]::new()
    foreach ($it in $rebuildJobs) { [void]$rebuildQueue.Enqueue($it) }

    $rebuildRunning = @()
    $rebuildTotal = $rebuildJobs.Count
    $rebuildDone = 0

    Write-Progress -Activity "Rebuild FLVER" -Status ("0/{0}: starting..." -f $rebuildTotal) -PercentComplete 0

    while ($rebuildQueue.Count -gt 0 -or $rebuildRunning.Count -gt 0) {
        while ($rebuildRunning.Count -lt $ThrottleLimit -and $rebuildQueue.Count -gt 0) {
            $jobItem = $rebuildQueue.Dequeue()
            $rebuildRunning += Start-ThreadJob -ArgumentList $jobItem, $FlverJsonToolExe, $RebuildCommand -ScriptBlock {
                param($it, $toolExe, $rebuildCmd)

                $ok = $false
                $err = ""
                $stdout = ""
                $stderr = ""

                try {
                    if (-not (Test-Path -LiteralPath $it.Json -PathType Leaf)) { throw "Missing JSON: $($it.Json)" }

                    $psi = [System.Diagnostics.ProcessStartInfo]::new()
                    $psi.FileName = $toolExe
                    foreach ($arg in @($rebuildCmd, $it.Json, $it.Flver)) { [void]$psi.ArgumentList.Add([string]$arg) }
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

                    if ($p.ExitCode -ne 0) {
                        $detail = ($stderr + "`n" + $stdout).Trim()
                        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "FlverJsonTool produced no stderr/stdout." }
                        throw "FlverJsonTool $rebuildCmd failed with exit code $($p.ExitCode): $detail"
                    }
                    if (-not (Test-Path -LiteralPath $it.Flver -PathType Leaf)) { throw "FLVER not produced: $($it.Flver)" }
                    $ok = $true
                }
                catch {
                    $err = $_.Exception.Message
                }

                [pscustomobject]@{ FlverBase=$it.FlverBase; Flver=$it.Flver; Ok=[bool]$ok; Error=$err; StdErr=$stderr; StdOut=$stdout }
            }
        }

        $finished = @($rebuildRunning | Where-Object { $_.State -in @("Completed","Failed","Stopped") })
        if ($finished.Count -eq 0) {
            $pct = if ($rebuildTotal -gt 0) { [int](100.0 * $rebuildDone / $rebuildTotal) } else { 100 }
            Write-Progress -Activity "Rebuild FLVER" -Status ("{0}/{1} done, {2} running..." -f $rebuildDone, $rebuildTotal, $rebuildRunning.Count) -PercentComplete $pct
            Start-Sleep -Milliseconds 200
            continue
        }

        foreach ($job in $finished) {
            try {
                $received = @(Receive-Job -Job $job -ErrorAction Stop)
                if ($received.Count -eq 0) {
                    [void]$rebuildResultsList.Add([pscustomobject]@{ FlverBase=""; Flver=""; Ok=$false; Error="Thread job produced no result. State=$($job.State)"; StdErr=""; StdOut="" })
                } else {
                    foreach ($row in $received) { [void]$rebuildResultsList.Add($row) }
                }
            }
            catch {
                [void]$rebuildResultsList.Add([pscustomobject]@{ FlverBase=""; Flver=""; Ok=$false; Error="Thread job failed: $($_.Exception.Message)"; StdErr=""; StdOut="" })
            }
            finally {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                $rebuildRunning = @($rebuildRunning | Where-Object { $_.Id -ne $job.Id })
            }

            $rebuildDone++
            $pct = if ($rebuildTotal -gt 0) { [int](100.0 * $rebuildDone / $rebuildTotal) } else { 100 }
            Write-Progress -Activity "Rebuild FLVER" -Status ("{0}/{1} done..." -f $rebuildDone, $rebuildTotal) -PercentComplete $pct
        }
    }

    Write-Progress -Activity "Rebuild FLVER" -Completed
    $rebuildResults = @($rebuildResultsList)

    $rebuildManifest = Join-Path $workRoot "rebuild_manifest.csv"
    $rebuildResults | Sort-Object FlverBase | Export-Csv -LiteralPath $rebuildManifest -NoTypeInformation -Encoding UTF8
    $failRebuild = @($rebuildResults | Where-Object { -not $_.Ok })
    if ($failRebuild.Count -gt 0) {
        $failRebuild | Select-Object -First 20 | ForEach-Object {
            Write-Host ("  FAIL rebuild: {0}" -f $_.FlverBase) -ForegroundColor Red
            Write-Host ("                {0}" -f (($_.Error -split "`r?`n") | Select-Object -First 1)) -ForegroundColor Red
        }
        throw "FLVER rebuild failed for $($failRebuild.Count) file(s). See: $rebuildManifest"
    }
    Write-Host ("Stage #5 done. OK={0}" -f $rebuildResults.Count)

    # ------------------------------------------------------------
    # Stage #6: recompress FLVER -> DCX
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #6: recompressing FLVER -> DCX with WitchyBND, batchSize={0}..." -f $WitchyBatchSize)

    $flverList = @($jobs | ForEach-Object {
        $dcxPath = Join-Path $workRoot $_.DcxRelWin
        $dcxPath -replace '\.dcx$', ''
    })
    Invoke-WitchyBatchSimple -Exe $WitchyBND -Paths $flverList -BatchSize $WitchyBatchSize -Label "WitchyBND recompress"

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
    # Stage #7: write patched DCX files into OutputDir
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #7: writing patched FLVER DCX files into OutputDir..."

    foreach ($j in $jobs) {
        $newDcx = Join-Path $workRoot $j.DcxRelWin
        $destDcx = Join-Path $outRoot $j.OutputRelWin
        Ensure-Dir (Split-Path -Parent $destDcx)
        Copy-Item -LiteralPath $newDcx -Destination $destDcx -Force
    }

    Write-Host "Stage #7 done."
    Write-Host ""
    Write-Host "================ FINAL SUMMARY ================"
    Write-Host ("Patches applied: {0}" -f $jobs.Count)
    Write-Host ("PatchSearchMode: {0}" -f $PatchSearchMode)
    Write-Host ("PreferThreeWay:  {0}" -f ([bool]$PreferThreeWay))
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
