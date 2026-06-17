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
[Parameter(Mandatory=$true)][string]$RootDir,     # 
[Parameter(Mandatory=$true)][string]$TexconvExe,  # 
[Parameter(Mandatory=$true)][string]$MagickExe,   # 

[int]$ThrottleLimit = [int][Environment]::ProcessorCount -2,
[int]$ProgressEvery = 10, # legacy (kept); progress bars are primary
[switch]$DryRun,
[switch]$NoUpscale,          # Set2 mode: keep treatments but final texture size remains 1x

# Apply results back onto RootDir after processing completes (or apply existing OutRoot if nothing to build)
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

Write-Host "SCRIPT VERSION: 2026-02-19 (data magick upscale: disk-verified stages + live progress + apply cleanup + preserve core commands)"

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

function Is-LowResFolderName([string]$name) { return ($name -match '_l(?=-)') }

function Is-HiresDataFolderName([string]$name) {
	if ($name -notlike "*-tpf-dcx") { return $false }
	if (Is-LowResFolderName $name) { return $false }
	return ($name -match '_(n|r|s|m)(?=(_|-))')
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

# --------------------------------------------------------------------------------------
# Output + temp dirs (match Script #1 scheme: rooted at parent(RootDir), prefixed with leaf(RootDir))
# --------------------------------------------------------------------------------------
$rootFull   = (Resolve-Path -LiteralPath $RootDir).Path
$rootFull   = $rootFull -replace '[\\/]+$',''
$rootLeaf   = Split-Path $rootFull -Leaf
$rootParent = Split-Path $rootFull -Parent

$OutRoot   = Join-Path $rootParent ("{0}_upscaled_2x_data_magick_bc1_bc4_dx9bc4" -f $rootLeaf)
$WorkRoot  = Join-Path $OutRoot "_work"
$LogRoot   = Join-Path $OutRoot "_logs"

# Stage work dirs (disk-verified pipeline)
$png1Root  = Join-Path $WorkRoot "stage1_png"   # DDS -> PNG
$png2Root  = Join-Path $WorkRoot "stage2_png2x" # Magick upscale output

if ([string]::IsNullOrWhiteSpace($BackupDir)) {
	$BackupDir = Join-Path $rootParent ("{0}_backup_original_dds_data" -f $rootLeaf)
}

if ($DryRun) {
	Write-Host "DRYRUN: enabled (will not execute stages)."
}

# Create dirs up-front (safe)
Ensure-Dir $OutRoot
Ensure-Dir $WorkRoot
Ensure-Dir $LogRoot
Ensure-Dir $png1Root
Ensure-Dir $png2Root
if ($Apply -and (-not $NoBackup)) { Ensure-Dir $BackupDir }

Write-Host "RootDir : $rootFull"
Write-Host "OutRoot : $OutRoot"
Write-Host "WorkRoot: $WorkRoot"
Write-Host "LogRoot : $LogRoot"
Write-Host "Throttle: $ThrottleLimit"
Write-Host "Rule: Upscale BC1* -> BC1* and BC4_UNORM -> BC4_UNORM (DX9/ATI1). Copy-through everything else."
Write-Host "DryRun : $DryRun"
Write-Host "Apply  : $Apply"
Write-Host "Keep   : $Keep"
Write-Host "ForceRebuild: $ForceRebuild"
Write-Host "Backup : " -NoNewline
if ($Apply -and (-not $NoBackup)) { Write-Host $BackupDir } else { Write-Host "disabled" }
Write-Host ""

# --------------------------------------------------------------------------------------
# Collect target DDS (hires data folders) + manifest
# --------------------------------------------------------------------------------------
$folders = @(Get-ChildItem -LiteralPath $rootFull -Directory -Recurse -Force |
Where-Object { Is-HiresDataFolderName $_.Name })

if ($folders.Count -eq 0) {
	Write-Host "No hires data folders found for _n/_r/_s/_m (excluding _l-)."
	return
}

Write-Host ("Target folders (hires data n/r/s/m): {0}" -f $folders.Count)

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
	
	$outDir = Join-Path $OutRoot $relDir
	$outDds = Join-Path $outDir $f.Name
	
	$png1Dir = Join-Path $png1Root $relDir
	$png2Dir = Join-Path $png2Root $relDir
	
	$png1 = Join-Path $png1Dir ($base + ".png")
	$png2 = Join-Path $png2Dir ($base + ".png")
	
	$safeRelFolder = ($relDir -replace '[\\/:*?"<>|]', '_')
	if ([string]::IsNullOrWhiteSpace($safeRelFolder)) { $safeRelFolder = "_root" }
	$log = Join-Path $LogRoot ("data_magick_" + $safeRelFolder + ".log")
	
	$backupPath = if ($Apply -and (-not $NoBackup)) { Join-Path $BackupDir $rel } else { $null }
	
	[void]$manifest.Add([PSCustomObject]@{
		FullName=$full; Rel=$rel; RelDir=$relDir; Base=$base
		OutDir=$outDir; OutDds=$outDds
		Png1Dir=$png1Dir; Png2Dir=$png2Dir
		Png1=$png1; Png2=$png2
		Log=$log
		BackupPath=$backupPath
		
		# Stage-populated (disk-verified)
		Png1Actual=$null; Png2Actual=$null; OutDdsActual=$null
		IsBC1=$false; IsBC4=$false; FmtOut=$null
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
# BUILD PIPELINE (disk-verified stages)
# --------------------------------------------------------------------------------------
$copiedOK = 0
$missing2 = New-Object System.Collections.ArrayList
$missing4 = New-Object System.Collections.ArrayList
$missing5 = New-Object System.Collections.ArrayList
$manifest5 = New-Object System.Collections.ArrayList

if ($needBuild) {
	
	# Stage 1: Backup originals (serial) for files we WILL build (Apply only)
	# (Apply-only mode still backs up inside Apply loop; this stage covers newly-built files.)
	if ($wantApply -and (-not $NoBackup)) {
		Write-Host "Stage 1: Backup originals (serial)..."
		$i = 0
		foreach ($m in $todo0) {
			try {
				Ensure-Dir (Split-Path $m.BackupPath -Parent)
				Copy-Item -LiteralPath $m.FullName -Destination $m.BackupPath -Force
				$i++
				if (($i % 500) -eq 0) { Write-Host "  backed up $i / $($todo0.Count)" }
				} catch {
				# backup failures should not crash the entire run; apply loop will still attempt backup per-file
			}
		}
		Write-Host ("Stage 1 done. OK={0} FAIL=0" -f $i)
	}
	
	# --------------------------------------------------------------------------------------
	# Stage 2: DDS -> PNG + detect BC1 / BC4 (texconv core call preserved)
	# --------------------------------------------------------------------------------------
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
		$isBC4 = $false
		$fmtOut = $null
		try {
			[System.IO.Directory]::CreateDirectory($_.Png1Dir) | Out-Null
			[System.IO.Directory]::CreateDirectory($_.OutDir)  | Out-Null
			[System.IO.Directory]::CreateDirectory((Split-Path $_.Log -Parent)) | Out-Null
			
			$dds = $_.FullName
			$png1 = $_.Png1
			$w1 = $_.Png1Dir
			$log = $_.Log
			
			# 1) DDS -> PNG (capture output for format detection)
			# --- CORE COMMAND (KEEP INTACT) ---
			$tcOut = & $using:TexconvExe -nologo -ignoremips -ft png -y -o $w1 $dds 2>&1 #here IGNOREMIPS for cainhurst but does it break something else?
			$tcOut | Add-Content -LiteralPath $log
			if (-not (Test-Path -LiteralPath $png1)) { throw "texconv did not produce PNG: $png1" }
			
			$isBC1 = ($tcOut -match '\bBC1_')
			$isBC4 = ($tcOut -match '\bBC4_UNORM\b')
			
			if ($isBC1) {
				$fmtOut = if ($tcOut -match '\bBC1_UNORM_SRGB\b') { "BC1_UNORM_SRGB" } else { "BC1_UNORM" }
				} elseif ($isBC4) {
				$fmtOut = "BC4_UNORM"
				} else {
				$fmtOut = $null
			}
			
			$ok = $true
			} catch {
			$err = $_.Exception.Message
			try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
			} finally {
			# IMPORTANT: always emit one object so progress can count it
			[PSCustomObject]@{
				FullName = $_.FullName
				Ok       = $ok
				Error    = $err
				IsBC1    = [bool]$isBC1
				IsBC4    = [bool]$isBC4
				FmtOut   = $fmtOut
				Done     = $true
			}
		}
	}
	
	# verify stage2 outputs and enrich manifest
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
			$m.IsBC4 = [bool]$r.IsBC4
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
	
	# --------------------------------------------------------------------------------------
	# Stage 3: Copy-through non-BC1/non-BC4 (parallel)
	# --------------------------------------------------------------------------------------
	Write-Host "Stage 3: Copy-through non-BC1/BC4 (parallel)..."
	
	$copyList = @($manifest2a | Where-Object { -not $_.IsBC1 -and -not $_.IsBC4 })
	$upList   = @($manifest2a | Where-Object { $_.IsBC1 -or $_.IsBC4 })
	
	if ($copyList.Count -eq 0) {
		Write-Host "Stage 3: Nothing to copy-through (all are BC1/BC4)."
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
	
	# --------------------------------------------------------------------------------------
	# Stage 4: Magick upscale to 2x for BC1/BC4 (parallel) (magick core calls preserved)
	# --------------------------------------------------------------------------------------
	if ($upList.Count -eq 0) {
		Write-Host "No BC1/BC4 files to upscale after Stage 3."
		$manifest4a = @()
		$missing4.Clear() | Out-Null
		} else {
		Write-Host "Stage 4: Magick upscale 2x (parallel)..."
		
		$stage4Results = Invoke-ParallelStageWithProgress `
		-Activity "Stage 4: Magick upscale" `
		-InputObject $upList `
		-ThrottleLimit $ThrottleLimit `
		-CountPath $png2Root `
		-CountFilter "*.png" `
		-ParallelScript {
			$ok = $false
			$err = $null
			try {
				[System.IO.Directory]::CreateDirectory($_.Png2Dir) | Out-Null
				
				$png1 = $_.Png1Actual
				$png2 = $_.Png2
				$log  = $_.Log
				
				if (-not $png1) { throw "Missing Png1Actual" }
				
				if ($_.IsBC1) {
					# 2) Upscale 2x (linear-ish) for data-ish textures, or keep 1x when -NoUpscale is used: keep RGB, no gamma surprises
					# --- CORE COMMAND (KEEP INTACT) ---
					if ($using:Use1xNoUpscale) {
						& $using:MagickExe $png1 -colorspace RGB -alpha on -filter Mitchell -strip $png2 2>&1 | Add-Content -LiteralPath $log
					}
					else {
						& $using:MagickExe $png1 -colorspace RGB -alpha on -filter Mitchell -resize 200% -strip $png2 2>&1 | Add-Content -LiteralPath $log
					}
					if (-not (Test-Path -LiteralPath $png2)) { throw "magick did not produce PNG: $png2" }
				}
				elseif ($_.IsBC4) {
					# BC4: treat as single-channel mask. Force grayscale pipeline and write DX9-style ATI1 header.
					# 2) Upscale as grayscale, or keep 1x when -NoUpscale is used (avoid channel mixing)
					# --- CORE COMMAND (KEEP INTACT) ---
					if ($using:Use1xNoUpscale) {
						& $using:MagickExe $png1 -alpha off -channel R -colorspace Gray -separate +channel -filter Triangle -define png:exclude-chunk=gAMA,cHRM,iCCP,sRGB -strip $png2 2>&1 | Add-Content -LiteralPath $log # -colorspace Gray messes it up but we are going to fix later
					}
					else {
						& $using:MagickExe $png1 -alpha off -channel R -colorspace Gray -separate +channel -filter Triangle -resize 200% -define png:exclude-chunk=gAMA,cHRM,iCCP,sRGB -strip $png2 2>&1 | Add-Content -LiteralPath $log # -colorspace Gray messes it up but we are going to fix later
					}
					if (-not (Test-Path -LiteralPath $png2)) { throw "magick did not produce PNG: $png2" }
				}
				else {
					throw "Stage4 called for non-BC1/BC4 (unexpected)"
				}
				
				$ok = $true
			}
			catch {
				$err = $_.Exception.Message
				try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
			}
			finally {
				# IMPORTANT: always emit one object so progress can count it
				[PSCustomObject]@{ FullName=$_.FullName; Ok=$ok; Error=$err; Done=$true }
			}
		}
		
		$manifest4 = New-Object System.Collections.ArrayList
		$missing4.Clear() | Out-Null
		
		$stage4ByFull = @{}
		foreach ($r in $stage4Results) { $stage4ByFull[$r.FullName] = $r }
		
		foreach ($m in $upList) {
			$r = $stage4ByFull[$m.FullName]
			$a2 = Find-ExpectedFile -Path $m.Png2
			if ($r -and $r.Ok -and $a2) {
				$m.Png2Actual = $a2
				[void]$manifest4.Add($m)
				} else {
				$errMsg = "Missing png2 on disk"
				if ($r -and $r.Error) { $errMsg = [string]$r.Error }
				[void]$missing4.Add([PSCustomObject]@{ File=$m.FullName; Error=$errMsg })
			}
		}
		
		Write-Host ("Stage 4 verified on disk. OK={0} MISSING={1}" -f $manifest4.Count, $missing4.Count)
		if ($missing4.Count -gt 0) { $missing4 | Select-Object -First 20 File,Error | Format-Table -AutoSize }
		
		$manifest4a = [object[]]$manifest4.ToArray()
	}
	
	# --------------------------------------------------------------------------------------
	# Stage 5: PNG -> DDS for BC1/BC4 (parallel) (texconv core calls preserved)
	# --------------------------------------------------------------------------------------
	if ($manifest4a.Count -eq 0) {
		Write-Host "Stage 5: Nothing to encode (no BC1/BC4 upscaled PNGs)."
		$manifest5 = New-Object System.Collections.ArrayList
		$missing5.Clear() | Out-Null
		} else {
		Write-Host "Stage 5: PNG -> DDS (parallel)..."
		
		$stage5Results = Invoke-ParallelStageWithProgress `
		-Activity "Stage 5: PNG -> DDS" `
		-InputObject $manifest4a `
		-ThrottleLimit $ThrottleLimit `
		-CountPath $OutRoot `
		-CountFilter "*.dds" `
		-ParallelScript {
			$ok = $false
			$err = $null
			try {
				[System.IO.Directory]::CreateDirectory($_.OutDir) | Out-Null
				
				$png2      = $_.Png2Actual
				$outFolder = $_.OutDir
				$outDds    = $_.OutDds
				$log       = $_.Log
				
				if (-not $png2) { throw "Missing Png2Actual" }
				
				if ($_.IsBC1) {
					$fmtOut = $_.FmtOut
					if ([string]::IsNullOrWhiteSpace($fmtOut)) { throw "Missing FmtOut for BC1" }
					
					# 3) Encode back to BC1
					# --- CORE COMMAND (KEEP INTACT) ---
					$tcOut2 = & $using:TexconvExe -nologo -f $fmtOut -m 1 -y -o $outFolder $png2 2>&1  # -m 1 best quality
					$tcOut2 | Add-Content -LiteralPath $log
					if (-not (Test-Path -LiteralPath $outDds)) { throw "texconv did not produce DDS: $outDds" }
				}
				elseif ($_.IsBC4) {
					$fmtOut = "BC4_UNORM"
					
					# 3) Encode back to BC4, forcing DX9 header (ATI1) for WitchyBND compatibility
					# --- CORE COMMAND (KEEP INTACT) ---
					#$tcOut2 = & $using:TexconvExe -nologo -f $fmtOut -dx9 -srgb i -m 1 -y -o $outFolder $png2 2>&1 # -m 1 best quality
					$tcOut2 = & $using:TexconvExe -nologo -f $fmtOut -dx9 --ignore-srgb -m 1 -y -o $outFolder $png2 2>&1 # -m 1 best quality --ignore-srgb
					$tcOut2 | Add-Content -LiteralPath $log
					if (-not (Test-Path -LiteralPath $outDds)) { throw "texconv did not produce DDS: $outDds" }
				}
				else {
					throw "Stage5 called for non-BC1/BC4 (unexpected)"
				}
				
				$ok = $true
			}
			catch {
				$err = $_.Exception.Message
				try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
			}
			finally {
				# IMPORTANT: always emit one object so progress can count it
				[PSCustomObject]@{ FullName=$_.FullName; Ok=$ok; Error=$err; Done=$true }
			}
		}
		
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
	$bc4ok = (@($manifest5 | Where-Object { $_.IsBC4 })).Count
	$failTotal = $missing2.Count + $missing4.Count + $missing5.Count
	
	Write-Host ""
	Write-Host "Done processing (disk-verified)."
	Write-Host ("OK (BC1/BC4) : {0}" -f $manifest5.Count)
	Write-Host ("BC1 OK       : {0}" -f $bc1ok)
	Write-Host ("BC4 OK       : {0}" -f $bc4ok)
	Write-Host ("COPY OTHER   : {0}" -f $copiedOK)
	Write-Host ("FAIL (any)   : {0}" -f $failTotal)
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
(Get-ChildItem -LiteralPath $OutRoot -Recurse -Filter *.dds -File -ErrorAction SilentlyContinue |
Where-Object { $_.FullName -notmatch '\\_work\\' -and $_.FullName -notmatch '\\_logs\\' }).Count
)

Write-Host ""
Write-Host "Applying output DDS back onto RootDir..."

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

$applied   = 0
$backuped  = 0
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
	Write-Host ("Apply FAIL={0}. Keeping folders for inspection:" -f $applyFail.Count)
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

Write-Host "Apply succeeded. Cleaning folders..."

# Always remove intermediates
Remove-Item -Recurse -Force $WorkRoot -ErrorAction SilentlyContinue

# Remove backup only if enabled
if (-not $NoBackup) {
	Remove-Item -Recurse -Force $BackupDir -ErrorAction SilentlyContinue
}

# Remove OutRoot (final output tree) to match Script #1 apply cleanup
Remove-Item -Recurse -Force $OutRoot -ErrorAction SilentlyContinue

Write-Host "Cleanup complete."
