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
    08_Mapfiles_BBReborne_Textures.ps1

    Map textures wrapper for the BBReborne map tab.

    Behavior:
    - Resolves tools from the BBReborne tool paths file.
    - Copies the selected map texture archives from <GameRoot>\map into
      <OutputRoot>\BBReborne_textures\map, preserving the same relative paths.
    - Copies matching .tpfbhd files when present next to .tpfbdt files.
    - Runs the existing per-package texture pipeline in place on the copied output files.
    - Uses per-map settings from the existing commands_upscale_v2 workflow.

    Notes:
    - The actual worker scripts live under Scripts\Textures and are called by this wrapper.
    - Only m24 has extra sub-map texture packages (m24_01_*), so M24 processes both base m24_* and m24_01_*.
#>

[CmdletBinding()]
param(
    [string]$ToolPathsPs1 = "",
    [string]$GameRoot = "",
    [string]$OutputRoot = "",
    [string]$MapCode = "",
    [string]$MapFolder = "",
    [string]$PwshExe = "",

    [string]$WitchyBndExe = "",
    [string]$TexturesRoot = "",
    [string]$TexconvExe = "",
    [string]$RealEsrganExe = "",
    [string]$RealEsrganModelName = "",
    [string]$RealEsrganModelFile = "",
    [string]$MagickExe = "",

    [string]$DiffuseScript = "",
    [string]$LinearScript = "",
    [string]$HeightScript = "",
    [string]$ReflectanceScript = "",
    [string]$SpecularScript = "",
    [string]$RepackLScript = "",

    [string]$CpuThrottle = "",
    [string]$GpuThrottle = "",
    [int]$ThrottleLimit = 2,
    [int]$GpuThrottleLimit = 2,
    [switch]$ContinueOnError,
    [string[]]$OnlyGroups,
    [switch]$Keep,
    [switch]$NoApply,
    [switch]$RepackL,
    [switch]$DryRun,
    [switch]$NoUpscale
)

$PreRepackDeleteFolders = @{
    "m25\m25_0000" = @(
	"m25_carpet_621_n-tpf-dcx"
	"m25_carpet_621_r_l-tpf-dcx"
	"m25_carpet_621_r-tpf-dcx"
	"m25_carpet_621_s_l-tpf-dcx"
	"m25_carpet_621_s-tpf-dcx"
	"m25_carpet_621_a_l-tpf-dcx"
	"m25_carpet_621_a-tpf-dcx"
	"m25_carpet_621_n_l-tpf-dcx"
    )
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Format-Duration {
    param([TimeSpan]$TimeSpan)
    $hours = ($TimeSpan.Days * 24) + $TimeSpan.Hours
    "{0:00}:{1:00}:{2:00}" -f $hours, $TimeSpan.Minutes, $TimeSpan.Seconds
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

function Get-BBReborneProjectRoot([string]$ToolPathsFile) {
    if (-not [string]::IsNullOrWhiteSpace($ToolPathsFile)) {
        $toolPathsFull = [IO.Path]::GetFullPath($ToolPathsFile)
        $toolRootFromFile = Split-Path -Parent $toolPathsFull
        if ((Split-Path -Leaf $toolRootFromFile) -ieq 'Tools') {
            return (Split-Path -Parent $toolRootFromFile)
        }
    }
    $scriptsRoot = Split-Path -Parent $PSScriptRoot
    return (Split-Path -Parent $scriptsRoot)
}

function Invoke-External {
    param(
        [Parameter(Mandatory)] [string]$Label,
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [object[]]$ArgumentList
    )
    Write-Host $Label -ForegroundColor Cyan
    & $FilePath @ArgumentList
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Label failed with exit code $exitCode"
    }
}

function Invoke-PwshScript {
    param(
        [Parameter(Mandatory)] [string]$Label,
        [Parameter(Mandatory)] [string]$ScriptPath,
        [Parameter(Mandatory)] [object[]]$Args
    )
    Invoke-External -Label $Label -FilePath $PwshExe -ArgumentList (@('-File', $ScriptPath) + $Args)
}

function Get-CommonArgs {
    param([string]$RootDir)
    @(
        '-RootDir',    $RootDir,
        '-TexconvExe', $TexconvExe,
        '-MagickExe',  $MagickExe
    )
}

function Convert-MapCodeToTextureGroup([string]$Code) {
    $clean = ($Code.Trim()).ToLowerInvariant()
    if ($clean -match '^m\d{2}$') { return $clean }
    if ($clean -match '^(m\d{2})_\d{2}_\d{2}_\d{2}$') { return $Matches[1] }
    throw "Unsupported map selection '$Code'. Expected values like M21 or m24_01_00_00."
}

function Get-TexturePackagePrefixFromMapFolder([string]$Folder) {
    $clean = ($Folder.Trim()).ToLowerInvariant()
    if ($clean -notmatch '^(m\d{2})_(\d{2})_\d{2}_\d{2}$') {
        throw "Unsupported MapFolder '$Folder'. Expected values like m24_01_00_00."
    }
    $short = $Matches[1]
    $sub = $Matches[2]
    if ($sub -eq '00') { return $short }
    return ('{0}_{1}' -f $short, $sub)
}

function Get-HeaderPathIfPresent([string]$DataPath) {
    $candidate = $DataPath -replace '\.tpfbdt$', '.tpfbhd'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return ''
}

function Copy-StageTexturePackage {
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$DestFile
    )
    Ensure-Dir (Split-Path -Parent $DestFile)
    Copy-Item -LiteralPath $SourceFile -Destination $DestFile -Force
    $srcHeader = Get-HeaderPathIfPresent $SourceFile
    if (-not [string]::IsNullOrWhiteSpace($srcHeader)) {
        $dstHeader = $DestFile -replace '\.tpfbdt$', '.tpfbhd'
        Copy-Item -LiteralPath $srcHeader -Destination $dstHeader -Force
    }
}

function Remove-PreRepackFolders {
    param(
        [Parameter(Mandatory)] [string]$WorkRoot,
        [Parameter(Mandatory)] [string]$GroupName,
        [Parameter(Mandatory)] [string]$PackageName
    )

    $keysToCheck = @(
        "$GroupName\$PackageName",
        $PackageName,
        $GroupName
    )

    $foldersToDelete = New-Object System.Collections.Generic.List[string]

    foreach ($key in $keysToCheck) {
        if ($PreRepackDeleteFolders.ContainsKey($key)) {
            foreach ($rel in @($PreRepackDeleteFolders[$key])) {
                if (-not [string]::IsNullOrWhiteSpace($rel)) {
                    [void]$foldersToDelete.Add($rel)
                }
            }
        }
    }

    $uniqueFolders = @($foldersToDelete | Select-Object -Unique)
    if ($uniqueFolders.Count -eq 0) { return }

    Write-Host "Pre-repack folder deletions:" -ForegroundColor DarkYellow

    foreach ($rel in $uniqueFolders) {
        $target = Join-Path $WorkRoot $rel
        if (Test-Path -LiteralPath $target) {
            Write-Host ("  DELETE {0}" -f $target) -ForegroundColor DarkYellow
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        else {
            Write-Host ("  SKIP missing {0}" -f $target) -ForegroundColor DarkYellow
        }
    }
}

function Invoke-TexturePipeline {
    param(
        [Parameter(Mandatory)] [string]$GroupName,
        [Parameter(Mandatory)] [string]$PackageName,
        [Parameter(Mandatory)] [hashtable]$Profile
    )

    $archivePath = Join-Path $TexturesRoot "$GroupName\$PackageName.tpfbdt"
    $workRoot    = Join-Path $TexturesRoot "$GroupName\$PackageName-tpfbdt"

    if (-not (Test-Path -LiteralPath $archivePath)) {
        throw "Archive not found: $archivePath"
    }

    $pkgTimer = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor DarkGray
    Write-Host "Processing $GroupName\$PackageName" -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor DarkGray
    Write-Host ("Mode: Apply={0}  Keep={1}" -f (-not $NoApply), $Keep) -ForegroundColor DarkCyan

    try {
        Invoke-External -Label '1/7 Extract with WitchyBND' -FilePath $WitchyBndExe -ArgumentList @($archivePath)

        $commonArgs = Get-CommonArgs -RootDir $workRoot
        $applyArgs = @()
        if (-not $NoApply) { $applyArgs += '-Apply' }
        $keepArgs = @()
        if ($Keep) { $keepArgs += '-Keep' }
        $noUpscaleArgs = @()
        if ($NoUpscale) { $noUpscaleArgs += '-NoUpscale' }
        $realEsrganModelArgs = @()
        if (-not [string]::IsNullOrWhiteSpace($RealEsrganModelName)) { $realEsrganModelArgs += @('-RealEsrganModelName', $RealEsrganModelName) }
        if (-not [string]::IsNullOrWhiteSpace($RealEsrganModelFile)) { $realEsrganModelArgs += @('-RealEsrganModelFile', $RealEsrganModelFile) }

        $diffuseArgs = $commonArgs + @('-RealEsrganExe', $RealEsrganExe, '-ThrottleLimit', $GpuThrottleLimit) + $realEsrganModelArgs + $applyArgs + $keepArgs + $noUpscaleArgs
        Invoke-PwshScript -Label '2/7 Upscale diffuse' -ScriptPath $DiffuseScript -Args $diffuseArgs

        $linearArgs = $commonArgs + $applyArgs + $keepArgs + $noUpscaleArgs
        Invoke-PwshScript -Label '3/7 Upscale linear' -ScriptPath $LinearScript -Args $linearArgs

        $heightArgs = $commonArgs + $Profile.HeightArgs + $applyArgs + $keepArgs
        Invoke-PwshScript -Label '4/7 Fix height' -ScriptPath $HeightScript -Args $heightArgs

        $reflectanceArgs = $commonArgs + $Profile.ReflectanceArgs + $applyArgs + $keepArgs
        Invoke-PwshScript -Label '5/7 Fix reflectance' -ScriptPath $ReflectanceScript -Args $reflectanceArgs

        $specularArgs = $commonArgs + $Profile.SpecularArgs + $applyArgs + $keepArgs
        Invoke-PwshScript -Label '6/7 Fix specular' -ScriptPath $SpecularScript -Args $specularArgs

        # RepackL repair is always required for this texture pipeline.
        $repackLArgs = @('-RootDir', $workRoot, '-TexconvExe', $TexconvExe, '-ThrottleLimit', $ThrottleLimit)
        if ($Keep) { $repackLArgs += '-Keep' }
        Invoke-PwshScript -Label '6.5/7 Repair _l DDS before repack' -ScriptPath $RepackLScript -Args $repackLArgs

        Remove-PreRepackFolders -WorkRoot $workRoot -GroupName $GroupName -PackageName $PackageName
        Invoke-External -Label '7/7 Repack with WitchyBND' -FilePath $WitchyBndExe -ArgumentList @($workRoot)

        if (-not $Keep) {
            Write-Host 'Cleanup texture work folder and Witchy backup files...' -ForegroundColor DarkGray
            if (Test-Path -LiteralPath $workRoot -PathType Container) {
                Remove-Item -LiteralPath $workRoot -Recurse -Force
            }

            $headerPath = $archivePath -replace '\.tpfbdt$', '.tpfbhd'
            $backupPaths = @(
                ($archivePath + '.bak'),
                ($headerPath + '.bak')
            )
            foreach ($backupPath in $backupPaths) {
                if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                    Remove-Item -LiteralPath $backupPath -Force
                }
            }

            $repackLTempFolders = @(
                ($workRoot + '_backup_original_dds_repack_l'),
                ($workRoot + '_repack_l_repair')
            )
            foreach ($tempFolder in $repackLTempFolders) {
                if (Test-Path -LiteralPath $tempFolder -PathType Container) {
                    Remove-Item -LiteralPath $tempFolder -Recurse -Force
                }
            }
        }

        $pkgTimer.Stop()
        Write-Host ("DONE  {0}\{1}   [{2}]" -f $GroupName, $PackageName, (Format-Duration $pkgTimer.Elapsed)) -ForegroundColor Green
    }
    catch {
        $pkgTimer.Stop()
        Write-Host ("FAIL  {0}\{1}   [{2}]" -f $GroupName, $PackageName, (Format-Duration $pkgTimer.Elapsed)) -ForegroundColor Red
        throw
    }
}

# ------------------------------------------------------------
# Resolve BBReborne tool paths and script defaults.
# ------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($ToolPathsPs1)) {
    Assert-File $ToolPathsPs1 'ToolPathsPs1'
    . $ToolPathsPs1
}

$projectRoot = Get-BBReborneProjectRoot -ToolPathsFile $ToolPathsPs1
$texturesScriptRoot = Join-Path (Join-Path $projectRoot 'Scripts') 'Textures'

if ([string]::IsNullOrWhiteSpace($GameRoot) -and (Test-Path variable:BBR_GameRoot)) { $GameRoot = $BBR_GameRoot }
if ([string]::IsNullOrWhiteSpace($OutputRoot) -and (Test-Path variable:BBR_OutputRoot)) { $OutputRoot = $BBR_OutputRoot }
if ([string]::IsNullOrWhiteSpace($PwshExe) -and (Test-Path variable:BBR_Pwsh7Exe)) { $PwshExe = $BBR_Pwsh7Exe }
if ([string]::IsNullOrWhiteSpace($PwshExe)) { $PwshExe = 'pwsh' }
if ([string]::IsNullOrWhiteSpace($WitchyBndExe) -and (Test-Path variable:BBR_WitchyBND_v3_0_0_1)) { $WitchyBndExe = $BBR_WitchyBND_v3_0_0_1 }
if ([string]::IsNullOrWhiteSpace($TexconvExe) -and (Test-Path variable:BBR_TexconvExe)) { $TexconvExe = $BBR_TexconvExe }
if ([string]::IsNullOrWhiteSpace($RealEsrganExe) -and (Test-Path variable:BBR_RealEsrganExe)) { $RealEsrganExe = $BBR_RealEsrganExe }
if ([string]::IsNullOrWhiteSpace($MagickExe) -and (Test-Path variable:BBR_ImageMagickExe)) { $MagickExe = $BBR_ImageMagickExe }

if ([string]::IsNullOrWhiteSpace($TexturesRoot)) {
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { throw 'OutputRoot is required when TexturesRoot is not provided.' }
    $TexturesRoot = Join-Path (Join-Path (Join-Path $OutputRoot 'BBReborne_textures') 'map') ''
}

if ([string]::IsNullOrWhiteSpace($DiffuseScript))     { $DiffuseScript     = Join-Path $texturesScriptRoot '01_Mapfiles_BBReborne_Textures_Upscale_Diffuse_2x_AI.ps1' }
if ([string]::IsNullOrWhiteSpace($LinearScript))      { $LinearScript      = Join-Path $texturesScriptRoot '02_Mapfiles_BBReborne_Textures_Upscale_Data_Linear_RGBA_BC1.ps1' }
if ([string]::IsNullOrWhiteSpace($HeightScript))      { $HeightScript      = Join-Path $texturesScriptRoot '03_Mapfiles_BBReborne_Textures_HeightFix_N_Blue_From_RG.ps1' }
if ([string]::IsNullOrWhiteSpace($ReflectanceScript)) { $ReflectanceScript = Join-Path $texturesScriptRoot '04_Mapfiles_BBReborne_Textures_Reflectance_Fix.ps1' }
if ([string]::IsNullOrWhiteSpace($SpecularScript))    { $SpecularScript    = Join-Path $texturesScriptRoot '05_Mapfiles_BBReborne_Textures_Specular_Fix.ps1' }
if ([string]::IsNullOrWhiteSpace($RepackLScript))     { $RepackLScript     = Join-Path $texturesScriptRoot '06_Mapfiles_BBReborne_Textures_Repack_L_Repair.ps1' }

if (-not [string]::IsNullOrWhiteSpace($CpuThrottle)) {
    $parsedThrottle = 0
    if ([int]::TryParse($CpuThrottle, [ref]$parsedThrottle) -and $parsedThrottle -gt 0) { $ThrottleLimit = $parsedThrottle }
}
elseif ((Test-Path variable:BBR_CpuThrottle) -and $BBR_CpuThrottle -gt 0) {
    $ThrottleLimit = [int]$BBR_CpuThrottle
}
if ($ThrottleLimit -lt 1) { $ThrottleLimit = 1 }

if (-not [string]::IsNullOrWhiteSpace($GpuThrottle)) {
    $parsedGpuThrottle = 0
    if ([int]::TryParse($GpuThrottle, [ref]$parsedGpuThrottle) -and $parsedGpuThrottle -gt 0) { $GpuThrottleLimit = $parsedGpuThrottle }
}
elseif ((Test-Path variable:BBR_GpuThrottle) -and $BBR_GpuThrottle -gt 0) {
    $GpuThrottleLimit = [int]$BBR_GpuThrottle
}
if ($GpuThrottleLimit -lt 1) { $GpuThrottleLimit = 1 }

$sourceTexturesRoot = if (-not [string]::IsNullOrWhiteSpace($GameRoot)) { Join-Path $GameRoot 'map' } else { '' }

foreach ($required in @(
    [pscustomobject]@{ Name='GameRoot'; Value=$GameRoot },
    [pscustomobject]@{ Name='OutputRoot'; Value=$OutputRoot },
    [pscustomobject]@{ Name='WitchyBndExe'; Value=$WitchyBndExe },
    [pscustomobject]@{ Name='TexconvExe'; Value=$TexconvExe },
    [pscustomobject]@{ Name='RealEsrganExe'; Value=$RealEsrganExe },
    [pscustomobject]@{ Name='MagickExe'; Value=$MagickExe },
    [pscustomobject]@{ Name='DiffuseScript'; Value=$DiffuseScript },
    [pscustomobject]@{ Name='LinearScript'; Value=$LinearScript },
    [pscustomobject]@{ Name='HeightScript'; Value=$HeightScript },
    [pscustomobject]@{ Name='ReflectanceScript'; Value=$ReflectanceScript },
    [pscustomobject]@{ Name='SpecularScript'; Value=$SpecularScript },
    [pscustomobject]@{ Name='RepackLScript'; Value=$RepackLScript }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
        throw "$($required.Name) is required. Pass it directly or via ToolPathsPs1/GameRoot/OutputRoot."
    }
}

Assert-Dir $sourceTexturesRoot 'Source map root'
Assert-File $PwshExe 'PwshExe'
Assert-File $WitchyBndExe 'WitchyBndExe'
Assert-File $TexconvExe 'TexconvExe'
Assert-File $RealEsrganExe 'RealEsrganExe'
Assert-File $MagickExe 'MagickExe'
Assert-File $DiffuseScript 'DiffuseScript'
Assert-File $LinearScript 'LinearScript'
Assert-File $HeightScript 'HeightScript'
Assert-File $ReflectanceScript 'ReflectanceScript'
Assert-File $SpecularScript 'SpecularScript'
Assert-File $RepackLScript 'RepackLScript'
Ensure-Dir $TexturesRoot

$Profiles = @{
	#T=18m
    m21 = @{
		HeightArgs = @(
		"-BlueMin", 0,
		"-BlueMax", 1,
		"-CompressStart", 0.55,
		"-CompressFull", 0.90
		)
        ReflectanceArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.01,
		"-KneeMax", 1.00,
		"-SigmaLo", 0.0025,
		"-SigmaHi", 0.0125,
		"-PostScale", 0.75,
		"-HighlightStart", 0.35,
		"-MaxSpec", 0,
		"-FlatBrightMeanMin", 0.42,
		"-FlatBrightSigmaMax", 0.01,
		"-FlatBrightScale", 0.25
        )
        SpecularArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.60,
		"-KneeMax", 0.95,
		"-SigmaLo", 0.015,
		"-SigmaHi", 0.04,
		"-HighlightStart", 0.05,
		"-PostScale", 0.7,
		"-MaxSpec", 0
        )
	}
	
	#T=24m
    m22 = @{
		HeightArgs = @(
		"-BlueMin", 0.20, # if m21_00_ground_051 where not to break 0 and 1 (also looks good as is)
		"-BlueMax", 0.80,
		"-CompressStart", 0.55,
		"-CompressFull", 0.90
		)
        ReflectanceArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.01,
		"-KneeMax", 1.00,
		"-SigmaLo", 0.0025,
		"-SigmaHi", 0.0125,
		"-PostScale", 0.75,
		"-HighlightStart", 0.35,
		"-MaxSpec", 0,
		"-FlatBrightMeanMin", 0.42,
		"-FlatBrightSigmaMax", 0.01,
		"-FlatBrightScale", 0.25
        )
        SpecularArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.75,
		"-KneeMax", 0.90,
		"-SigmaLo", 0.015,
		"-SigmaHi", 0.04,
		"-HighlightStart", 0,
		"-PostScale", 0.9,
		"-MaxSpec", 0
        )
	}
	
	#T=01:40:03
    m23 = @{
		
		HeightArgs = @(
		"-BlueMin", 0,
		"-BlueMax", 1,
		"-CompressStart", 0.55,
		"-CompressFull", 0.90
		)
		ReflectanceArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.01,
		"-KneeMax", 1.00,
		"-SigmaLo", 0.0025,
		"-SigmaHi", 0.0125,
		"-PostScale", 0.75,
		"-HighlightStart", 0.35,
		"-MaxSpec", 0,
		"-FlatBrightMeanMin", 0.42,
		"-FlatBrightSigmaMax", 0.01,
		"-FlatBrightScale", 0.85
        )
        SpecularArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.75,
		"-KneeMax", 0.95,
		"-SigmaLo", 0.015,
		"-SigmaHi", 0.04,
		"-HighlightStart", 0.45,
		"-PostScale", 0.85,
		"-GlobalScale", 0.60,
		"-MaxSpec", 0.55
        )
	}
	
	#T=01:36:47 x2
    m24 = @{
		HeightArgs = @(
		"-BlueMin", 0,
		"-BlueMax", 1,
		"-CompressStart", 0.55,
		"-CompressFull", 0.90
		)		
        ReflectanceArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.01,
		"-KneeMax", 1.00,
		"-SigmaLo", 0.0025,
		"-SigmaHi", 0.0125,
		"-PostScale", 0.75,
		"-HighlightStart", 0.35,
		"-MaxSpec", 0,
		"-FlatBrightMeanMin", 0.42,
		"-FlatBrightSigmaMax", 0.01,
		"-FlatBrightScale", 0.85
        )
        SpecularArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.8,
		"-KneeMax", 0.95,
		"-SigmaLo", 0.015,
		"-SigmaHi", 0.04,
		"-HighlightStart", 0.45,
		"-PostScale", 0.85,
		"-GlobalScale", 0.60, #was .65
		"-MaxSpec", 0.55
        )
	}
	
	#T=18m
	m25 = @{
		HeightArgs = @(
		"-BlueMin", 0.2
		"-BlueMax", 0.9,
		"-CompressStart", 0.55,
		"-CompressFull", 0.90
		)		
        ReflectanceArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin",0.9,
		"-KneeMax", 1.00,
		"-SigmaLo", 0.0025,
		"-SigmaHi", 0.0125,
		"-PostScale", 1,
		"-HighlightStart", 0.65,
		"-MaxSpec", 0.0,
		"-FlatBrightMeanMin", 0.42,
		"-FlatBrightSigmaMax", 0.01,
		"-FlatBrightScale", 0.85
        )
		SpecularArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.02,
		"-KneeMax", 0.82,
		"-SigmaLo", 0.015,
		"-SigmaHi", 0.28,
		"-HighlightStart", 0.45,
		"-PostScale", 0.94,
		"-GlobalScale", 0.90,
		"-MaxSpec", 0.0,
		"-BrightBusy",
		"-BrightBusyMeanMin", 0.605,
		"-BrightBusySigmaMin", 0.12,
		"-BrightBusyScale", 0.57
		)
	}
	
	#T=00:18
	m26 = @{
		HeightArgs = @(
		"-BlueMin", 0,
		"-BlueMax", 1,
		"-CompressStart", 0.55,
		"-CompressFull", 0.90
		)		
        ReflectanceArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.01,
		"-KneeMax", 1.00,
		"-SigmaLo", 0.0025,
		"-SigmaHi", 0.0125,
		"-PostScale", 0.75,
		"-HighlightStart", 0.35,
		"-MaxSpec", 0,
		"-FlatBrightMeanMin", 0.42,
		"-FlatBrightSigmaMax", 0.01,
		"-FlatBrightScale", 0.85
        )
        SpecularArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.8,
		"-KneeMax", 0.95,
		"-SigmaLo", 0.015,
		"-SigmaHi", 0.04,
		"-HighlightStart", 0.45,
		"-PostScale", 0.85,
		"-GlobalScale", 0.65,
		"-MaxSpec", 0.55
        )
	}	
	
    #T=12m
    m27 = @{
		HeightArgs = @(
		"-BlueMin", 0,
		"-BlueMax", 1,
		"-CompressStart", 0.55,
		"-CompressFull", 0.90
		)		
        ReflectanceArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.01,
		"-KneeMax", 1.00,
		"-SigmaLo", 0.0025,
		"-SigmaHi", 0.0125,
		"-PostScale", 0.75,
		"-HighlightStart", 0.35,
		"-MaxSpec", 0,
		"-FlatBrightMeanMin", 0.42,
		"-FlatBrightSigmaMax", 0.01,
		"-FlatBrightScale", 0.85
        )
        SpecularArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.8,
		"-KneeMax", 0.95,
		"-SigmaLo", 0.015,
		"-SigmaHi", 0.04,
		"-HighlightStart", 0.45,
		"-PostScale", 0.85,
		"-GlobalScale", 0.65,
		"-MaxSpec", 0.55
        )
	}
	
	#T=40m
    m28 = @{
		HeightArgs = @(
		"-BlueMin", 0.20,
		"-BlueMax", 0.80,
		"-CompressStart", 0.55,
		"-CompressFull", 0.90
		)		
        ReflectanceArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.01,
		"-KneeMax", 1.00,
		"-SigmaLo", 0.0025,
		"-SigmaHi", 0.0125,
		"-PostScale", 0.75,
		"-HighlightStart", 0.35,
		"-MaxSpec", 0,
		"-FlatBrightMeanMin", 0.42,
		"-FlatBrightSigmaMax", 0.01,
		"-FlatBrightScale", 0.85
        )
        SpecularArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.75,
		"-KneeMax", 0.95,
		"-SigmaLo", 0.015,
		"-SigmaHi", 0.04,
		"-HighlightStart", 0.45,
		"-PostScale", 0.85,
		"-GlobalScale", 0.65,
		"-MaxSpec", 0.55
        )
	}
	
	#T=1h15
	m29 = @{
		HeightArgs = @(
		"-BlueMin", 0,
		"-BlueMax", 1,
		"-CompressStart", 0.55,
		"-CompressFull", 0.90
		)		
        ReflectanceArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.01,
		"-KneeMax", 1.00,
		"-SigmaLo", 0.0025,
		"-SigmaHi", 0.0125,
		"-PostScale", 0.75,
		"-HighlightStart", 0.35,
		"-MaxSpec", 0,
		"-FlatBrightMeanMin", 0.42,
		"-FlatBrightSigmaMax", 0.01,
		"-FlatBrightScale", 0.85
        )
        SpecularArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.8,
		"-KneeMax", 0.95,
		"-SigmaLo", 0.015,
		"-SigmaHi", 0.04,
		"-HighlightStart", 0.45,
		"-PostScale", 0.85,
		"-GlobalScale", 0.65,
		"-MaxSpec", 0.55
        )
	}
	
	#T=1h20
	m32 = @{
		HeightArgs = @(
		"-BlueMin", 0,
		"-BlueMax", 1,
		"-CompressStart", 0.55,
		"-CompressFull", 0.90
		)		
        ReflectanceArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.01,
		"-KneeMax", 1.00,
		"-SigmaLo", 0.0025,
		"-SigmaHi", 0.0125,
		"-PostScale", 0.75,
		"-HighlightStart", 0.35,
		"-MaxSpec", 0,
		"-FlatBrightMeanMin", 0.42,
		"-FlatBrightSigmaMax", 0.01,
		"-FlatBrightScale", 0.85
        )
        SpecularArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.8,
		"-KneeMax", 0.95,
		"-SigmaLo", 0.015,
		"-SigmaHi", 0.04,
		"-HighlightStart", 0.45,
		"-PostScale", 0.85,
		"-GlobalScale", 0.65,
		"-MaxSpec", 0.55
        )
	}
	
	#T=21m
	m33 = @{
		HeightArgs = @(
		"-BlueMin", 0,
		"-BlueMax", 1,
		"-CompressStart", 0.55,
		"-CompressFull", 0.90
		)		
        ReflectanceArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.01,
		"-KneeMax", 1.00,
		"-SigmaLo", 0.0025,
		"-SigmaHi", 0.0125,
		"-PostScale", 0.75,
		"-HighlightStart", 0.35,
		"-MaxSpec", 0,
		"-FlatBrightMeanMin", 0.42,
		"-FlatBrightSigmaMax", 0.01,
		"-FlatBrightScale", 0.85
        )
        SpecularArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.8,
		"-KneeMax", 0.95,
		"-SigmaLo", 0.015,
		"-SigmaHi", 0.04,
		"-HighlightStart", 0.45,
		"-PostScale", 0.85,
		"-GlobalScale", 0.65,
		"-MaxSpec", 0.55
        )
	}
	
	#T=42m
	m34 = @{
		HeightArgs = @(
		"-BlueMin", 0,
		"-BlueMax", 1,
		"-CompressStart", 0.55,
		"-CompressFull", 0.90
		)		
        ReflectanceArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.01,
		"-KneeMax", 1.00,
		"-SigmaLo", 0.0025,
		"-SigmaHi", 0.0125,
		"-PostScale", 0.75,
		"-HighlightStart", 0.35,
		"-MaxSpec", 0,
		"-FlatBrightMeanMin", 0.42,
		"-FlatBrightSigmaMax", 0.01,
		"-FlatBrightScale", 0.85
        )
        SpecularArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.8,
		"-KneeMax", 0.95,
		"-SigmaLo", 0.015,
		"-SigmaHi", 0.04,
		"-HighlightStart", 0.45,
		"-PostScale", 0.85,
		"-GlobalScale", 0.65,
		"-MaxSpec", 0.55
        )
	}
		
	#T=18m
	m35 = @{
		HeightArgs = @(
		"-BlueMin", 0,
		"-BlueMax", 1,
		"-CompressStart", 0.55,
		"-CompressFull", 0.90
		)		
        ReflectanceArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.01,
		"-KneeMax", 1.00,
		"-SigmaLo", 0.0025,
		"-SigmaHi", 0.0125,
		"-PostScale", 0.75,
		"-HighlightStart", 0.35,
		"-MaxSpec", 0,
		"-FlatBrightMeanMin", 0.42,
		"-FlatBrightSigmaMax", 0.01,
		"-FlatBrightScale", 0.85
        )
        SpecularArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.8,
		"-KneeMax", 0.95,
		"-SigmaLo", 0.015,
		"-SigmaHi", 0.04,
		"-HighlightStart", 0.45,
		"-PostScale", 0.85,
		"-GlobalScale", 0.65,
		"-MaxSpec", 0.55
        )
	}
			
	#T=20
	m36 = @{
		HeightArgs = @(
		"-BlueMin", 0,
		"-BlueMax", 1,
		"-CompressStart", 0.55,
		"-CompressFull", 0.90
		)		
        ReflectanceArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.01,
		"-KneeMax", 1.00,
		"-SigmaLo", 0.0025,
		"-SigmaHi", 0.0125,
		"-PostScale", 0.75,
		"-HighlightStart", 0.35,
		"-MaxSpec", 0,
		"-FlatBrightMeanMin", 0.42,
		"-FlatBrightSigmaMax", 0.01,
		"-FlatBrightScale", 0.85
        )
        SpecularArgs = @(
		"-Mode", "Knee",
		"-AutoKnee",
		"-KneeMin", 0.8,
		"-KneeMax", 0.95,
		"-SigmaLo", 0.015,
		"-SigmaHi", 0.04,
		"-HighlightStart", 0.45,
		"-PostScale", 0.85,
		"-GlobalScale", 0.65,
		"-MaxSpec", 0.55
        )
	}
	
	
}

$Groups = [ordered]@{
    m21 = @(
	"m21_0000","m21_0001","m21_0002","m21_0003"
    )
	
    m22 = @(
	"m22_0000","m22_0001","m22_0002","m22_0003"
    )
	
    m23 = @(
	"m23_0000","m23_0001","m23_0002","m23_0003"
    )
	
    m24 = @(
	"m24_0000","m24_0001","m24_0002","m24_0003",
	"m24_01_0000","m24_01_0001","m24_01_0002","m24_01_0003"
	)
    
	<# 	m24_01 = @(
		"m24_01_0000","m24_01_0001","m24_01_0002","m24_01_0003"
	) #>
	
    m25 = @(
	"m25_0000","m25_0001","m25_0002","m25_0003"
    )
    
	m26 = @(
	"m26_0000","m26_0001","m26_0002","m26_0003"
    )
	
	m27 = @(
	"m27_0000","m27_0001","m27_0002","m27_0003"
    )
    
	m28 = @(
	"m28_0000","m28_0001","m28_0002","m28_0003"
    )
	
	m29 = @(
	"m29_0000","m29_0001","m29_0002","m29_0003"
    )
	
	m32 = @(
	"m32_0000","m32_0001","m32_0002","m32_0003"
    )
	
	m33 = @(
	"m33_0000","m33_0001","m33_0002","m33_0003"
    )
	
	m34 = @(
	"m34_0000","m34_0001","m34_0002","m34_0003"
    )
	
	m35 = @(
	"m35_0000","m35_0001","m35_0002","m35_0003"
    )
		
	m36 = @(
	"m36_0000","m36_0001","m36_0002","m36_0003"
    )
	
}

$SelectedGroups = [ordered]@{}
$SelectedPackagesByGroup = @{}

if (-not [string]::IsNullOrWhiteSpace($MapFolder)) {
    $groupName = Convert-MapCodeToTextureGroup $MapFolder
    if (-not $Groups.Contains($groupName)) { throw "Unknown group: $groupName" }
    $prefix = Get-TexturePackagePrefixFromMapFolder $MapFolder
    $pkgs = @($Groups[$groupName] | Where-Object { $_.StartsWith(($prefix + '_'), [StringComparison]::OrdinalIgnoreCase) })
    if ($pkgs.Count -eq 0) { throw "No texture packages matched MapFolder $MapFolder" }
    $SelectedGroups[$groupName] = $pkgs
}
elseif (-not [string]::IsNullOrWhiteSpace($MapCode)) {
    $groupName = Convert-MapCodeToTextureGroup $MapCode
    if (-not $Groups.Contains($groupName)) { throw "Unknown group: $groupName" }
    $SelectedGroups[$groupName] = @($Groups[$groupName])
}
else {
    $SelectedGroups = $Groups
    if ($OnlyGroups -and $OnlyGroups.Count -gt 0) {
        $unknown = @($OnlyGroups | Where-Object { -not $Groups.Contains($_) })
        if ($unknown.Count -gt 0) {
            throw "Unknown group(s): $($unknown -join ', '). Valid groups: $($Groups.Keys -join ', ')"
        }
        $SelectedGroups = [ordered]@{}
        foreach ($groupName in $Groups.Keys) {
            if ($OnlyGroups -contains $groupName) { $SelectedGroups[$groupName] = $Groups[$groupName] }
        }
    }
}

Write-Host ('ProjectRoot:   {0}' -f $projectRoot)
Write-Host ('SourceRoot:    {0}' -f $sourceTexturesRoot)
Write-Host ('TexturesRoot:  {0}' -f $TexturesRoot)
Write-Host ('CpuThrottle:   {0}' -f $ThrottleLimit)
Write-Host ('GpuThrottle:   {0}' -f $GpuThrottleLimit)
if (-not [string]::IsNullOrWhiteSpace($MapCode)) { Write-Host ('MapCode:       {0}' -f $MapCode) }
if (-not [string]::IsNullOrWhiteSpace($MapFolder)) { Write-Host ('MapFolder:     {0}' -f $MapFolder) }

$stageJobs = [System.Collections.Generic.List[object]]::new()
foreach ($groupName in $SelectedGroups.Keys) {
    foreach ($package in @($SelectedGroups[$groupName])) {
        $src = Join-Path (Join-Path $sourceTexturesRoot $groupName) ($package + '.tpfbdt')
        $dst = Join-Path (Join-Path $TexturesRoot $groupName) ($package + '.tpfbdt')
        [void]$stageJobs.Add([pscustomobject]@{ Group=$groupName; Package=$package; Source=$src; Dest=$dst; Header=(Get-HeaderPathIfPresent $src) })
    }
}

$missing = @($stageJobs | Where-Object { -not (Test-Path -LiteralPath $_.Source -PathType Leaf) })
if ($missing.Count -gt 0) {
    $list = ($missing | ForEach-Object { $_.Source }) -join "`n"
    throw "Missing source texture archive(s):`n$list"
}

if ($DryRun) {
    foreach ($j in $stageJobs) {
        Write-Host ('DRY  {0} -> {1}' -f $j.Source, $j.Dest)
        if (-not [string]::IsNullOrWhiteSpace($j.Header)) { Write-Host ('     header: {0}' -f $j.Header) }
    }
    return
}

Write-Host ''
Write-Host 'Stage #1: staging source texture archives into output root...' -ForegroundColor Cyan
foreach ($j in $stageJobs) {
    Copy-StageTexturePackage -SourceFile $j.Source -DestFile $j.Dest
}

$overallTimer = [System.Diagnostics.Stopwatch]::StartNew()
$groupResults = [ordered]@{}

foreach ($groupName in $SelectedGroups.Keys) {
    $groupTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $groupFailed = $false

    Write-Host ''
    Write-Host '##################################################' -ForegroundColor DarkYellow
    Write-Host ("Starting group: {0}" -f $groupName) -ForegroundColor DarkYellow
    Write-Host '##################################################' -ForegroundColor DarkYellow

    foreach ($package in @($SelectedGroups[$groupName])) {
        try {
            Invoke-TexturePipeline -GroupName $groupName -PackageName $package -Profile $Profiles[$groupName]
        }
        catch {
            $groupFailed = $true
            Write-Host $_.Exception.Message -ForegroundColor Red
            if (-not $ContinueOnError) { throw }
        }
    }

    $groupTimer.Stop()
    $groupResults[$groupName] = [pscustomobject]@{
        Group   = $groupName
        Status  = if ($groupFailed) { 'FAILED' } else { 'OK' }
        Elapsed = Format-Duration $groupTimer.Elapsed
    }

    Write-Host ''
    Write-Host ("Finished group: {0}   [{1}]   Status={2}" -f $groupName, (Format-Duration $groupTimer.Elapsed), $groupResults[$groupName].Status) -ForegroundColor Magenta
}

$overallTimer.Stop()
Write-Host ''
Write-Host '================ FINAL SUMMARY ================' -ForegroundColor Green
$groupResults.Values | Format-Table -AutoSize
Write-Host ('Overall elapsed: {0}' -f (Format-Duration $overallTimer.Elapsed)) -ForegroundColor Green
