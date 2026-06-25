# BB Reborne DIY Tool
# Copyright (C) 2026 Greg Pitta
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# See the LICENSE file for details.


<# -BlurSigma

Controls how much the generated grayscale height is blurred before being written into blue. The script passes it into ImageMagick as -blur 0x<BlurSigma>.

Effect on the image:

Lower BlurSigma preserves more small detail, noise, and sharp transitions.
Higher BlurSigma smooths the height map and reduces noisy or jagged blue detail.

Examples:

-BlurSigma 0.5
Blue will follow fine pores, cracks, grain, and compression noise more closely. Good for sharp stone or carved detail, but can create harsh or noisy height.
-BlurSigma 2.0
Balanced smoothing. Keeps medium forms while calming noise.
-BlurSigma 4.0
Much smoother. Good if the generated height is too crunchy or if the normal map is messy.
-BlurSigma 8.0
Very soft. Broad shapes remain, but lots of fine relief disappears.


-WhiteMinThreshold

This decides whether a file gets replaced at all, unless -ForceReplace overrides it. The script inspects the existing blue channel and replaces only when:

min(Blue) >= WhiteMinThreshold

That means the current blue channel is almost entirely white or very bright.

Effect on behavior:

Higher threshold = fewer files get replaced
Lower threshold = more files get replaced

Examples:

-WhiteMinThreshold 0.99
Only nearly pure-white blue channels get replaced. Very conservative.
-WhiteMinThreshold 0.95
Default. Replaces files whose blue is basically “full white placeholder”.
-WhiteMinThreshold 0.80
More aggressive. Files with already somewhat bright blue may also get replaced.

Image example:

existing normal map has blue around 1.0 everywhere → will likely be replaced
existing normal map has blue ranging 0.65–1.0 → may not be replaced with default 0.95


-BlueMin and -BlueMax

These define the output range the new blue channel is compressed into:

generated grayscale 0 maps toward BlueMin
generated grayscale 1 maps toward BlueMax

Effect on the image:

Wider range gives stronger blue contrast, more pronounced height variation.
Narrower range gives gentler, flatter blue variation.

Examples:

Conservative range

-BlueMin 0.35 -BlueMax 0.65

Very restrained
Safer if strong height causes artifacts
Blue never gets very dark or very bright
Default range

-BlueMin 0.20 -BlueMax 0.80

Middle ground
Enough contrast to carry shape without going too extreme
Strong range

-BlueMin 0.05 -BlueMax 0.95

Very wide
More dramatic height separation
Can exaggerate forms and potentially create harsher results

Visual intuition:

On worn cobblestone:
0.35–0.65 = shallow, subtle relief
0.20–0.80 = moderate relief
0.05–0.95 = stronger peaks/valleys, more pronounced

Important: the script validates that BlueMin < BlueMax.


-CompressStart and -CompressFull

These decide when the script starts applying the BlueMin/BlueMax compression based on the contrast of the generated grayscale height.

The script measures grayscale range:

range = maxH - minH

Then computes an amount:

0.0 when range <= CompressStart
1.0 when range >= CompressFull
smoothly interpolated between them otherwise

So:

If generated height contrast is low, the script leaves it closer to the original auto-leveled grayscale.
If generated height contrast is high, the script compresses more strongly into your BlueMin..BlueMax band.

Effect on the image:

Lower CompressStart / CompressFull = compression kicks in more often
Higher values = compression only happens for stronger-contrast maps

Examples:

Default

-CompressStart 0.55 -CompressFull 0.90

compression starts only when the generated height already has decent contrast
full compression only for very contrasty cases

Earlier compression

-CompressStart 0.20 -CompressFull 0.50

most images will get compressed
results become more standardized and controlled

Later compression

-CompressStart 0.75 -CompressFull 0.98

only very high-contrast generated maps get compressed
more images keep their natural auto-leveled range

Image example:

soft plaster wall with weak RG variation
with high CompressStart, little compression happens
cracked stone with big RG variation
compression engages strongly and keeps blue inside your target band

1. Safe test preset

Only replace obvious placeholder-blue maps, keep output for inspection:
-BlurSigma 4.0 -WhiteMinThreshold 0.95 -BlueMin 0.20 -BlueMax 0.80 -CompressStart 0.55 -CompressFull 0.90 -Apply -Keep
2. Sharper, more detailed preset
-BlurSigma 1.0 -BlueMin 0.15 -BlueMax 0.85 -CompressStart 0.45 -CompressFull 0.80 -ForceReplace

3. Softer, safer preset
-BlurSigma 6.0 -BlueMin 0.30 -BlueMax 0.70 -CompressStart 0.65 -CompressFull 0.95
 #>
param(
[Parameter(Mandatory=$true)][string]$RootDir,
[Parameter(Mandatory=$true)][string]$TexconvExe,
[Parameter(Mandatory=$true)][string]$MagickExe,

[int]$ThrottleLimit = [int][Environment]::ProcessorCount -2,
[int]$ProgressEvery = 25,

# Height gen params
[double]$BlurSigma = 4.0,

# Only replace existing height if Blue channel is "full white"
# We test: min(Blue) >= WhiteMinThreshold (normalized 0..1)
[double]$WhiteMinThreshold = 0.95,

# Compress rebuilt blue range after auto-level, smoothly:
# 0 -> BlueMin, 1 -> BlueMax
[ValidateRange(0.0,1.0)][double]$BlueMin = 0.20,
[ValidateRange(0.0,1.0)][double]$BlueMax = 0.80,

# Start compressing only when generated blue has enough contrast
[ValidateRange(0.0,1.0)][double]$CompressStart = 0.55,
[ValidateRange(0.0,1.0)][double]$CompressFull  = 0.90,

# If set, replace Blue regardless
[switch]$ForceReplace,

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

Write-Host "SCRIPT VERSION: 2026-02-19 (heightfix: disk-verified stages + live progress + apply cleanup + preserve core commands)"

if ($PSVersionTable.PSVersion.Major -lt 7) { throw "Run with PowerShell 7+ (pwsh)." }
if (-not (Test-Path -LiteralPath $RootDir))    { throw "RootDir not found: $RootDir" }
if (-not (Test-Path -LiteralPath $TexconvExe)) { throw "texconv.exe not found: $TexconvExe" }
if (-not (Test-Path -LiteralPath $MagickExe))  { throw "magick.exe not found: $MagickExe" }

if ($BlueMin -ge $BlueMax) { throw "BlueMin must be lower than BlueMax." }
if ($CompressStart -ge $CompressFull) { throw "CompressStart must be lower than CompressFull." }

Write-Host "BlueMin: $BlueMin"
Write-Host "BlueMax: $BlueMax"

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

function Is-HiresNormalFolderName([string]$name) {
	if ($name -notlike "*-tpf-dcx") { return $false }
	if (Is-LowResFolderName $name)  { return $false }
	return ($name -match '_(n)(?=(_|-))')
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
# Output + temp dirs (match reference scheme: rooted at parent(RootDir), prefixed with leaf(RootDir))
# --------------------------------------------------------------------------------------
$rootFull   = (Resolve-Path -LiteralPath $RootDir).Path
$rootFull   = $rootFull -replace '[\\/]+$',''
$rootLeaf   = Split-Path $rootFull -Leaf
$rootParent = Split-Path $rootFull -Parent

$OutRoot   = Join-Path $rootParent ("{0}_heightfix_blue_from_rg" -f $rootLeaf)
$WorkRoot  = Join-Path $OutRoot "_work"
$LogRoot   = Join-Path $OutRoot "_logs"

# Stage work dirs (disk-verified pipeline)
$pngInRoot  = Join-Path $WorkRoot "stage1_png_in"   # DDS -> PNG
$pngOutRoot = Join-Path $WorkRoot "stage2_png_out"  # Magick output

if ([string]::IsNullOrWhiteSpace($BackupDir)) {
	$BackupDir = Join-Path $rootParent ("{0}_backup_original_dds_heightfix" -f $rootLeaf)
}

Ensure-Dir $OutRoot
Ensure-Dir $WorkRoot
Ensure-Dir $LogRoot
Ensure-Dir $pngInRoot
Ensure-Dir $pngOutRoot
if ($Apply -and (-not $NoBackup)) { Ensure-Dir $BackupDir }

Write-Host "RootDir : $rootFull"
Write-Host "OutRoot : $OutRoot"
Write-Host "WorkRoot: $WorkRoot"
Write-Host "LogRoot : $LogRoot"
Write-Host "Throttle: $ThrottleLimit"
Write-Host "ProgressEvery: $ProgressEvery"
Write-Host "BlurSigma: $BlurSigma"
Write-Host "WhiteMinThreshold: $WhiteMinThreshold"
Write-Host "ForceReplace: $ForceReplace"
Write-Host "DryRun : $DryRun"
Write-Host "Apply  : $Apply"
Write-Host "Keep   : $Keep"
Write-Host "ForceRebuild: $ForceRebuild"
Write-Host "Backup : " -NoNewline
if ($Apply -and (-not $NoBackup)) { Write-Host $BackupDir } else { Write-Host "disabled" }
Write-Host ""

if ($DryRun) {
	Write-Host "DRYRUN: enabled (will not execute stages)."
	return
}

# --------------------------------------------------------------------------------------
# Collect target DDS (hires normal folders) + manifest
# --------------------------------------------------------------------------------------
$folders = @(Get-ChildItem -LiteralPath $rootFull -Directory -Recurse -Force |
Where-Object { Is-HiresNormalFolderName $_.Name })

if ($folders.Count -eq 0) {
	Write-Host "No hires normal (_n) '-tpf-dcx' folders found (excluding _l-)."
	return
}

Write-Host ("Target folders (hires _n): {0}" -f $folders.Count)

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
	
	$pngInDir  = Join-Path $pngInRoot  $relDir
	$pngOutDir = Join-Path $pngOutRoot $relDir
	
	$png1 = Join-Path $pngInDir  ($base + ".png")
	$png2 = Join-Path $pngOutDir ($base + ".png")
	
	$safeRelFolder = ($relDir -replace '[\\/:*?"<>|]', '_')
	if ([string]::IsNullOrWhiteSpace($safeRelFolder)) { $safeRelFolder = "_root" }
	$log = Join-Path $LogRoot ("heightfix_" + $safeRelFolder + ".log")
	
	$backupPath = if ($Apply -and (-not $NoBackup)) { Join-Path $BackupDir $rel } else { $null }
	
	[void]$manifest.Add([PSCustomObject]@{
		FullName=$full; Rel=$rel; RelDir=$relDir; Base=$base
		OutDir=$outDir; OutDds=$outDds
		PngInDir=$pngInDir; PngOutDir=$pngOutDir
		Png1=$png1; Png2=$png2
		Log=$log
		BackupPath=$backupPath
		
		# Stage-populated (disk-verified)
		Png1Actual=$null; Png2Actual=$null; OutDdsActual=$null
		FmtOut=$null
		ShouldReplace=$false
		SkipBecauseExists=$false
		KeptCopyThrough=$false
	})
}

Write-Host "Manifest: $($manifest.Count) files."
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
$missing2 = New-Object System.Collections.ArrayList
$missing3 = New-Object System.Collections.ArrayList
$missing4 = New-Object System.Collections.ArrayList
$manifest4 = New-Object System.Collections.ArrayList

if ($needBuild) {
	
	# Stage 1: Backup originals (serial) for files we WILL build (Apply only)
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
				# keep going; apply loop will still try
			}
		}
		Write-Host ("Stage 1 done. OK={0} FAIL=0" -f $i)
	}
	
	# --------------------------------------------------------------------------------------
	# Stage 2: DDS -> PNG + detect original format token (texconv core call preserved)
	# --------------------------------------------------------------------------------------
	Write-Host "Stage 2: DDS -> PNG (parallel) + detect format token..."
	$stage2Results = Invoke-ParallelStageWithProgress `
    -Activity "Stage 2: DDS -> PNG" `
    -InputObject $todo0 `
    -ThrottleLimit $ThrottleLimit `
    -CountPath $pngInRoot `
    -CountFilter "*.png" `
    -ParallelScript {
		$ok = $false
		$err = $null
		$fmtOut = $null
		try {
			[System.IO.Directory]::CreateDirectory($_.PngInDir) | Out-Null
			[System.IO.Directory]::CreateDirectory($_.OutDir)   | Out-Null
			[System.IO.Directory]::CreateDirectory((Split-Path $_.Log -Parent)) | Out-Null
			
			$dds  = $_.FullName
			$png1 = $_.Png1
			$w1   = $_.PngInDir
			$log  = $_.Log
			
			# 1) DDS -> PNG
			# --- CORE COMMAND (KEEP INTACT) ---
			$tcOut = & $using:TexconvExe -nologo -ignoremips -ft png -y -o $w1 $dds 2>&1 #here IGNOREMIPS for cainhurst but does it break something else?
			$tcOut | Add-Content -LiteralPath $log
			if ($LASTEXITCODE -ne 0) { throw "texconv decode failed (exit=$LASTEXITCODE)" }
			if (-not (Test-Path -LiteralPath $png1)) { throw "texconv did not produce PNG: $png1" }
			
			# Extract original BC format token (best-effort)
			foreach ($line in $tcOut) {
				if ($line -match '\b(BC[0-9A-Z_]+)\b') { $fmtOut = $Matches[1]; break }
			}
			if ([string]::IsNullOrWhiteSpace($fmtOut)) { $fmtOut = "BC1_UNORM" }
			
			$ok = $true
			} catch {
			$err = $_.Exception.Message
			try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
			} finally {
			# IMPORTANT: always emit one object so progress can count it
			[PSCustomObject]@{ FullName=$_.FullName; Ok=$ok; Error=$err; FmtOut=$fmtOut; Done=$true }
		}
	}
	
	# verify stage2 outputs and enrich manifest
	$byFull = @{}
	foreach ($m in $todo0) { $byFull[$m.FullName] = $m }
	
	$manifest2 = New-Object System.Collections.ArrayList
	$missing2.Clear() | Out-Null
	
	$stage2ByFull = @{}
	foreach ($r in $stage2Results) { $stage2ByFull[$r.FullName] = $r }
	
	foreach ($m in $todo0) {
		$r = $stage2ByFull[$m.FullName]
		$actual = Find-ExpectedFile -Path $m.Png1
		if ($r -and $r.Ok -and $actual) {
			$m.Png1Actual = $actual
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
	# Stage 3: Decide replace vs keep (parallel) using magick stats (core call preserved)
	# --------------------------------------------------------------------------------------
	Write-Host "Stage 3: Decide replace vs keep (parallel)..."
	$stage3Results = Invoke-ParallelStageWithProgress `
    -Activity "Stage 3: Decide replace/keep" `
    -InputObject $manifest2a `
    -ThrottleLimit $ThrottleLimit `
    -ParallelScript {
		$ok = $false
		$err = $null
		$shouldReplace = $false
		$minB = $null
		$maxB = $null
		try {
			$png1 = $_.Png1Actual
			if (-not $png1) { throw "Missing Png1Actual" }
			
			# 2) Decide if we should replace height (blue)
			# --- CORE COMMAND (KEEP INTACT) ---
			# Locale-proof: get integer min/max and quantumrange (all integers)
			$blueStats = & $using:MagickExe $png1 -alpha off -channel B -separate +channel `
			-format "%[min],%[max],%[fx:quantumrange]" info: 2>$null
			
			$minB = 0.0; $maxB = 1.0; $qrange = 65535.0
			
			if ($blueStats -match '^\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*$') {
				$minQ   = [double]$Matches[1]
				$maxQ   = [double]$Matches[2]
				$qrange = [double]$Matches[3]
				if ($qrange -le 0) { $qrange = 65535.0 }
				
				$minB = $minQ / $qrange
				$maxB = $maxQ / $qrange
				} else {
				try { Add-Content -LiteralPath $_.Log -Value ("[WARN] Could not parse blueStats: " + $blueStats) } catch {}
			}
			
			$shouldReplace = ([bool]$using:ForceReplace) -or ($minB -ge [double]$using:WhiteMinThreshold)
			
			$ok = $true
			} catch {
			$err = $_.Exception.Message
			try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
			} finally {
			[PSCustomObject]@{
				FullName       = $_.FullName
				Ok             = $ok
				Error          = $err
				ShouldReplace  = [bool]$shouldReplace
				MinB           = $minB
				MaxB           = $maxB
				Done           = $true
			}
		}
	}
	
	$stage3ByFull = @{}
	foreach ($r in $stage3Results) { $stage3ByFull[$r.FullName] = $r }
	
	$replaceList = New-Object System.Collections.ArrayList
	$keepList    = New-Object System.Collections.ArrayList
	$missing3.Clear() | Out-Null
	
	foreach ($m in $manifest2a) {
		$r = $stage3ByFull[$m.FullName]
		if ($r -and $r.Ok) {
			$m.ShouldReplace = [bool]$r.ShouldReplace
			if ($m.ShouldReplace) { [void]$replaceList.Add($m) } else { [void]$keepList.Add($m) }
			} else {
			$errMsg = "Decision failed"
			if ($r -and $r.Error) { $errMsg = [string]$r.Error }
			[void]$missing3.Add([PSCustomObject]@{ File=$m.FullName; Error=$errMsg })
		}
	}
	
	Write-Host ("Stage 3 decided. REPLACE={0} KEEP={1} FAIL={2}" -f $replaceList.Count, $keepList.Count, $missing3.Count)
	if ($missing3.Count -gt 0) { $missing3 | Select-Object -First 20 File,Error | Format-Table -AutoSize }
	
	# --------------------------------------------------------------------------------------
	# Stage 4a: KEEP path = copy DDS through unchanged (parallel)
	# --------------------------------------------------------------------------------------
	if ($keepList.Count -eq 0) {
		Write-Host "Stage 4a: KEEP copy-through: nothing to copy."
		} else {
		Write-Host "Stage 4a: KEEP copy-through DDS (parallel)..."
		$null = Invoke-ParallelStageWithProgress `
		-Activity "Stage 4a: Copy-through KEEP" `
		-InputObject @($keepList.ToArray()) `
		-ThrottleLimit $ThrottleLimit `
		-CountPath $OutRoot `
		-CountFilter "*.dds" `
		-ParallelScript {
			try {
				[System.IO.Directory]::CreateDirectory($_.OutDir) | Out-Null
				Copy-Item -LiteralPath $_.FullName -Destination $_.OutDds -Force
				$_.KeptCopyThrough = $true
				} catch {
				try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $_.Exception.Message) } catch {}
			}
			[PSCustomObject]@{ FullName=$_.FullName; Done=$true }
		}
	}
	
	# --------------------------------------------------------------------------------------
	# Stage 4b: REPLACE path = Magick build blue from RG into new PNG (parallel)
	# --------------------------------------------------------------------------------------
	$replaceArr = @($replaceList.ToArray())
	$manifest4b = New-Object System.Collections.ArrayList
	
	if ($replaceArr.Count -eq 0) {
		Write-Host "Stage 4b: REPLACE compose: nothing to replace."
		} else {
		Write-Host "Stage 4b: REPLACE compose blue-from-RG (parallel)..."
		
		
		$stage4bParams = @{
			Activity      = "Stage 4b: Compose height PNG"
			InputObject   = $replaceArr
			ThrottleLimit = $ThrottleLimit
			CountPath     = $pngOutRoot
			CountFilter   = "*.png"
			ParallelScript = {
				$ok = $false
				$err = $null
				try {
					[System.IO.Directory]::CreateDirectory($_.PngOutDir) | Out-Null
					
					$png1 = $_.Png1Actual
					$png2 = $_.Png2
					$log  = $_.Log
					
					if (-not $png1) { throw "Missing Png1Actual" }
					
					$blurArg = ("0x{0}" -f [double]$using:BlurSigma)
					$tmpGray = Join-Path $_.PngOutDir ($_.Base + "._heightgray.png")
					
					$magArgs1 = @(
					$png1,
					"(",
					"+clone",
					"-alpha","off",
					"-colorspace","RGB",
					"-fx","1-hypot(2*r-1,2*g-1)",
					"-blur",$blurArg,
					"-auto-level",
					")",
					"-delete","0",
					"-define","png:exclude-chunk=gAMA,cHRM,iCCP,sRGB",
					"-strip",
					$tmpGray
					)
					
					& $using:MagickExe @magArgs1 2>&1 | Add-Content -LiteralPath $log
					if ($LASTEXITCODE -ne 0) { throw "magick temp height build failed (exit=$LASTEXITCODE)" }
					if (-not (Test-Path -LiteralPath $tmpGray)) { throw "temp grayscale was not produced: $tmpGray" }
					
					$grayStats = & $using:MagickExe $tmpGray -alpha off `
					-format "%[min],%[max],%[fx:quantumrange]" info: 2>$null
					
					$minH = 0.0; $maxH = 1.0; $qrange = 65535.0
					if ($grayStats -match '^\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*$') {
						$minQ   = [double]$Matches[1]
						$maxQ   = [double]$Matches[2]
						$qrange = [double]$Matches[3]
						if ($qrange -le 0) { $qrange = 65535.0 }
						$minH = $minQ / $qrange
						$maxH = $maxQ / $qrange
						} else {
						throw "Could not parse grayscale stats: $grayStats"
					}
					
					$range = $maxH - $minH
					
					$amount = if ($range -le [double]$using:CompressStart) {
						0.0
					}
					elseif ($range -ge [double]$using:CompressFull) {
						1.0
					}
					else {
						($range - [double]$using:CompressStart) / ([double]$using:CompressFull - [double]$using:CompressStart)
					}
					
					$blueExpr = (
					"u*(1-{0}) + ({1}+u*({2}-{1}))*{0}" -f
					$amount,
					[double]$using:BlueMin,
					[double]$using:BlueMax
					)
					
					$magArgs2 = @(
					$png1,
					"(",
					$tmpGray,
					"-alpha","off",
					"-fx",$blueExpr,
					")",
					"-compose","CopyBlue",
					"-composite",
					"-define","png:exclude-chunk=gAMA,cHRM,iCCP,sRGB",
					"-strip",
					$png2
					)
					
					& $using:MagickExe @magArgs2 2>&1 | Add-Content -LiteralPath $log
					if ($LASTEXITCODE -ne 0) { throw "magick height-compose failed (exit=$LASTEXITCODE)" }
					if (-not (Test-Path -LiteralPath $png2)) { throw "magick did not produce PNG: $png2" }
					
					Remove-Item -LiteralPath $tmpGray -Force -ErrorAction SilentlyContinue
					try { Add-Content -LiteralPath $log -Value ("[INFO] range={0} amount={1}" -f $range, $amount) } catch {}
					
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
		}
		$stage4bResults = Invoke-ParallelStageWithProgress @stage4bParams
		
		$stage4bByFull = @{}
		foreach ($r in $stage4bResults) { $stage4bByFull[$r.FullName] = $r }
		
		$missing4.Clear() | Out-Null
		foreach ($m in $replaceArr) {
			$r = $stage4bByFull[$m.FullName]
			$a2 = Find-ExpectedFile -Path $m.Png2
			if ($r -and $r.Ok -and $a2) {
				$m.Png2Actual = $a2
				[void]$manifest4b.Add($m)
				} else {
				$errMsg = "Missing composed PNG on disk"
				if ($r -and $r.Error) { $errMsg = [string]$r.Error }
				[void]$missing4.Add([PSCustomObject]@{ File=$m.FullName; Error=$errMsg })
			}
		}
		
		Write-Host ("Stage 4b verified on disk. OK={0} MISSING={1}" -f $manifest4b.Count, $missing4.Count)
		if ($missing4.Count -gt 0) { $missing4 | Select-Object -First 20 File,Error | Format-Table -AutoSize }
	}
	
	# --------------------------------------------------------------------------------------
	# Stage 5: REPLACE path encode PNG -> DDS using original format token (parallel)
	# (texconv core calls preserved, including dx9 for BC4_*)
	# --------------------------------------------------------------------------------------
	$manifest4bArr = @($manifest4b.ToArray())
	if ($manifest4bArr.Count -eq 0) {
		Write-Host "Stage 5: Nothing to encode (no composed PNGs)."
		} else {
		Write-Host "Stage 5: Encode composed PNG -> DDS (parallel)..."
		$stage5Params = @{
			Activity      = "Stage 5: PNG -> DDS"
			InputObject   = $manifest4bArr
			ThrottleLimit = $ThrottleLimit
			CountPath     = $OutRoot
			CountFilter   = "*.dds"
			ParallelScript = {
				$ok = $false
				$err = $null
				try {
					[System.IO.Directory]::CreateDirectory($_.OutDir) | Out-Null
					
					$png2      = $_.Png2Actual
					$outFolder = $_.OutDir
					$outDds    = $_.OutDds
					$log       = $_.Log
					$fmtOut    = $_.FmtOut
					
					if (-not $png2) { throw "Missing Png2Actual" }
					if ([string]::IsNullOrWhiteSpace($fmtOut)) { throw "Missing FmtOut" }
					
					$useDx9 = ($fmtOut -like "BC4_*")
					
					if ($useDx9) {
						$tcOut2 = & $using:TexconvExe -nologo -f $fmtOut -dx9 --ignore-srgb -m 1 -y -o $outFolder $png2 2>&1
						} else {
						$tcOut2 = & $using:TexconvExe -nologo -f $fmtOut --ignore-srgb -m 1 -y -o $outFolder $png2 2>&1
					}
					
					$tcOut2 | Add-Content -LiteralPath $log
					if ($LASTEXITCODE -ne 0) { throw "texconv encode failed (exit=$LASTEXITCODE) fmt=$fmtOut" }
					if (-not (Test-Path -LiteralPath $outDds)) { throw "texconv did not produce DDS: $outDds" }
					
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
		}
		$stage5Results = Invoke-ParallelStageWithProgress @stage5Params
		
		$stage5ByFull = @{}
		foreach ($r in $stage5Results) { $stage5ByFull[$r.FullName] = $r }
		
		foreach ($m in $manifest4bArr) {
			$r = $stage5ByFull[$m.FullName]
			$actual = Find-ExpectedFile -Path $m.OutDds
			if ($r -and $r.Ok -and $actual) {
				$m.OutDdsActual = $actual
				[void]$manifest4.Add($m)
				} else {
				$errMsg = "Missing DDS on disk"
				if ($r -and $r.Error) { $errMsg = [string]$r.Error }
				# reuse missing4 as "encode missing" is fine; keep separate list if you prefer
				[void]$missing4.Add([PSCustomObject]@{ File=$m.FullName; Error=$errMsg })
			}
		}
		
		Write-Host ("Stage 5 verified on disk. OK={0} MISSING={1}" -f $manifest4.Count, $missing4.Count)
		if ($missing4.Count -gt 0) { $missing4 | Select-Object -First 20 File,Error | Format-Table -AutoSize }
	}
	
	Write-Host ""
	Write-Host "Done processing (disk-verified)."
	Write-Host ("REPLACE encoded OK : {0}" -f $manifest4.Count)
	Write-Host ("KEEP copy-through  : {0}" -f $keepList.Count)
	Write-Host ("FAIL (stage2/3/4/5): {0}" -f ($missing2.Count + $missing3.Count + $missing4.Count))
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

$applyFiles = @(Get-ChildItem -LiteralPath $OutRoot -Recurse -Filter *.dds -File -ErrorAction SilentlyContinue |
Where-Object { $_.FullName -notmatch '\\_work\\' -and $_.FullName -notmatch '\\_logs\\' })

Write-Host ("Applying outputs from OutRoot (existing + new). OutRoot DDS count: {0}" -f $applyFiles.Count)

Write-Host ""
Write-Host "Applying height-fixed DDS back onto RootDir..."

$newFiles = $applyFiles

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
		if (($applied % 50) -eq 0) {
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

# Remove OutRoot to match Script #1 apply cleanup
Remove-Item -Recurse -Force $OutRoot -ErrorAction SilentlyContinue

Write-Host "Cleanup complete."