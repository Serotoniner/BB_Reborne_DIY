# BB Reborne DIY Tool
# Copyright (C) 2026 Greg Pitta
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# See the LICENSE file for details.


param(
[Parameter(Mandatory=$true)][string]$RootDir,       #
[Parameter(Mandatory=$true)][string]$TexconvExe,    #
[Parameter(Mandatory=$true)][string]$MagickExe,     #
[Parameter(Mandatory=$true)][string]$RealEsrganExe, # 

[string]$RealEsrganModelName = "BBReborneUpscaler",
[string]$RealEsrganModelFile = "",

[int]$ThrottleLimit = 1,
[int]$ProgressEvery = 10,       # legacy print frequency (kept, but progress bars are primary now)
[switch]$DryRun,
[switch]$NoUpscale,          # Set2 mode: keep treatments but final texture size remains 1x

# Apply results back onto RootDir after processing completes (or apply existing OutRoot if nothing to build)
[switch]$Apply,

# Keep outputs/temp/logs/backup folders even when applying (skip cleanup)
[switch]$Keep,

[string]$BackupDir = "",        # defaults to sibling: "{leaf}_backup_original_dds"
[switch]$NoBackup,

# Optional: rebuild even if OutRoot already has DDS (resume is default behavior)
[switch]$ForceRebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($ThrottleLimit -lt 1) { $ThrottleLimit = 1 }
$Use1xNoUpscale = [bool]$NoUpscale

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

Write-Host "SCRIPT VERSION: 2026-02-19-main-sha2 (AI upscale: short SHA temp paths + letter-L-safe _a detection)"

if ($PSVersionTable.PSVersion.Major -lt 7) { throw "Run with PowerShell 7+ (pwsh)." }
if (-not (Test-Path -LiteralPath $RootDir)) { throw "RootDir not found: $RootDir" }
if (-not (Test-Path -LiteralPath $TexconvExe)) { throw "texconv.exe not found: $TexconvExe" }
if (-not (Test-Path -LiteralPath $RealEsrganExe)) { throw "realesrgan exe not found: $RealEsrganExe" }
if (-not (Test-Path -LiteralPath $MagickExe)) { throw "magick.exe not found: $MagickExe" }

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
function Is-HiresDiffuseFolderName([string]$name) {
	# Hires diffuse/albedo token _a. Exclude only the true low-res albedo suffix _a_l.
	# Do not reject names that contain an unrelated _L_ token, e.g. o355004_AM_M_1100_L_a.
	if ($name -match '_a_l(?=(_|-|\.|$))') { return $false }
	return ($name -match '_a(?=(_|-|\.|$))')
}
function LooksLikeSkyName([string]$s) {
	return ($s -match '(?i)(sky|cloud|clond|cirrus)')
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
	
	# last resort: allow suffixes (base*.ext)
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
    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
	[AllowEmptyCollection()]
	[object[]]$InputObject,
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
			$all = @(Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue)
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


# --------------------------------------------------------------------------------------
# Output + temp dirs (match Script #1 scheme: rooted at parent(RootDir), prefixed with leaf(RootDir))
# --------------------------------------------------------------------------------------
function Resolve-RealEsrganModelName {
	param(
		[Parameter(Mandatory=$true)][string]$ExePath,
		[AllowNull()][string]$ModelName,
		[AllowNull()][string]$ModelFile
	)

	$name = [string]$ModelName
	if ([string]::IsNullOrWhiteSpace($name)) {
		$name = "BBReborneUpscaler"
	}

	if ([string]::IsNullOrWhiteSpace($ModelFile)) {
		return $name.Trim()
	}

	$modelPath = (Resolve-Path -LiteralPath $ModelFile).Path
	$ext = [System.IO.Path]::GetExtension($modelPath).ToLowerInvariant()
	if ($ext -ne ".bin" -and $ext -ne ".param") {
		throw "Real-ESRGAN model file must be .bin or .param: $modelPath"
	}

	$modelDir = Split-Path -Parent $modelPath
	$modelStem = [System.IO.Path]::GetFileNameWithoutExtension($modelPath)
	$sourceBin = Join-Path $modelDir ($modelStem + ".bin")
	$sourceParam = Join-Path $modelDir ($modelStem + ".param")

	if (-not (Test-Path -LiteralPath $sourceBin -PathType Leaf)) {
		throw "Real-ESRGAN model .bin not found: $sourceBin"
	}
	if (-not (Test-Path -LiteralPath $sourceParam -PathType Leaf)) {
		throw "Real-ESRGAN model .param not found: $sourceParam"
	}

	$exeDir = Split-Path -Parent $ExePath
	$activeModelsDir = Join-Path $exeDir "models"
	[System.IO.Directory]::CreateDirectory($activeModelsDir) | Out-Null

	Copy-Item -LiteralPath $sourceBin -Destination (Join-Path $activeModelsDir (Split-Path -Leaf $sourceBin)) -Force
	Copy-Item -LiteralPath $sourceParam -Destination (Join-Path $activeModelsDir (Split-Path -Leaf $sourceParam)) -Force

	return $modelStem
}

$ResolvedRealEsrganModelName = Resolve-RealEsrganModelName -ExePath $RealEsrganExe -ModelName $RealEsrganModelName -ModelFile $RealEsrganModelFile

$rootFull   = (Resolve-Path -LiteralPath $RootDir).Path
$rootFull   = $rootFull -replace '[\\/]+$',''
$rootLeaf   = Split-Path $rootFull -Leaf
$rootParent = Split-Path $rootFull -Parent

$OutRoot   = Join-Path $rootParent ("{0}_upscaled_2x_ai_a_bc1_bc7" -f $rootLeaf)
$WorkRoot  = Join-Path $OutRoot "_work"
$LogRoot   = Join-Path $OutRoot "_logs"

# Stage work dirs (disk-verified pipeline)
$png1Root  = Join-Path $WorkRoot "stage1_png"      # DDS -> PNG
$png4Root  = Join-Path $WorkRoot "stage2_png4x"    # Real-ESRGAN output
$png2Root  = Join-Path $WorkRoot "stage3_png2x"    # Downscaled 2x PNG

if ([string]::IsNullOrWhiteSpace($BackupDir)) {
	$BackupDir = Join-Path $rootParent ("{0}_backup_original_dds" -f $rootLeaf)
}

if (-not $DryRun) {
	Ensure-Dir $OutRoot
	Ensure-Dir $WorkRoot
	Ensure-Dir $LogRoot
	Ensure-Dir $png1Root
	Ensure-Dir $png4Root
	Ensure-Dir $png2Root
	
	if ($Apply -and (-not $NoBackup)) {
		Ensure-Dir $BackupDir
	}
}

Write-Host "RootDir : $rootFull"
Write-Host "OutRoot : $OutRoot"
Write-Host "WorkRoot: $WorkRoot"
Write-Host "LogRoot : $LogRoot"
Write-Host "Throttle: $ThrottleLimit"
Write-Host "Rule: Upscale BC1* and BC7* diffuse (_a) with Real-ESRGAN, preserve SRGB vs UNORM, copy-through everything else."
Write-Host "DryRun : $DryRun"
Write-Host "Apply  : $Apply"
Write-Host "Keep   : $Keep"
Write-Host "ForceRebuild: $ForceRebuild"
Write-Host "RealESRGAN model: $ResolvedRealEsrganModelName"
Write-Host "Backup : " -NoNewline
if ($Apply -and (-not $NoBackup)) { Write-Host $BackupDir } else { Write-Host "disabled" }
Write-Host ""

# --------------------------------------------------------------------------------------
# Collect target DDS (hires diffuse folders) + manifest
# --------------------------------------------------------------------------------------
$folders = @(Get-ChildItem -LiteralPath $rootFull -Directory -Recurse -Force |
Where-Object { $_.Name -like "*-tpf-dcx" -and (Is-HiresDiffuseFolderName $_.Name) })

if ($folders.Count -eq 0) {
	Write-Host "No hires diffuse (*_a* but not *_l-*) '-tpf-dcx' folders found."
	return
}

Write-Host ("Target folders (hires a_diffuse): {0}" -f $folders.Count)

$ddsList = New-Object System.Collections.ArrayList
foreach ($fld in $folders) {
	$dds = @(Get-ChildItem -LiteralPath $fld.FullName -Filter *.dds -File -ErrorAction SilentlyContinue)
	foreach ($d in $dds) { [void]$ddsList.Add($d) }
}
Write-Host ("Total DDS files in those folders: {0}" -f $ddsList.Count)
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
	
	$outDir   = Join-Path $OutRoot $relDir
	$outDds   = Join-Path $outDir $f.Name
	
	# Keep final output paths unchanged, but keep all transient PNG stages in
	# short SHA folders to avoid Windows path-length failures in texconv/ImageMagick/Real-ESRGAN.
	$workKey = Get-ShortWorkKey $relDir
	
	$png1Dir  = Join-Path $png1Root $workKey
	$png4Dir  = Join-Path $png4Root $workKey
	$png2Dir  = Join-Path $png2Root $workKey
	
	$png1 = Join-Path $png1Dir ($base + ".png")
	$png4 = Join-Path $png4Dir ($base + ".png")
	$png2 = Join-Path $png2Dir ($base + ".png")
	
	$log = Join-Path $LogRoot ("ai_upscale_" + $workKey + ".log")
	
	$backupPath = if ($Apply -and (-not $NoBackup)) { Join-Path $BackupDir $rel } else { $null }
	
	$isSky = (LooksLikeSkyName $base) -or (LooksLikeSkyName $relDir)
	
	[void]$manifest.Add([PSCustomObject]@{
		FullName=$full; Rel=$rel; RelDir=$relDir; WorkKey=$workKey; Base=$base
		IsSky = [bool]$isSky
		OutDir=$outDir; OutDds=$outDds
		Png1Dir=$png1Dir; Png4Dir=$png4Dir; Png2Dir=$png2Dir
		Png1=$png1; Png4=$png4; Png2=$png2
		Log=$log
		BackupPath=$backupPath
		
		Png1Actual=$null; Png4Actual=$null; Png2Actual=$null; OutDdsActual=$null
		IsBC1=$false; IsBC7=$false; FmtOut=$null
		SkipBecauseExists=$false
	})
}

Write-Host "Manifest: $($manifest.Count) files."
if ($DryRun) {
	Write-Host "DRYRUN: not executing stages."
	Write-Host "Outputs would be in: $OutRoot"
	return
}

$manifest0 = [object[]]$manifest.ToArray()

# --------------------------------------------------------------------------------------
# Stage 0: mark skips (existing outputs), with ForceRebuild option
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

# --------------------------------------------------------------------------------------
# BUILD PIPELINE (Stages 1-5) only when there is something to build
# --------------------------------------------------------------------------------------
$copiedOK = 0
$missing2 = New-Object System.Collections.ArrayList
$missing4 = New-Object System.Collections.ArrayList
$missing5 = New-Object System.Collections.ArrayList
$manifest5 = New-Object System.Collections.ArrayList

if ($needBuild) {
	
	# Stage 1: backup originals (serial) for files we WILL build (Apply only)
	if ($wantApply -and (-not $NoBackup)) {
		Write-Host "Stage 1: Backup originals (serial)..."
		$i = 0
		foreach ($m in $todo0) {
			Ensure-Dir (Split-Path $m.BackupPath -Parent)
			Copy-Item -LiteralPath $m.FullName -Destination $m.BackupPath -Force
			$i++
			if (($i % 500) -eq 0) { Write-Host "  backed up $i / $($todo0.Count)" }
		}
		Write-Host ("Stage 1 done. OK={0} FAIL=0" -f $i)
	}
	
	# Stage 2: DDS -> PNG + detect format
	Write-Host "Stage 2: DDS -> PNG (parallel) + detect format..."
	$stage2Results = Invoke-ParallelStageWithProgress `
    -Activity "Stage 2: DDS -> PNG" `
    -InputObject $todo0 `
    -ThrottleLimit $ThrottleLimit `
    -CountPath $png1Root `
    -CountFilter "*.png" `
    -ParallelScript {
		$ok = $false
		$err = $null
		$isBC1 = $false
		$isBC7 = $false
		$fmtOut = $null
		try {
			[System.IO.Directory]::CreateDirectory($_.Png1Dir) | Out-Null
			[System.IO.Directory]::CreateDirectory($_.OutDir)  | Out-Null
			[System.IO.Directory]::CreateDirectory((Split-Path $_.Log -Parent)) | Out-Null
			
			$dds = $_.FullName
			$png1 = $_.Png1
			$w1 = $_.Png1Dir
			$log = $_.Log
			
			# --- CORE COMMAND (KEEP INTACT) ---
			$tcOut = & $using:TexconvExe -nologo -ignoremips -ft png -y -o $w1 $dds 2>&1 #here IGNOREMIPS for cainhurst but does it break something else?
			$tcOut | Add-Content -LiteralPath $log
			if (-not (Test-Path -LiteralPath $png1)) { throw "texconv did not produce PNG: $png1" }
			
			$isBC1 = ($tcOut -match '\bBC1_')
			$isBC7 = ($tcOut -match '\bBC7_')
			
			if ($isBC1) {
				$fmtOut = if ($tcOut -match '\bBC1_UNORM_SRGB\b') { "BC1_UNORM_SRGB" } else { "BC1_UNORM" }
				} elseif ($isBC7) {
				$fmtOut = if ($tcOut -match '\bBC7_UNORM_SRGB\b') { "BC7_UNORM_SRGB" } else { "BC7_UNORM" }
			}
			
			$ok = $true
			} catch {
			$err = $_.Exception.Message
			try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
			} finally {
			[PSCustomObject]@{
				FullName = $_.FullName
				Png1Path = $_.Png1
				IsBC1    = [bool]$isBC1
				IsBC7    = [bool]$isBC7
				FmtOut   = $fmtOut
				Ok       = $ok
				Error    = $err
				Done     = $true
			}
		}
	}
	
	# verify stage2 outputs
	$byFull = @{}
	foreach ($m in $todo0) { $byFull[$m.FullName] = $m }
	
	$manifest2 = New-Object System.Collections.ArrayList
	$missing2.Clear() | Out-Null
	
	foreach ($r in $stage2Results) {
		if (-not $byFull.ContainsKey($r.FullName)) { continue }
		$m = $byFull[$r.FullName]
		
		$actual = Find-ExpectedFile -Path $m.Png1
		if ($r.Ok -and $actual) {
			$m.Png1Actual = $actual
			$m.IsBC1 = [bool]$r.IsBC1
			$m.IsBC7 = [bool]$r.IsBC7
			$m.FmtOut = $r.FmtOut
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
	
	# Stage 3: copy-through non-BC1/BC7
	Write-Host "Stage 3: Copy-through non-BC1/BC7 (parallel)..."
	$copyList = @($manifest2a | Where-Object { -not $_.IsBC1 -and -not $_.IsBC7 })
	$upList   = @($manifest2a | Where-Object { $_.IsBC1 -or $_.IsBC7 })
	
	$skyList    = @($upList | Where-Object { $_.IsSky })
	$nonskyList = @($upList | Where-Object { -not $_.IsSky })
	
	Write-Host ("Stage 4 plan: SKY={0}  NONSKY={1}" -f $skyList.Count, $nonskyList.Count)
	
	if ($copyList.Count -eq 0) {
		Write-Host "Stage 3: Nothing to copy-through (all are BC1/BC7)."
		$copiedOK = 0
		} else {
		$null = Invoke-ParallelStageWithProgress `
		-Activity "Stage 3: Copy-through others" `
		-InputObject $copyList `
		-ThrottleLimit $ThrottleLimit `
		-CountPath $OutRoot `
		-CountFilter "*.dds" `
		-ParallelScript {
			try {
				[System.IO.Directory]::CreateDirectory($_.OutDir) | Out-Null
				Copy-Item -LiteralPath $_.FullName -Destination $_.OutDds -Force
				} catch {
				try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $_.Exception.Message) } catch {}
			}
			[PSCustomObject]@{ File=$_.FullName; Done=$true }
		}
		
		$copiedOK = 0
		foreach ($m in $copyList) {
			$actual = Find-ExpectedFile -Path $m.OutDds
			if ($actual) { $m.OutDdsActual = $actual; $copiedOK++ }
		}
		Write-Host ("Stage 3 verified on disk. COPY_OK={0} COPY_TOTAL={1}" -f $copiedOK, $copyList.Count)
	}
	
	# Stage 4 + 5 only for BC1/BC7
	if ($upList.Count -eq 0) {
		Write-Host "No BC1/BC7 files to upscale after Stage 3."
		$manifest5 = New-Object System.Collections.ArrayList
		$missing4.Clear() | Out-Null
		$missing5.Clear() | Out-Null
		} else {
		
		# Stage 4A: SKY files -> ImageMagick 2x directly to png2
		$manifest4 = New-Object System.Collections.ArrayList
		$missing4.Clear() | Out-Null
		
		if ($skyList.Count -gt 0) {
			Write-Host "Stage 4A: SKY -> ImageMagick 2x (parallel)..."
			
			$stage4aResults = Invoke-ParallelStageWithProgress `
			-Activity "Stage 4A: SKY (Magick 2x)" `
			-InputObject $skyList `
			-ThrottleLimit $ThrottleLimit `
			-CountPath $png2Root `
			-CountFilter "*.png" `
			-ParallelScript {
				$ok  = $false
				$err = $null
				try {
					[System.IO.Directory]::CreateDirectory($_.Png2Dir) | Out-Null
					
					$png1 = $_.Png1Actual
					$png2 = $_.Png2
					$log  = $_.Log
					
					if (-not $png1) { throw "Missing Png1Actual" }
					
					# Upscale 2x using ImageMagick
					
					#$imOut = & $using:MagickExe $png1 -alpha on -colorspace sRGB -define png:sRGB=intent=0 -define png:gAMA=0.45455 "PNG32:$png2" 2>&1
					#$imOut | Add-Content -LiteralPath $log
					
					if ($using:Use1xNoUpscale) {
						$imOut = & $using:MagickExe $png1 `
						-alpha on `
						-colorspace RGB `
						-gamma 2.4 `
						-filter Mitchell `
						-attenuate 0.06 +noise Gaussian `
						-gaussian-blur 0x0.25 `
						-ordered-dither o8x8,1 `
						-gamma 0.454545 `
						"PNG32:$png2" 2>&1
					}
					else {
						$imOut = & $using:MagickExe $png1 `
						-alpha on `
						-colorspace RGB `
						-gamma 2.4 `
						-filter Mitchell -resize "200%" `
						-attenuate 0.06 +noise Gaussian `
						-gaussian-blur 0x0.25 `
						-ordered-dither o8x8,1 `
						-gamma 0.454545 `
						"PNG32:$png2" 2>&1
					}
					
					#$imOut = & $using:MagickExe $png1 -alpha on -strip -set colorspace RGB -type TrueColorMatte "PNG32:$png2" 2>&1 #-filter Mitchell -resize "200%" -gaussian-blur 10x0
					
					# NO-OP: avoid ImageMagick entirely (prevents gamma/colorspace surprises)
					# Copy-Item -LiteralPath $png1 -Destination $png2 -Force
					# if (-not (Test-Path -LiteralPath $png2)) { throw "Copy did not produce PNG: $png2" }
					# $LASTEXITCODE  = 0
					
					if ($LASTEXITCODE -ne 0) { throw "ImageMagick 2x resize failed (exit $LASTEXITCODE)" }
					if (-not (Test-Path -LiteralPath $png2)) { throw "ImageMagick did not produce PNG: $png2" }
					
					$ok = $true
				}
				catch {
					$err = $_.Exception.Message
					try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
				}
				finally {
					[PSCustomObject]@{ FullName=$_.FullName; Ok=$ok; Error=$err; Done=$true }
				}
			}
			
			# Verify 4A outputs
			$byFull4a = @{}
			foreach ($r in $stage4aResults) { $byFull4a[$r.FullName] = $r }
			
			foreach ($m in $skyList) {
				$r  = $byFull4a[$m.FullName]
				$a2 = Find-ExpectedFile -Path $m.Png2
				if ($r -and $r.Ok -and $a2) {
					$m.Png2Actual = $a2
					[void]$manifest4.Add($m)
					} else {
					$errMsg = "Missing png2 on disk (SKY)"
					if ($r -and $r.Error) { $errMsg = [string]$r.Error }
					[void]$missing4.Add([PSCustomObject]@{ File=$m.FullName; Error=$errMsg })
				}
			}
			
			Write-Host ("Stage 4A verified on disk. OK={0} MISSING={1}" -f `
			(@($manifest4 | Where-Object { $_.IsSky })).Count, `
			(@($missing4  | Where-Object { $_.Error -like "*SKY*" })).Count)
		}
		
		# Stage 4B: Real-ESRGAN + downscale
		Write-Host "Stage 4: Real-ESRGAN 4x + downscale to 2x (parallel)..."
		
		$stage4Params = @{
			Activity       = "Stage 4: AI upscale + downscale"
			InputObject    = $nonskyList
			ThrottleLimit  = $ThrottleLimit
			CountPath      = $png2Root
			CountFilter    = "*.png"
			ParallelScript = {
				$ok  = $false
				$err = $null
				try {
					
					[System.IO.Directory]::CreateDirectory($_.Png4Dir) | Out-Null
					[System.IO.Directory]::CreateDirectory($_.Png2Dir) | Out-Null
					
					$png1 = $_.Png1Actual
					$png4 = $_.Png4
					$png2 = $_.Png2
					$log  = $_.Log
					
					if (-not $png1) { throw "Missing Png1Actual" }
					
					# --- CORE COMMAND (KEEP INTACT) ---
					& $using:RealEsrganExe -i $png1 -o $png4 -n $using:ResolvedRealEsrganModelName -f png 2>&1 | Add-Content -LiteralPath $log
					#& $using:RealEsrganExe -i $png1 -o $png4 -n realisticrescaler -f png 2>&1 | Add-Content -LiteralPath $log
					if (-not (Test-Path -LiteralPath $png4)) { throw "Real-ESRGAN did not produce PNG: $png4" }
					
					# Downscale 4x -> 2x, or 4x -> 1x when -NoUpscale is used, with ImageMagick (log output)
					if ($using:Use1xNoUpscale) {
						$imOut = & $using:MagickExe $png4 -colorspace RGB -alpha on -filter Mitchell -resize "25%" -attenuate 0.06 +noise Gaussian $png2 2>&1 
					}
					else {
						$imOut = & $using:MagickExe $png4 -colorspace RGB -alpha on -filter Mitchell -resize "50%" -attenuate 0.06 +noise Gaussian $png2 2>&1 
					}
					$imOut | Add-Content -LiteralPath $log
					if ($LASTEXITCODE -ne 0) { throw "ImageMagick resize failed (exit $LASTEXITCODE)" }
					if (-not (Test-Path -LiteralPath $png2)) { throw "Downscale did not produce PNG: $png2" }
					
					$ok = $true
				}
				catch {
					$err = $_.Exception.Message
					try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
				}
				finally {
					[PSCustomObject]@{
						FullName = $_.FullName
						Ok       = $ok
						Error    = $err
						Done     = $true
					}
				}
			}
		}
		
		$stage4Results = Invoke-ParallelStageWithProgress @stage4Params
		
		#$manifest4 = New-Object System.Collections.ArrayList
		$missing4.Clear() | Out-Null
		
		$stage4ByFull = @{}
		foreach ($r in $stage4Results) { $stage4ByFull[$r.FullName] = $r }
		
		foreach ($m in $nonskyList) {
			$r = $stage4ByFull[$m.FullName]
			$a4 = Find-ExpectedFile -Path $m.Png4
			$a2 = Find-ExpectedFile -Path $m.Png2
			if ($r -and $r.Ok -and $a2) {
				$m.Png4Actual = $a4
				$m.Png2Actual = $a2
				[void]$manifest4.Add($m)
				} else {
				$errMsg = "Missing png2 on disk (NONSKY)"
				if ($r -and $r.Error) { $errMsg = [string]$r.Error }
				[void]$missing4.Add([PSCustomObject]@{ File=$m.FullName; Error=$errMsg })
			}
		}
		
		Write-Host ("Stage 4 verified on disk. OK={0} MISSING={1}" -f $manifest4.Count, $missing4.Count)
		if ($missing4.Count -gt 0) { $missing4 | Select-Object -First 20 File,Error | Format-Table -AutoSize }
		
		$manifest4a = [object[]]$manifest4.ToArray()
		
		# Stage 5: PNG -> DDS
		Write-Host "Stage 5: PNG -> DDS (parallel)..."
		
		$stage5Params = @{
			Activity       = "Stage 5: PNG -> DDS"
			InputObject    = $manifest4a
			ThrottleLimit  = $ThrottleLimit
			CountPath      = $OutRoot
			CountFilter    = "*.dds"
			ParallelScript = {
				$ok  = $false
				$err = $null
				try {
					[System.IO.Directory]::CreateDirectory($_.OutDir) | Out-Null
					
					$png2      = $_.Png2Actual
					$outFolder = $_.OutDir
					$outDds    = $_.OutDds
					$log       = $_.Log
					
					if (-not $png2) { throw "Missing Png2Actual" }
					
					# Decide output format
					$fmt = $_.FmtOut
					if ([string]::IsNullOrWhiteSpace($fmt)) { throw "Missing FmtOut (BC1/BC7 decision)" }
					
					# Optional policy: sky textures always become BC7 SRGB
					if ($_.IsSky) {
						$fmt = "BC7_UNORM_SRGB"
					}
					
					# --- CORE COMMAND (KEEP INTACT) ---
					$tcOut2 = & $using:TexconvExe -nologo -f $fmt -m 1 -y -o $outFolder $png2 2>&1
					$tcOut2 | Add-Content -LiteralPath $log
					
					if ($LASTEXITCODE -ne 0) { throw "texconv failed (exit $LASTEXITCODE)" }
					if (-not (Test-Path -LiteralPath $outDds)) { throw "texconv did not produce DDS: $outDds" }
					
					$ok = $true
				}
				catch {
					# IMPORTANT: capture full details (much easier debugging)
					$err = ( $_ | Out-String ).Trim()
					try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
				}
				finally {
					[PSCustomObject]@{
						FullName = $_.FullName
						Ok       = $ok
						Error    = $err
						Done     = $true
					}
				}
			}
		}
		
		$stage5Results = Invoke-ParallelStageWithProgress @stage5Params
		
		$manifest5 = New-Object System.Collections.ArrayList
		$missing5.Clear() | Out-Null
		
		$stage5ByFull = @{}
		foreach ($r in $stage5Results) { $stage5ByFull[$r.FullName] = $r }
		
		foreach ($m in $manifest4a) {
			$r = $stage5ByFull[$m.FullName]
			$actual = Find-ExpectedFile -Path $m.OutDds
			if ($r -and $r.Ok -and $actual) {
				$m.OutDdsActual = $actual
				[void]$manifest5.Add($m)
				} else {
				$errMsg = "Missing DDS on disk"
				if ($r -and $r.Error) { $errMsg = [string]$r.Error }
				[void]$missing5.Add([PSCustomObject]@{ File=$m.FullName; Error=$errMsg })
			}
		}
		
		Write-Host ("Stage 5 verified on disk. OK={0} MISSING={1}" -f $manifest5.Count, $missing5.Count)
		if ($missing5.Count -gt 0) { $missing5 | Select-Object -First 20 File,Error | Format-Table -AutoSize }
	}
	
	# Summary (disk-verified)
	$bc1ok = (@($manifest5 | Where-Object { $_.IsBC1 })).Count
	$bc7ok = (@($manifest5 | Where-Object { $_.IsBC7 })).Count
	$failTotal = $missing2.Count + $missing4.Count + $missing5.Count
	
	Write-Host ""
	Write-Host "Done processing (disk-verified)."
	Write-Host ("OK (AI)     : {0}" -f $manifest5.Count)
	Write-Host ("BC1 OK      : {0}" -f $bc1ok)
	Write-Host ("BC7 OK      : {0}" -f $bc7ok)
	Write-Host ("COPY OTHER  : {0}" -f $copiedOK)
	Write-Host ("FAIL (any)  : {0}" -f $failTotal)
	Write-Host ""
	Write-Host "Output DDS tree: $OutRoot"
	Write-Host "Logs folder    : $LogRoot"
}

# --------------------------------------------------------------------------------------
# APPLY (always uses whatever DDS exists in OutRoot, excluding _work/_logs)
# --------------------------------------------------------------------------------------
if (-not $wantApply) {
	Write-Host ""
	Write-Host "DONE (no -Apply): originals were NOT modified."
	Write-Host "Work folder kept at: $WorkRoot"
	return
}

Write-Host ("Applying outputs from OutRoot (existing + new). OutRoot DDS count: {0}" -f `
@(Get-ChildItem -LiteralPath $OutRoot -Recurse -Filter *.dds -File -ErrorAction SilentlyContinue |
Where-Object { $_.FullName -notmatch '\\_work\\' -and $_.FullName -notmatch '\\_logs\\' }).Count
)

Write-Host ""
Write-Host "Applying upscaled DDS back onto RootDir..."

$newFiles = @(Get-ChildItem -LiteralPath $OutRoot -Recurse -Filter *.dds -File -ErrorAction SilentlyContinue |
Where-Object { $_.FullName -notmatch '\\_work\\' -and $_.FullName -notmatch '\\_logs\\' })

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

$applied = 0
$backuped = 0
$applyFail = New-Object System.Collections.ArrayList

foreach ($nf in $newFiles) {
	try {
		$rel  = Get-RelativePath -base $OutRoot -full $nf.FullName
		$dest = Join-Path $rootFull $rel
		Ensure-Dir (Split-Path $dest -Parent)
		
		if ((Test-Path -LiteralPath $dest) -and (-not $NoBackup)) {
			$backupPath = Join-Path $BackupDir $rel
			Ensure-Dir (Split-Path $backupPath -Parent)
			Copy-Item -LiteralPath $dest -Destination $backupPath -Force
			$backuped++
		}
		
		Copy-Item -LiteralPath $nf.FullName -Destination $dest -Force
		
		$applied++
		if (($applied % 25) -eq 0) {
			Write-Host ("Applied {0}/{1}..." -f $applied, $newFiles.Count)
		}
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
	Write-Host ("Apply FAIL={0}. Keeping temp folders for inspection:" -f $applyFail.Count)
	$applyFail | Select-Object -First 20 File,Error | Format-Table -AutoSize
	Write-Host "  OutRoot: $OutRoot"
	Write-Host "  Work  : $WorkRoot"
	Write-Host "  Logs  : $LogRoot"
	if (-not $NoBackup) { Write-Host "  Backup: $BackupDir" }
	return
}

Write-Host ""

if ($Keep) {
	Write-Host "Apply succeeded. -Keep specified: skipping cleanup (keeping all folders)."
	Write-Host ("  OutRoot: {0}" -f $OutRoot)
	Write-Host ("  Work  : {0}" -f $WorkRoot)
	Write-Host ("  Logs  : {0}" -f $LogRoot)
	if (-not $NoBackup) { Write-Host ("  Backup: {0}" -f $BackupDir) }
	else { Write-Host "  Backup: disabled (-NoBackup)" }
	return
}

Write-Host "Apply succeeded. Cleaning temp folders..."

# Always remove work intermediates
Remove-Item -Recurse -Force $WorkRoot -ErrorAction SilentlyContinue

# Remove backup only if it was actually used
if (-not $NoBackup) {
	Remove-Item -Recurse -Force $BackupDir -ErrorAction SilentlyContinue
}

# Remove OutRoot (final output tree) to match Script #1 "apply cleanup"
# WARNING: this deletes the generated outputs after apply.
Remove-Item -Recurse -Force $OutRoot -ErrorAction SilentlyContinue

Write-Host "Cleanup complete."