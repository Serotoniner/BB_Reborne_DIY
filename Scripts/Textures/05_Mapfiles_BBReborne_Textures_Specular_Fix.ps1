# BB Reborne DIY Tool
# Copyright (C) 2026 Greg Pitta
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# See the LICENSE file for details.


<# -Mode

Choices:

Multiply
Knee

This decides the overall behavior.

Multiply

Applies a uniform scale to the whole grayscale specular map.

Effect:

lowers all specular values evenly
darkest, mid, and brightest areas all move together
simplest mode

Use it when:

the whole spec map is too shiny everywhere
you want predictable blanket reduction
Knee

Leaves darker parts closer to original and mainly reshapes the brighter region above HighlightStart.

Effect:

preserves base material separation better
mainly tamps down bright peaks
usually better when only highlights are the problem

Use it when:

the surface looks broadly fine, but hot specular peaks are too strong
you want more natural control than Multiply
Multiply-mode parameter
-SpecScale

Used directly in Multiply mode, and also still matters conceptually as your “strength” control. Default 1.0.

In Multiply mode the script does:

finalScale = SpecScale * GlobalScale

then multiplies the whole grayscale image by that.

Effect:

1.0 = no change
0.8 = 20% dimmer specular everywhere
0.5 = half as bright everywhere
0.25 = heavy suppression

Examples:

slightly too glossy stone: -Mode Multiply -SpecScale 0.85
strong mirror-like highlights all over: -Mode Multiply -SpecScale 0.5
Knee-mode parameters
-Knee

Default 0.85. In Knee mode it controls the highlight remap curve above HighlightStart.

Effect:

lower value = stronger highlight suppression
higher value = gentler suppression

Examples:

0.95 = very mild
0.85 = balanced
0.70 = noticeably stronger
0.50 = aggressive

Image feel:

polished or wet surfaces with overblown peaks benefit from lower Knee
if lowered too far, highlights can become dull and lose material identity
-PostScale

Default 1.0. Applied after the knee remap inside the bright region.

Effect:

1.0 = leave knee result alone
< 1.0 = extra suppression after the curve
> 1.0 = re-open highlights slightly

Examples:

-Knee 0.85 -PostScale 0.9 = knee plus a bit more damping
-Knee 0.85 -PostScale 1.0 = neutral
-Knee 0.85 -PostScale 1.05 = slightly brighter post-knee highlights

Good for:

fine-tuning when the curve shape feels right but the final intensity is still off
-HighlightStart

Default 0.65. Defines where Knee mode begins to alter values. Below this threshold, the image is kept closer to the original before GlobalScale is applied.

Effect:

lower value = more of the image gets treated as highlight
higher value = only the brightest peaks get reshaped

Examples:

0.50 = broad control over upper mids and highlights
0.65 = balanced default
0.80 = only very bright peaks are affected

Image examples:

shiny stone floor with large glossy regions:
0.55 helps calm broad shine
mostly matte surface with only tiny hot sparkles:
0.80 is better
-GlobalScale

Default 1.0. This is important in this script. It multiplies the entire final result, including both the untouched low region and the knee-adjusted highlight region.

In Knee mode, the expression is effectively:

final = knee_or_original * GlobalScale

In Multiply mode, it is combined with SpecScale:
finalScale = SpecScale * GlobalScale

Effect:

acts like a global master dimmer after your shaping choices
lower value = the whole spec map gets darker
unlike PostScale, it affects both dark/mid and bright regions

Examples:

0.95 = subtle global reduction
0.8 = clear overall dimming
0.6 = strong whole-map suppression

This is the easiest way to say:
“keep the shape, but lower the whole output a bit.”

-MaxSpec

Default 0.0, which disables it. If set between 0 and 1, the script measures the max value of the adjusted image and proportionally scales the whole image down so that its brightest point becomes MaxSpec.

This is not a hard clamp per pixel in the same way as the reflectance script. Here it is a scale-to-max-after-remap.

Effect:

preserves relative contrast
but lowers the entire map if its brightest value exceeds your target
great as a safety ceiling

Examples:

-MaxSpec 0.9 = only mild cap
-MaxSpec 0.75 = stronger overall reduction if peaks are too high
-MaxSpec 0.0 = disabled

Image feel:

very useful when you like the curve shape but still want to guarantee no peaks exceed a certain strength
Auto-adaptive Knee params
-AutoKnee

Enables dynamic knee selection based on the image’s grayscale standard deviation.

This script explicitly uses an inverted mapping:

low sigma, more uniform image → KneeMin
high sigma, more varied image → KneeMax

So:

flatter spec maps get stronger treatment
more detailed / varied spec maps get gentler treatment

This is a very sensible behavior for batch work.

Use it when:

some textures are flat shiny sheets
others have detailed spec breakup
you want the flatter ones hit harder automatically
-KneeMin

Default 0.85. Strongest knee the auto system is allowed to use. Since lower knee means stronger suppression, this is your “maximum strength” end.

Effect:

lower KneeMin = stronger suppression on flat/uniform maps
higher KneeMin = gentler minimum behavior

Examples:

0.85 = mild-to-moderate
0.70 = stronger on flat maps
0.55 = aggressive on flat maps
-KneeMax

Default 1.0. Gentlest knee the auto system is allowed to use for more varied maps.

Effect:

lower KneeMax = even detailed textures still get some suppression
higher KneeMax = detailed textures stay closer to original

Examples:

1.0 = very gentle upper end
0.95 = still soft, but slightly active
0.85 = everything gets more noticeable adjustment
-SigmaLo and -SigmaHi

These define the sigma window for AutoKnee interpolation.

Effect:

values near SigmaLo are treated as flat/uniform
values near SigmaHi are treated as varied/detailed
values between them blend smoothly

Examples:

SigmaLo 0.01 -SigmaHi 0.03
more sensitive to small variance differences
SigmaLo 0.02 -SigmaHi 0.08
broader, calmer adaptive response

Use these when:

AutoKnee seems to classify too many maps as flat
or does not react enough to flatter maps #>
param(
[Parameter(Mandatory=$true)][string]$RootDir,
[Parameter(Mandatory=$true)][string]$TexconvExe,
[Parameter(Mandatory=$true)][string]$MagickExe,

# Curve for reducing shininess
[ValidateSet("Multiply","Knee")]
[string]$Mode = "Knee",

# Multiply mode: out = in * SpecScale
[double]$SpecScale = 1.0,

# Knee mode: out = 1 - (1 - in)^K
[double]$Knee = 0.85,

# Optional final multiply after Knee
[double]$PostScale = 1.0,

# Dynamic knee based on uniformity (stddev)
[switch]$AutoKnee,
[double]$KneeMin = 0.85,
[double]$KneeMax = 1,
[double]$SigmaLo = 0.015,
[double]$SigmaHi = 0.04,

[double]$HighlightStart = 0.65,
[double]$MaxSpec = 0.0,
[double]$GlobalScale = 1.0,

# Optional reflectance-style "flat bright" branch for specular
# Disabled by default unless -FlatBright is passed
[switch]$FlatBright,
[double]$FlatBrightMeanMin = 0.75,
[double]$FlatBrightSigmaMax = 0.03,
[double]$FlatBrightScale = 0.70,

# Optional "bright busy" branch for bright + high-variance atlases
# Disabled by default unless -BrightBusy is passed
[switch]$BrightBusy,
[double]$BrightBusyMeanMin = 0.58,
[double]$BrightBusySigmaMin = 0.12,
[double]$BrightBusyScale = 0.65,

[int]$ThrottleLimit = [int][Environment]::ProcessorCount -2,
[int]$ProgressEvery = 50,
[switch]$DryRun,

# Apply results back onto RootDir after processing completes
[switch]$Apply,

# Keep outputs/temp/logs/backup folders even when applying (skip cleanup)
[switch]$Keep,

[string]$BackupDir = "",
[switch]$NoBackup,

# Optional: rebuild even if OutRoot already has DDS (resume is default behavior)
[switch]$ForceRebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($ThrottleLimit -lt 1) { $ThrottleLimit = 1 }

trap {
	Write-Host ""
	Write-Host "==== UNHANDLED ERROR ===="
	Write-Host ("Type:    {0}" -f $_.Exception.GetType().FullName)
	Write-Host ("Message: {0}" -f $_.Exception.Message)
	if ($_.Exception.InnerException) { Write-Host ("Inner:   {0}" -f $_.Exception.InnerException.Message) }
	if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) { Write-Host ""; Write-Host $_.InvocationInfo.PositionMessage }
	if ($_.ScriptStackTrace) { Write-Host ""; Write-Host "Stack:"; Write-Host $_.ScriptStackTrace }
	break
}

Write-Host "SCRIPT VERSION: 2026-02-19-main-sha (specular BC4: disk-verified stages + short SHA temp paths + preserve core commands + optional FlatBright/BrightBusy branches)"

if ($PSVersionTable.PSVersion.Major -lt 7) { throw "Run with PowerShell 7+ (pwsh)." }
if (-not (Test-Path -LiteralPath $RootDir))    { throw "RootDir not found: $RootDir" }
if (-not (Test-Path -LiteralPath $TexconvExe)) { throw "texconv.exe not found: $TexconvExe" }
if (-not (Test-Path -LiteralPath $MagickExe))  { throw "magick.exe not found: $MagickExe" }

function Ensure-Dir([string]$p) { [System.IO.Directory]::CreateDirectory($p) | Out-Null }

function Get-RelativePath([string]$base, [string]$full) {
	$b = (Resolve-Path -LiteralPath $base).Path.TrimEnd('\')
	$f = (Resolve-Path -LiteralPath $full).Path
	if ($f.StartsWith($b, [System.StringComparison]::OrdinalIgnoreCase)) {
		return $f.Substring($b.Length).TrimStart('\')
	}
	return $full
}


function Get-ShortWorkKey([string]$Value) {
	if ([string]::IsNullOrWhiteSpace($Value)) { $Value = '_root' }
	$sha = [System.Security.Cryptography.SHA256]::Create()
	try {
		$bytes = [System.Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())
		return ([Convert]::ToHexString($sha.ComputeHash($bytes))).Substring(0, 16).ToLowerInvariant()
	}
	finally {
		if ($sha) { $sha.Dispose() }
	}
}
function Is-LowResFolderName([string]$name) { return ($name -match '_l(?=-)') }

function Is-SpecularFolderName([string]$name) {
	if ($name -notlike "*-tpf-dcx") { return $false }
	if (Is-LowResFolderName $name)  { return $false }
	return ($name -match '_(s)(?=(_|-))')
}

function Find-ExpectedFile {
	param([Parameter(Mandatory=$true)][string]$Path)
	
	if (Test-Path -LiteralPath $Path) { return $Path }
	
	$dir  = Split-Path $Path -Parent
	$base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
	$ext  = [System.IO.Path]::GetExtension($Path)
	
	$alt1 = Join-Path $dir ($base + $ext.ToUpperInvariant())
	if (Test-Path -LiteralPath $alt1) { return $alt1 }
	
	$alt2 = Join-Path $dir ($base + $ext.ToLowerInvariant())
	if (Test-Path -LiteralPath $alt2) { return $alt2 }
	
	try {
		$hits = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
		Where-Object { $_.Name -like ($base + "*" + $ext) } |
		Select-Object -First 1
		if ($hits) { return $hits.FullName }
	} catch {}
	
	return $null
}

function Count-FilesSafe {
	param([string]$Path,[string]$ExtPattern)
	try {
		if (-not (Test-Path -LiteralPath $Path)) { return 0 }
		return (Get-ChildItem -LiteralPath $Path -Recurse -File -Filter $ExtPattern -ErrorAction SilentlyContinue).Count
	} catch { return 0 }
}

function Invoke-ParallelStageWithProgress {
	param(
		[Parameter(Mandatory=$true)][string]$Activity,
		[Parameter(Mandatory=$true)][object[]]$InputObject,
		[Parameter(Mandatory=$true)][scriptblock]$ParallelScript,
		[Parameter(Mandatory=$true)][int]$ThrottleLimit,
		[string]$CountPath = $null,
		[string]$CountFilter = $null,
		[int]$PollMs = 400
	)
	
	$total = @($InputObject).Count
	if ($total -eq 0) { return @() }
	
	$job = $InputObject | ForEach-Object -Parallel $ParallelScript -ThrottleLimit $ThrottleLimit -AsJob
	
	$lastCountTick = [Environment]::TickCount64
	$cachedFileCount = $null
	
	try {
		while ($true) {
			$all  = @(Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue)
			$done = $all.Count
			if ($done -gt $total) { $done = $total }
			
			$pct = [int](100.0 * $done / $total)
			if ($pct -gt 100) { $pct = 100 }
			
			$status = "Done: $done / $total"
			if ($CountPath -and $CountFilter) {
				$now = [Environment]::TickCount64
				if ($cachedFileCount -eq $null -or ($now - $lastCountTick) -ge 1200) {
					$cachedFileCount = Count-FilesSafe -Path $CountPath -ExtPattern $CountFilter
					$lastCountTick = $now
				}
				$status = "Done: $done / $total | Files on disk: $cachedFileCount"
			}
			
			Write-Progress -Activity $Activity -Status $status -PercentComplete $pct
			
			if ($job.State -in @('Completed','Failed','Stopped')) { break }
			Start-Sleep -Milliseconds $PollMs
		}
		
		Write-Progress -Activity $Activity -Completed
		return @(Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue)
	}
	finally {
		Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
	}
}

function Clamp01([double]$x) {
	if ($x -lt 0) { return 0.0 }
	if ($x -gt 1) { return 1.0 }
	return $x
}

function Compute-KneeFromSigma {
	param([double]$sigma,[double]$SigmaLo,[double]$SigmaHi,[double]$KneeMin,[double]$KneeMax)
	$den = [Math]::Max(1e-9, ($SigmaHi - $SigmaLo))
	$t = Clamp01( ($sigma - $SigmaLo) / $den )
	# INVERTED mapping:
	#   uniform (low sigma) => KneeMin (strong)
	#   varied   (high sigma) => KneeMax (gentle)
	return ($KneeMin + $t * ($KneeMax - $KneeMin))
}

# --------------------------------------------------------------------------------------
# Output + temp dirs (match reference scheme: rooted at parent(RootDir), prefixed with leaf(RootDir))
# --------------------------------------------------------------------------------------
$rootFull   = (Resolve-Path -LiteralPath $RootDir).Path
$rootFull   = $rootFull -replace '[\\/]+$',''
$rootLeaf   = Split-Path $rootFull -Leaf
$rootParent = Split-Path $rootFull -Parent

$OutRoot   = Join-Path $rootParent ("{0}_specular_fix_s" -f $rootLeaf)
$WorkRoot  = Join-Path $OutRoot "_work"
$LogRoot   = Join-Path $OutRoot "_logs"
$EncodeTmp = Join-Path $OutRoot "_encode_tmp"

# Staged work dirs (disk-verified pipeline)
$pngInRoot   = Join-Path $WorkRoot "stage1_png_in"     # DDS -> PNG
$pngGrayRoot = Join-Path $WorkRoot "stage2_png_gray"   # extract R -> grayscale
$pngAdjRoot  = Join-Path $WorkRoot "stage3_png_adj"    # curve output

if ([string]::IsNullOrWhiteSpace($BackupDir)) {
	$BackupDir = Join-Path $rootParent ("{0}_backup_original_dds_specular_fix" -f $rootLeaf)
}

Ensure-Dir $OutRoot
Ensure-Dir $WorkRoot
Ensure-Dir $LogRoot
Ensure-Dir $EncodeTmp
Ensure-Dir $pngInRoot
Ensure-Dir $pngGrayRoot
Ensure-Dir $pngAdjRoot
if ($Apply -and (-not $NoBackup)) { Ensure-Dir $BackupDir }

Write-Host "RootDir   : $rootFull"
Write-Host "OutRoot   : $OutRoot"
Write-Host "WorkRoot  : $WorkRoot"
Write-Host "LogRoot   : $LogRoot"
Write-Host "EncodeTmp : $EncodeTmp"
Write-Host "Mode      : $Mode (SpecScale=$SpecScale Knee=$Knee PostScale=$PostScale)"
Write-Host "AutoKnee  : $AutoKnee (KneeMin=$KneeMin KneeMax=$KneeMax SigmaLo=$SigmaLo SigmaHi=$SigmaHi) [INVERTED]"
Write-Host "FlatBright: $FlatBright (MeanMin=$FlatBrightMeanMin SigmaMax=$FlatBrightSigmaMax Scale=$FlatBrightScale)"
Write-Host "BrightBusy: $BrightBusy (MeanMin=$BrightBusyMeanMin SigmaMin=$BrightBusySigmaMin Scale=$BrightBusyScale)"
Write-Host "Throttle  : $ThrottleLimit"
Write-Host "Progress  : every $ProgressEvery files (legacy; progress bars are primary now)"
Write-Host "DryRun    : $DryRun"
Write-Host "Apply     : $Apply"
Write-Host "Keep      : $Keep"
Write-Host "ForceRebuild: $ForceRebuild"
Write-Host "Backup    : " -NoNewline
if ($Apply -and (-not $NoBackup)) { Write-Host $BackupDir } else { Write-Host "disabled" }
Write-Host ""

if ($DryRun) {
	Write-Host "DRYRUN: enabled (will not execute stages)."
	return
}

# --------------------------------------------------------------------------------------
# Collect target DDS + manifest
# --------------------------------------------------------------------------------------
$folders = @(Get-ChildItem -LiteralPath $rootFull -Directory -Recurse -Force |
Where-Object { Is-SpecularFolderName $_.Name })

if ($folders.Count -eq 0) {
	Write-Host "No hires specular (_s) folders found (excluding _l-)."
	return
}
Write-Host ("Target folders (_s): {0}" -f $folders.Count)

$ddsList = New-Object System.Collections.ArrayList
foreach ($f in $folders) {
	foreach ($d in (Get-ChildItem -LiteralPath $f.FullName -Filter *.dds -File -ErrorAction SilentlyContinue)) {
		[void]$ddsList.Add($d)
	}
}

Write-Host ("Total DDS files: {0}" -f $ddsList.Count)
Write-Host ""
if ($ddsList.Count -eq 0) { return }

$manifest = [System.Collections.ArrayList]::new()
$rootPrefix = $rootFull; if (-not $rootPrefix.EndsWith('\')) { $rootPrefix += '\' }

foreach ($f in $ddsList) {
	$full = $f.FullName
	$rel = if ($full.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { $full.Substring($rootPrefix.Length) }
	else { ($full.Replace($rootFull, '') -replace '^[\\/]+','') }
	$rel = ($rel -replace '/','\')
	$relDir = Split-Path $rel -Parent
	if ([string]::IsNullOrWhiteSpace($relDir)) { $relDir = "" }
	
	$base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
	
	$outDir = Join-Path $OutRoot $relDir
	$outDds = Join-Path $outDir $f.Name
	
	# Keep final output paths unchanged, but keep transient PNG/DDS encode stages
	# in short SHA folders to avoid Windows path-length failures.
	$dirKey  = Get-ShortWorkKey $relDir
	$fileKey = Get-ShortWorkKey $rel
	
	$pngInDir   = Join-Path $pngInRoot   $dirKey
	$pngGrayDir = Join-Path $pngGrayRoot $dirKey
	$pngAdjDir  = Join-Path $pngAdjRoot  $dirKey
	
	$png1    = Join-Path $pngInDir   ($base + ".png")
	$pngGray = Join-Path $pngGrayDir ($base + "_r.png")
	$pngAdj  = Join-Path $pngAdjDir  ($base + "_adj.png")
	
	$log = Join-Path $LogRoot ("specfix_" + $fileKey + ".log")
	
	$encTmp = Join-Path $EncodeTmp ("enc_" + $fileKey)
	
	$backupPath = if ($Apply -and (-not $NoBackup)) { Join-Path $BackupDir $rel } else { $null }
	
	[void]$manifest.Add([PSCustomObject]@{
		FullName=$full; Rel=$rel; RelDir=$relDir; WorkKey=$dirKey; FileKey=$fileKey; Base=$base
		OutDir=$outDir; OutDds=$outDds
		PngInDir=$pngInDir; PngGrayDir=$pngGrayDir; PngAdjDir=$pngAdjDir
		Png1=$png1; PngGray=$pngGray; PngAdj=$pngAdj
		Log=$log
		EncTmpDir=$encTmp
		BackupPath=$backupPath
		
		# stage-populated
		Png1Actual=$null; PngGrayActual=$null; PngAdjActual=$null; OutDdsActual=$null
		IsBC4=$false
		SkipBecauseExists=$false
	})
}

Write-Host "Manifest: $($manifest.Count) files."
$manifest0 = [object[]]$manifest.ToArray()

# --------------------------------------------------------------------------------------
# Stage 0: mark skips
# --------------------------------------------------------------------------------------
foreach ($m in $manifest0) {
	if (-not $ForceRebuild -and (Test-Path -LiteralPath $m.OutDds)) { $m.SkipBecauseExists = $true }
}

$todo0 = @($manifest0 | Where-Object { -not $_.SkipBecauseExists })
$skip0 = @($manifest0 | Where-Object { $_.SkipBecauseExists })

Write-Host ("Stage 0: Skip existing outputs: SKIP={0} TODO={1}" -f $skip0.Count, $todo0.Count)

$needBuild = ($todo0.Count -gt 0)
$wantApply = [bool]$Apply

if (-not $needBuild) {
	Write-Host "Nothing to build (all outputs already exist)."
	if (-not $wantApply) { return }
	Write-Host "Apply requested: will apply existing outputs from OutRoot."
}

# Lists for reporting
$missing2 = New-Object System.Collections.ArrayList
$missing3 = New-Object System.Collections.ArrayList
$missing4 = New-Object System.Collections.ArrayList
$missing5 = New-Object System.Collections.ArrayList
$builtBC4 = New-Object System.Collections.ArrayList
$copyList = @()
$copyOK = 0

if ($needBuild) {
	
	# --------------------------------------------------------------------------------------
	# Stage 1: Backup originals (serial) for files we WILL build (Apply only)
	# --------------------------------------------------------------------------------------
	if ($wantApply -and (-not $NoBackup)) {
		Write-Host "Stage 1: Backup originals (serial)..."
		$i = 0
		foreach ($m in $todo0) {
			try {
				Ensure-Dir (Split-Path $m.BackupPath -Parent)
				Copy-Item -LiteralPath $m.FullName -Destination $m.BackupPath -Force
				$i++
				if (($i % 500) -eq 0) { Write-Host "  backed up $i / $($todo0.Count)" }
			} catch {}
		}
		Write-Host ("Stage 1 done. OK={0} FAIL=0" -f $i)
	}
	
	# --------------------------------------------------------------------------------------
	# Stage 2: DDS -> PNG + detect BC4 (texconv core call preserved)
	# --------------------------------------------------------------------------------------
	Write-Host "Stage 2: DDS -> PNG (parallel) + detect BC4..."
	$stage2Results = Invoke-ParallelStageWithProgress `
	-Activity "Stage 2: DDS -> PNG" `
	-InputObject $todo0 `
	-ThrottleLimit $ThrottleLimit `
	-CountPath $pngInRoot `
	-CountFilter "*.png" `
	-ParallelScript {
		$ok=$false; $err=$null; $isBC4=$false
		try {
			[System.IO.Directory]::CreateDirectory($_.PngInDir) | Out-Null
			[System.IO.Directory]::CreateDirectory($_.OutDir)   | Out-Null
			[System.IO.Directory]::CreateDirectory((Split-Path $_.Log -Parent)) | Out-Null
			
			$dds  = $_.FullName
			$png1 = $_.Png1
			$wDir = $_.PngInDir
			$log  = $_.Log
			
			# --- CORE COMMAND (KEEP INTACT) ---
			$tcOut = & $using:TexconvExe -nologo -ignoremips -ft png --ignore-srgb -y -o $wDir $dds 2>&1
			$tcOut | Add-Content -LiteralPath $log
			if ($LASTEXITCODE -ne 0) { throw "texconv decode failed (exit=$LASTEXITCODE)" }
			if (-not (Test-Path -LiteralPath $png1)) { throw "texconv did not produce PNG: $png1" }
			
			$isBC4 = ($tcOut -match '\bBC4_UNORM\b')
			
			$ok = $true
		} catch {
			$err = $_.Exception.Message
			try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
		} finally {
			[PSCustomObject]@{ FullName=$_.FullName; Ok=$ok; Error=$err; IsBC4=[bool]$isBC4; Done=$true }
		}
	}
	
	$s2 = @{}; foreach ($r in $stage2Results) { $s2[$r.FullName] = $r }
	
	$manifest2 = New-Object System.Collections.ArrayList
	$missing2.Clear() | Out-Null
	foreach ($m in $todo0) {
		$r = $s2[$m.FullName]
		$a1 = Find-ExpectedFile -Path $m.Png1
		if ($r -and $r.Ok -and $a1) {
			$m.Png1Actual = $a1
			$m.IsBC4 = [bool]$r.IsBC4
			[void]$manifest2.Add($m)
		} else {
			$errMsg = "Missing PNG on disk"
			if ($r -and $r.Error) { $errMsg = [string]$r.Error }
			[void]$missing2.Add([PSCustomObject]@{ File=$m.FullName; Error=$errMsg })
		}
	}
	
	Write-Host ("Stage 2 verified on disk. OK={0} MISSING={1}" -f $manifest2.Count, $missing2.Count)
	if ($missing2.Count -gt 0) { $missing2 | Select-Object -First 20 File,Error | Format-Table -AutoSize }
	
	$manifest2a = [object[]]$manifest2.ToArray()
	
	# --------------------------------------------------------------------------------------
	# Stage 3: Copy-through non-BC4
	# --------------------------------------------------------------------------------------
	Write-Host "Stage 3: Copy-through non-BC4 (parallel)..."
	$copyList = @($manifest2a | Where-Object { -not $_.IsBC4 })
	$bc4List  = @($manifest2a | Where-Object { $_.IsBC4 })
	
	if ($copyList.Count -eq 0) {
		Write-Host "Stage 3: Nothing to copy-through (all are BC4)."
		$copyOK = 0
	} else {
		$null = Invoke-ParallelStageWithProgress `
		-Activity "Stage 3: Copy-through" `
		-InputObject $copyList `
		-ThrottleLimit $ThrottleLimit `
		-CountPath $OutRoot `
		-CountFilter "*.dds" `
		-ParallelScript {
			try {
				[System.IO.Directory]::CreateDirectory($_.OutDir) | Out-Null
				Copy-Item -LiteralPath $_.FullName -Destination $_.OutDds -Force
				Add-Content -LiteralPath $_.Log -Value "[COPY] Non-BC4 file copied-through."
			} catch {
				try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $_.Exception.Message) } catch {}
			}
			[PSCustomObject]@{ File=$_.FullName; Done=$true }
		}
		
		$copyOK = 0
		foreach ($m in $copyList) {
			$a = Find-ExpectedFile -Path $m.OutDds
			if ($a) { $m.OutDdsActual = $a; $copyOK++ }
		}
		Write-Host ("Stage 3 verified on disk. COPY_OK={0} COPY_TOTAL={1}" -f $copyOK, $copyList.Count)
	}
	
	if ($bc4List.Count -eq 0) {
		Write-Host "No BC4 files to process after Stage 3."
	} else {
		
		# --------------------------------------------------------------------------------------
		# Stage 4: Extract R channel to grayscale PNG (Magick core call preserved)
		# --------------------------------------------------------------------------------------
		Write-Host "Stage 4: Extract R to grayscale (parallel)..."
		$stage4Results = Invoke-ParallelStageWithProgress `
		-Activity "Stage 4: Extract R" `
		-InputObject $bc4List `
		-ThrottleLimit $ThrottleLimit `
		-CountPath $pngGrayRoot `
		-CountFilter "*.png" `
		-ParallelScript {
			$ok=$false; $err=$null
			try {
				[System.IO.Directory]::CreateDirectory($_.PngGrayDir) | Out-Null
				
				$png1 = $_.Png1Actual
				$pngGray = $_.PngGray
				$log = $_.Log
				
				if (-not $png1) { throw "Missing Png1Actual" }
				
				# --- CORE COMMAND (KEEP INTACT) ---
				& $using:MagickExe $png1 `
				-alpha off `
				-channel R -separate +channel `
				-define png:exclude-chunk=gAMA,cHRM,iCCP,sRGB -strip `
				$pngGray 2>&1 | Add-Content -LiteralPath $log
				
				if ($LASTEXITCODE -ne 0) { throw "magick separate failed (exit=$LASTEXITCODE)" }
				if (-not (Test-Path -LiteralPath $pngGray)) { throw "magick did not produce gray PNG: $pngGray" }
				
				$ok = $true
			} catch {
				$err = $_.Exception.Message
				try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
			} finally {
				[PSCustomObject]@{ FullName=$_.FullName; Ok=$ok; Error=$err; Done=$true }
			}
		}
		
		$s4=@{}; foreach($r in $stage4Results){ $s4[$r.FullName]=$r }
		
		$manifest4 = New-Object System.Collections.ArrayList
		$missing4.Clear() | Out-Null
		foreach ($m in $bc4List) {
			$r = $s4[$m.FullName]
			$a = Find-ExpectedFile -Path $m.PngGray
			if ($r -and $r.Ok -and $a) {
				$m.PngGrayActual = $a
				[void]$manifest4.Add($m)
			} else {
				$errMsg = "Missing gray PNG on disk"
				if ($r -and $r.Error) { $errMsg = [string]$r.Error }
				[void]$missing4.Add([PSCustomObject]@{ File=$m.FullName; Error=$errMsg })
			}
		}
		
		Write-Host ("Stage 4 verified on disk. OK={0} MISSING={1}" -f $manifest4.Count, $missing4.Count)
		if ($missing4.Count -gt 0) { $missing4 | Select-Object -First 20 File,Error | Format-Table -AutoSize }
		
		$manifest4a = [object[]]$manifest4.ToArray()
		
		# --------------------------------------------------------------------------------------
		# Stage 5: Apply curve (Magick) to grayscale PNG (Magick core call preserved)
		#   UPDATE:
		#     - Highlight-only Knee mapping
		#     - GlobalScale applies to the whole final result
		#     - If MaxSpec > 0, final adjusted PNG is proportionally scaled so its max becomes MaxSpec
		#     - Optional FlatBright branch, gated by -FlatBright
		#     - Optional BrightBusy branch, gated by -BrightBusy
		#     - BrightBusy is checked first
		# --------------------------------------------------------------------------------------
		Write-Host "Stage 5: Apply curve (parallel)..."
		$stage5Results = Invoke-ParallelStageWithProgress `
		-Activity "Stage 5: Curve" `
		-InputObject $manifest4a `
		-ThrottleLimit $ThrottleLimit `
		-CountPath $pngAdjRoot `
		-CountFilter "*.png" `
		-ParallelScript {
			$ok=$false; $err=$null
			$tmpScaled = $null
			try {
				[System.IO.Directory]::CreateDirectory($_.PngAdjDir) | Out-Null
				
				$inPng  = $_.PngGrayActual
				$outPng = $_.PngAdj
				$log    = $_.Log
				
				if (-not $inPng) { throw "Missing PngGrayActual" }
				
				$Mode               = [string]$using:Mode
				$SpecScale          = [double]$using:SpecScale
				$Knee               = [double]$using:Knee
				$PostScale          = [double]$using:PostScale
				$GlobalScale        = [double]$using:GlobalScale
				$AutoKnee           = [bool]$using:AutoKnee
				$KneeMin            = [double]$using:KneeMin
				$KneeMax            = [double]$using:KneeMax
				$SigmaLo            = [double]$using:SigmaLo
				$SigmaHi            = [double]$using:SigmaHi
				$H                  = [double]$using:HighlightStart
				$MaxSpec            = [double]$using:MaxSpec
				
				$FlatBright         = [bool]$using:FlatBright
				$FlatBrightMeanMin  = [double]$using:FlatBrightMeanMin
				$FlatBrightSigmaMax = [double]$using:FlatBrightSigmaMax
				$FlatBrightScale    = [double]$using:FlatBrightScale
				
				$BrightBusy         = [bool]$using:BrightBusy
				$BrightBusyMeanMin  = [double]$using:BrightBusyMeanMin
				$BrightBusySigmaMin = [double]$using:BrightBusySigmaMin
				$BrightBusyScale    = [double]$using:BrightBusyScale
				
				if ($GlobalScale -le 0.0) { $GlobalScale = 1.0 }
				
				$tmpScaled = [System.IO.Path]::Combine($_.PngAdjDir, ($_.Base + "_adj_scaled.png"))
				if (Test-Path -LiteralPath $tmpScaled) {
					Remove-Item -LiteralPath $tmpScaled -Force -ErrorAction SilentlyContinue
				}
				
				if ($Mode -eq "Multiply") {
					$finalScale = $SpecScale * $GlobalScale
					& $using:MagickExe $inPng `
					-evaluate Multiply $finalScale -clamp `
					-define png:exclude-chunk=gAMA,cHRM,iCCP,sRGB -strip `
					$outPng 2>&1 | Add-Content -LiteralPath $log
				}
				else {
					$k = $Knee
					$sigma = 0.0
					$mean  = 0.0
					
					if ($AutoKnee -or $FlatBright -or $BrightBusy) {
						$sigmaStr = & $using:MagickExe $inPng -format "%[fx:standard_deviation]" info: 2>$null
						if ($sigmaStr -match '([0-9.eE+-]+)') { $sigma = [double]$Matches[1] }
						
						$meanStr = & $using:MagickExe $inPng -format "%[fx:mean]" info: 2>$null
						if ($meanStr -match '([0-9.eE+-]+)') { $mean = [double]$Matches[1] }
					}
					
					if ($AutoKnee) {
						$den = [Math]::Max(1e-9, ($SigmaHi - $SigmaLo))
						$t = ($sigma - $SigmaLo) / $den
						if ($t -lt 0) { $t = 0 } elseif ($t -gt 1) { $t = 1 }
						$k = ($KneeMin + $t * ($KneeMax - $KneeMin))
						
						Add-Content -LiteralPath $log -Value ("[AutoKnee] mean={0} sigma={1} -> K={2}" -f `
						$mean.ToString("0.######"), $sigma.ToString("0.######"), $k.ToString("0.######"))
					}
					
					# ------------------------------------------------------------------
					# BrightBusy branch:
					# bright overall + high variance/busy atlas
					# Checked before FlatBright
					# ------------------------------------------------------------------
					if ($BrightBusy -and $mean -ge $BrightBusyMeanMin -and $sigma -ge $BrightBusySigmaMin) {
						Add-Content -LiteralPath $log -Value ("[BrightBusy] mean={0} sigma={1} -> Multiply={2}" -f `
						$mean.ToString("0.######"), $sigma.ToString("0.######"), $BrightBusyScale.ToString("0.######"))
						
						$bbScale = $BrightBusyScale * $GlobalScale
						& $using:MagickExe $inPng `
						-evaluate Multiply $bbScale -clamp `
						-define png:exclude-chunk=gAMA,cHRM,iCCP,sRGB -strip `
						$outPng 2>&1 | Add-Content -LiteralPath $log
					}
					# ------------------------------------------------------------------
					# FlatBright branch:
					# bright overall + flat enough
					# ------------------------------------------------------------------
					elseif ($FlatBright -and $mean -ge $FlatBrightMeanMin -and $sigma -le $FlatBrightSigmaMax) {
						Add-Content -LiteralPath $log -Value ("[FlatBright] mean={0} sigma={1} -> Multiply={2}" -f `
						$mean.ToString("0.######"), $sigma.ToString("0.######"), $FlatBrightScale.ToString("0.######"))
						
						$fbScale = $FlatBrightScale * $GlobalScale
						& $using:MagickExe $inPng `
						-evaluate Multiply $fbScale -clamp `
						-define png:exclude-chunk=gAMA,cHRM,iCCP,sRGB -strip `
						$outPng 2>&1 | Add-Content -LiteralPath $log
					}
					else {
						if ($H -lt 0.0) { $H = 0.0 }
						if ($H -gt 1.0) { $H = 1.0 }
						
						$Hstr = $H.ToString("0.################")
						$kstr = $k.ToString("0.################")
						$pstr = $PostScale.ToString("0.################")
						$gstr = $GlobalScale.ToString("0.################")
						
						$fx = "((u<=${Hstr}) ? u : ( ${Hstr} + (1-${Hstr}) * (1 - pow(1 - ((u-${Hstr})/(1-${Hstr})), ${kstr})) * ${pstr} )) * ${gstr}"
						
						& $using:MagickExe $inPng -alpha off -colorspace Gray `
						-fx $fx -clamp `
						-define png:exclude-chunk=gAMA,cHRM,iCCP,sRGB -strip `
						$outPng 2>&1 | Add-Content -LiteralPath $log
					}
				}
				
				if ($LASTEXITCODE -ne 0) { throw "magick adjust failed (exit=$LASTEXITCODE)" }
				if (-not (Test-Path -LiteralPath $outPng)) { throw "magick did not produce adjusted PNG: $outPng" }
				
				# Optional scale-to-max-after-remap
				if ($MaxSpec -gt 0.0 -and $MaxSpec -lt 1.0) {
					$maxStr = & $using:MagickExe $outPng -format "%[fx:maxima]" info: 2>$null
					$imgMax = 1.0
					if ($maxStr -match '([0-9.eE+-]+)') { $imgMax = [double]$Matches[1] }
					
					if ($imgMax -gt 1e-9) {
						$scaleToMax = [Math]::Min(1.0, ($MaxSpec / $imgMax))
						Add-Content -LiteralPath $log -Value ("[ScaleToMax] adjustedMax={0} targetMax={1} -> scale={2}" -f `
						$imgMax.ToString("0.######"), $MaxSpec.ToString("0.######"), $scaleToMax.ToString("0.######"))
						
						if ($scaleToMax -lt 0.999999) {
							& $using:MagickExe $outPng `
							-evaluate Multiply $scaleToMax -clamp `
							-define png:exclude-chunk=gAMA,cHRM,iCCP,sRGB -strip `
							$tmpScaled 2>&1 | Add-Content -LiteralPath $log
							
							if ($LASTEXITCODE -ne 0) { throw "magick scale-to-max failed (exit=$LASTEXITCODE)" }
							if (-not (Test-Path -LiteralPath $tmpScaled)) { throw "magick did not produce scaled PNG: $tmpScaled" }
							
							Move-Item -LiteralPath $tmpScaled -Destination $outPng -Force
						}
					}
				}
				
				if (-not (Test-Path -LiteralPath $outPng)) { throw "Final adjusted PNG missing: $outPng" }
				
				$ok = $true
			} catch {
				$err = $_.Exception.Message
				try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
			} finally {
				if ($tmpScaled -and (Test-Path -LiteralPath $tmpScaled)) {
					Remove-Item -LiteralPath $tmpScaled -Force -ErrorAction SilentlyContinue
				}
				[PSCustomObject]@{ FullName=$_.FullName; Ok=$ok; Error=$err; Done=$true }
			}
		}
		
		$s5=@{}; foreach($r in $stage5Results){ $s5[$r.FullName]=$r }
		
		$manifest5 = New-Object System.Collections.ArrayList
		$missing5.Clear() | Out-Null
		foreach ($m in $manifest4a) {
			$r = $s5[$m.FullName]
			$a = Find-ExpectedFile -Path $m.PngAdj
			if ($r -and $r.Ok -and $a) {
				$m.PngAdjActual = $a
				[void]$manifest5.Add($m)
			} else {
				$errMsg = "Missing adjusted PNG on disk"
				if ($r -and $r.Error) { $errMsg = [string]$r.Error }
				[void]$missing5.Add([PSCustomObject]@{ File=$m.FullName; Error=$errMsg })
			}
		}
		
		Write-Host ("Stage 5 verified on disk. OK={0} MISSING={1}" -f $manifest5.Count, $missing5.Count)
		if ($missing5.Count -gt 0) { $missing5 | Select-Object -First 20 File,Error | Format-Table -AutoSize }
		
		$manifest5a = [object[]]$manifest5.ToArray()
		
		# --------------------------------------------------------------------------------------
		# Stage 6: Encode to BC4 DX9 ATI1, rename to exact filename (texconv core call preserved)
		# --------------------------------------------------------------------------------------
		Write-Host "Stage 6: Encode BC4 (parallel) + rename (parallel)..."
		
		if ($manifest5a.Count -eq 0) {
			Write-Host "Stage 6 skipped: no adjusted PNGs were produced by Stage 5."
			$builtCount = $copyOK + 0
			Write-Host ""
			Write-Host "Done processing (disk-verified)."
			Write-Host ("OK (built total) : {0}" -f $builtCount)
			Write-Host ("  - BC4 built    : 0")
			Write-Host ("  - Copied       : {0}" -f $copyOK)
			Write-Host ("FAIL (any)       : {0}" -f ($missing2.Count + $missing4.Count + $missing5.Count))
			Write-Host ""
			Write-Host "Output DDS tree: $OutRoot"
			Write-Host "Logs folder    : $LogRoot"
			return
		}
		
		$stage6Results = Invoke-ParallelStageWithProgress `
		-Activity "Stage 6: Encode BC4" `
		-InputObject $manifest5a `
		-ThrottleLimit $ThrottleLimit `
		-CountPath $OutRoot `
		-CountFilter "*.dds" `
		-ParallelScript {
			$ok=$false; $err=$null
			try {
				[System.IO.Directory]::CreateDirectory($_.OutDir) | Out-Null
				
				$inPng = $_.PngAdjActual
				$finalDds = $_.OutDds
				$tmpDir = $_.EncTmpDir
				$log = $_.Log
				
				if (-not $inPng) { throw "Missing PngAdjActual" }
				
				[System.IO.Directory]::CreateDirectory($tmpDir) | Out-Null
				Get-ChildItem -LiteralPath $tmpDir -Filter *.dds -File -ErrorAction SilentlyContinue |
				Remove-Item -Force -ErrorAction SilentlyContinue
				
				# --- CORE COMMAND (KEEP INTACT) ---
				$tc = & $using:TexconvExe -nologo -f BC4_UNORM -dx9 --ignore-srgb -m 1 -y -o $tmpDir $inPng 2>&1
				$tc | Add-Content -LiteralPath $log
				if ($LASTEXITCODE -ne 0) { throw "texconv encode failed (exit=$LASTEXITCODE)" }
				
				$produced = @(Get-ChildItem -LiteralPath $tmpDir -Filter *.dds -File -ErrorAction SilentlyContinue)
				if ($produced.Count -ne 1) { throw "texconv produced $($produced.Count) DDS files in tmp dir (expected 1)." }
				
				if (Test-Path -LiteralPath $finalDds) { Remove-Item -LiteralPath $finalDds -Force }
				Move-Item -LiteralPath $produced[0].FullName -Destination $finalDds -Force
				
				if (-not (Test-Path -LiteralPath $finalDds)) { throw "Final DDS missing after move: $finalDds" }
				
				$ok = $true
			} catch {
				$err = $_.Exception.Message
				try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
			} finally {
				[PSCustomObject]@{ FullName=$_.FullName; Ok=$ok; Error=$err; Done=$true }
			}
		}
		
		$s6=@{}; foreach($r in $stage6Results){ $s6[$r.FullName]=$r }
		
		$builtBC4.Clear() | Out-Null
		$missing6 = New-Object System.Collections.ArrayList
		
		foreach ($m in $manifest5a) {
			$r = $s6[$m.FullName]
			$a = Find-ExpectedFile -Path $m.OutDds
			if ($r -and $r.Ok -and $a) {
				$m.OutDdsActual = $a
				[void]$builtBC4.Add($m)
			} else {
				$errMsg = "Missing DDS on disk"
				if ($r -and $r.Error) { $errMsg = [string]$r.Error }
				[void]$missing6.Add([PSCustomObject]@{ File=$m.FullName; Error=$errMsg })
			}
		}
		
		Write-Host ("Stage 6 verified on disk. OK={0} MISSING={1}" -f $builtBC4.Count, $missing6.Count)
		if ($missing6.Count -gt 0) { $missing6 | Select-Object -First 20 File,Error | Format-Table -AutoSize }
		$missing2.AddRange($missing6) | Out-Null
	}
	
	$builtCount = $copyOK + $builtBC4.Count
	Write-Host ""
	Write-Host "Done processing (disk-verified)."
	Write-Host ("OK (built total) : {0}" -f $builtCount)
	Write-Host ("  - BC4 built    : {0}" -f $builtBC4.Count)
	Write-Host ("  - Copied       : {0}" -f $copyOK)
	Write-Host ("FAIL (any)       : {0}" -f ($missing2.Count + $missing4.Count + $missing5.Count))
	Write-Host ""
	Write-Host "Output DDS tree: $OutRoot"
	Write-Host "Logs folder    : $LogRoot"
}

# --------------------------------------------------------------------------------------
# APPLY (always uses whatever DDS exists in OutRoot, excluding _work/_logs/_encode_tmp)
# --------------------------------------------------------------------------------------
if (-not $Apply) {
	Write-Host ""
	Write-Host "DONE (no -Apply): originals were NOT modified."
	Write-Host "Work folder kept at: $WorkRoot"
	return
}

Write-Host ("Applying outputs from OutRoot (existing + new). OutRoot DDS count: {0}" -f `
(Get-ChildItem -LiteralPath $OutRoot -Recurse -Filter *.dds -File -ErrorAction SilentlyContinue |
Where-Object { $_.FullName -notmatch '\\_work\\' -and $_.FullName -notmatch '\\_logs\\' -and $_.FullName -notmatch '\\_encode_tmp\\' }).Count
)

Write-Host ""
Write-Host "Applying outputs back onto RootDir..."

$newFiles = @(Get-ChildItem -LiteralPath $OutRoot -Recurse -Filter *.dds -File -ErrorAction SilentlyContinue |
Where-Object { $_.FullName -notmatch '\\_work\\' -and $_.FullName -notmatch '\\_logs\\' -and $_.FullName -notmatch '\\_encode_tmp\\' })

if ($newFiles.Count -eq 0) {
	Write-Host "No DDS outputs found under OutRoot to apply."
	return
}

if (-not $NoBackup) {
	Ensure-Dir $BackupDir
	Write-Host "Backup enabled: $BackupDir"
} else {
	Write-Host "Backup disabled (-NoBackup)."
}

$applied   = 0
$backuped  = 0
$applyFail = New-Object System.Collections.ArrayList

foreach ($nf in $newFiles) {
	try {
		$rel2 = Get-RelativePath -base $OutRoot -full $nf.FullName
		$dest = Join-Path $rootFull $rel2
		Ensure-Dir (Split-Path $dest -Parent)
		
		if ((Test-Path -LiteralPath $dest) -and (-not $NoBackup)) {
			$backupPath = Join-Path $BackupDir $rel2
			Ensure-Dir (Split-Path $backupPath -Parent)
			Copy-Item -LiteralPath $dest -Destination $backupPath -Force
			$backuped++
		}
		
		Copy-Item -LiteralPath $nf.FullName -Destination $dest -Force
		
		$applied++
		if (($applied % 50) -eq 0) { Write-Host ("Applied {0}/{1}..." -f $applied, $newFiles.Count) }
	} catch {
		[void]$applyFail.Add([PSCustomObject]@{ File=$nf.FullName; Error=$_.Exception.Message })
	}
}

Write-Host ""
Write-Host "Apply complete."
Write-Host ("Applied files   : {0}" -f $applied)
Write-Host ("Backups created : {0}" -f $backuped)
if (-not $NoBackup) { Write-Host ("Backup folder   : {0}" -f $BackupDir) }

if ($applyFail.Count -gt 0) {
	Write-Host ""
	Write-Host ("Apply FAIL={0}. Keeping folders for inspection:" -f $applyFail.Count)
	$applyFail | Select-Object -First 20 File,Error | Format-Table -AutoSize
	Write-Host "  OutRoot: $OutRoot"
	Write-Host "  Work  : $WorkRoot"
	Write-Host "  Logs  : $LogRoot"
	Write-Host "  EncTmp: $EncodeTmp"
	if (-not $NoBackup) { Write-Host "  Backup: $BackupDir" }
	return
}

Write-Host ""

if ($Keep) {
	Write-Host "Apply succeeded. -Keep specified: skipping cleanup (keeping all folders)."
	Write-Host "  OutRoot: $OutRoot"
	Write-Host "  Work  : $WorkRoot"
	Write-Host "  Logs  : $LogRoot"
	Write-Host "  EncTmp: $EncodeTmp"
	if (-not $NoBackup) { Write-Host "  Backup: $BackupDir" }
	else { Write-Host "  Backup: disabled (-NoBackup)" }
	return
}

Write-Host "Apply succeeded. Cleaning folders..."

# remove intermediates always
Remove-Item -Recurse -Force $WorkRoot  -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $EncodeTmp -ErrorAction SilentlyContinue

# remove backup only if enabled
if (-not $NoBackup) {
	Remove-Item -Recurse -Force $BackupDir -ErrorAction SilentlyContinue
}

# remove OutRoot (final outputs were applied)
Remove-Item -Recurse -Force $OutRoot -ErrorAction SilentlyContinue

Write-Host "Cleanup complete."