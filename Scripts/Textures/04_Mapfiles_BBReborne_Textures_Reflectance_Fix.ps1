# BB Reborne DIY Tool
# Copyright (C) 2026 Greg Pitta
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# See the LICENSE file for details.


<# Main image-adjustment params
-Mode

Choices:

Multiply
Knee

This is the biggest decision.

Multiply

Applies a straight brightness reduction:

out = in * SpecScale

Effect:

lowers the whole reflectance map evenly
darks, mids, and highlights all go down together
simplest and most predictable mode

Use it when:

the whole texture is too reflective everywhere
you want a neutral reduction with no selective highlight shaping
Knee

Uses a curve only on the brighter part of the image, starting from HighlightStart. Below that point, the image is mostly unchanged. Above that point, the highlights are remapped with a knee curve.

Effect:

preserves darker/mid reflectance
mainly compresses bright shiny areas
usually more natural than Multiply for wet stone, polished floors, puddles, metal accents

Use it when:

highlights are too hot, but the base reflectance is okay
you want to tame shine without flattening everything
Multiply-mode parameter
-SpecScale

Only relevant in Multiply mode. Default is 1.0.

Effect:

1.0 = no change
0.8 = all reflectance becomes 80% of original
0.5 = cuts reflectance in half
1.2 = boosts reflectance, usually not what you want here

Examples:

old damp stone is slightly too glossy: -Mode Multiply -SpecScale 0.85
puddles are wildly overbright everywhere: -Mode Multiply -SpecScale 0.5
subtle tuning only: -Mode Multiply -SpecScale 0.95

Image feel:

lower values make the whole map duller
because it is global, it can also kill desirable small bright accents
Knee-mode parameters
-Knee

Default 0.85. Used in the formula:

out = 1 - (1 - in)^K
and in the actual highlight-only remap branch above HighlightStart.

Practical effect in this script:

lower Knee = stronger highlight suppression
higher Knee = milder change, closer to original

Examples:

-Knee 0.95
very gentle highlight control
-Knee 0.85
moderate compression
-Knee 0.70
stronger reduction of bright shine
-Knee 0.50
aggressive, can noticeably flatten hot highlights

Image examples:

polished wet bricks:
0.95 keeps sparkle
0.75 calms hot spots
puddles:
0.85 may still be strong
0.65 can push them down much more
-PostScale

Optional final multiplier after the knee/highlight remap. Default 1.0.

Effect:

1.0 = leave curved result unchanged
< 1.0 = darken the post-knee highlights more
> 1.0 = brighten the curved highlight result

This mostly acts like an extra intensity knob after the curve.

Examples:

-Knee 0.85 -PostScale 0.9
compress highlights, then lower them a bit more
-Knee 0.85 -PostScale 1.0
normal behavior
-Knee 0.85 -PostScale 1.1
unusual here, but can re-open highlights slightly

Use it when:

the curve shape is good but final highlight energy is still too high
-HighlightStart

Default 0.65. Only relevant in Knee mode.

This decides where highlight compression begins.

Effect:

lower value = more of the image gets treated as “highlight”
higher value = only the brightest peaks get affected

Examples:

0.50
starts affecting upper mids too
0.65
balanced default
0.80
only very bright peaks are touched

Image examples:

worn marble floor:
0.80 preserves most reflectance, only clamps hot glints
0.55 makes broad shiny areas much calmer
damp pavement:
0.60 helps if shine spreads over a lot of the surface
0.75 helps only if tiny hotspots are the issue

A good way to think of it:

lower HighlightStart = broader shine control
higher HighlightStart = surgical shine control
-MaxSpec

Optional hard ceiling on final reflectance. Default 0.0, which disables it. If set between 0 and 1, final values are clamped to that maximum.

Effect:

acts as a hard stop for the brightest output
useful when some pixels still spike too high even after the curve

Examples:

-MaxSpec 0.90
nothing can end brighter than 0.90
-MaxSpec 0.75
much stricter cap
-MaxSpec 0.0
disabled

Image examples:

a few puddle highlights are still blown out after Knee → add -MaxSpec 0.80
bright lacquered wood still flashes too much → -MaxSpec 0.85

This is a safety limiter, not a shaping control.

Auto-adaptive Knee params
-AutoKnee

Turns on dynamic Knee selection based on image statistics. The script measures:

standard_deviation
mean

Then it maps sigma to a Knee value between KneeMin and KneeMax. This means each texture can get a different effective knee.

Effect:

flatter images and more varied images can receive different treatment automatically
useful when batch-processing lots of textures with different reflectance behavior

Use it when:

you do not want one single Knee value for all textures
some maps are flat puddles and others are detailed stone/brick
-KneeMin and -KneeMax

Range of possible Knee values used by AutoKnee. Defaults:

KneeMin = 0.85
KneeMax = 1.0

Effect:

KneeMin = strongest allowed suppression
KneeMax = weakest allowed suppression

Examples:

conservative adaptive behavior:
-AutoKnee -KneeMin 0.9 -KneeMax 1.0
stronger adaptive behavior:
-AutoKnee -KneeMin 0.65 -KneeMax 0.95

Image feel:

narrower range = more consistent batch output
wider/lower range = more aggressive adaptation across files
-SigmaLo and -SigmaHi

These define the standard-deviation window used by AutoKnee. Defaults:

SigmaLo = 0.015
SigmaHi = 0.04

Effect:

textures with sigma near SigmaLo map toward one end of the Knee range
textures with sigma near SigmaHi map toward the other
in-between values interpolate smoothly

Practical meaning:

lower sigma = flatter / more uniform reflectance map
higher sigma = more varied / textured reflectance map

Examples:

-SigmaLo 0.01 -SigmaHi 0.03
AutoKnee reacts more strongly to small sigma differences
-SigmaLo 0.02 -SigmaHi 0.08
broader tolerance; adaptive behavior changes more gradually

Use these when AutoKnee seems too eager or not eager enough.

Flat-bright special branch params

This script has an extra path for textures that are both:

bright overall
very flat / low-variance

That is especially relevant for puddles, broad wet sheets, flat reflective ground patches.

-FlatBrightMeanMin

Default 0.42. Minimum mean brightness needed to trigger the flat-bright branch.

Effect:

lower value = more textures qualify as “bright”
higher value = only obviously bright textures qualify

Examples:

0.30 = many mid-bright flat textures may trigger
0.42 = balanced default
0.55 = only quite bright flat maps trigger
-FlatBrightSigmaMax

Default 0.01. Maximum sigma allowed to count as flat.

Effect:

lower value = only very uniform textures trigger
higher value = slightly more textured maps can still trigger

Examples:

0.005 = almost perfectly flat only
0.01 = default strict flatness
0.02 = more permissive
-FlatBrightScale

Default 0.25. When the flat-bright branch triggers, the script ignores the knee curve and does a whole-image multiply by this value instead.

Effect:

directly darkens bright flat reflectance maps
lower value = stronger suppression

Examples:

0.50 = moderate reduction
0.25 = strong reduction
0.15 = very aggressive puddle suppression

Image examples:

giant flat puddle reflecting like a mirror:
0.25 can strongly calm it down
wet marble slab with little variation:
0.4 may be enough
if flat bright surfaces are still too hot:
reduce to 0.2 #>


param(
  [Parameter(Mandatory=$true)][string]$RootDir,
  [Parameter(Mandatory=$true)][string]$TexconvExe,
  [Parameter(Mandatory=$true)][string]$MagickExe,

  # Curve for reducing reflectance intensity (_r)
  [ValidateSet("Multiply","Knee")]
  [string]$Mode = "Knee",

  # Multiply mode: out = in * Scale
  [double]$SpecScale = 1.0,

  # Knee mode: out = 1 - (1 - in)^K
  [double]$Knee = 0.85,

  # Optional final multiply after Knee/highlight remap
  [double]$PostScale = 1.0,

  # Dynamic knee based on uniformity (stddev)
  [switch]$AutoKnee,
  [double]$KneeMin = 0.85,
  [double]$KneeMax = 1.0,
  [double]$SigmaLo = 0.015,
  [double]$SigmaHi = 0.04,
  
  [double]$FlatBrightMeanMin = 0.42,
  [double]$FlatBrightSigmaMax = 0.01,
  [double]$FlatBrightScale = 0.25,


  # Highlight-only remap controls (applies in Knee mode)
  [double]$HighlightStart = 0.65,

  # Optional hard ceiling on final reflectance (0 disables). Example: 0.90
  [double]$MaxSpec = 0.0,

  [int]$ThrottleLimit = [int][Environment]::ProcessorCount - 2,
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

Write-Host "SCRIPT VERSION: 2026-03-07-main-sha (reflectance _r: BC1_UNORM_SRGB; disk-verified stages + short SHA temp paths + preserve core commands)"

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

function Is-ReflectanceFolderName([string]$name) {
  if ($name -notlike "*-tpf-dcx") { return $false }
  if (Is-LowResFolderName $name)  { return $false }
  return ($name -match '_(r)(?=(_|-))')
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

# --------------------------------------------------------------------------------------
# Output + temp dirs (match reference scheme: rooted at parent(RootDir), prefixed with leaf(RootDir))
# --------------------------------------------------------------------------------------
$rootFull   = (Resolve-Path -LiteralPath $RootDir).Path
$rootFull   = $rootFull -replace '[\\/]+$',''
$rootLeaf   = Split-Path $rootFull -Leaf
$rootParent = Split-Path $rootFull -Parent

$OutRoot   = Join-Path $rootParent ("{0}_reflectance_fix_r" -f $rootLeaf)
$WorkRoot  = Join-Path $OutRoot "_work"
$LogRoot   = Join-Path $OutRoot "_logs"
$EncodeTmp = Join-Path $OutRoot "_encode_tmp"

# Staged work dirs (disk-verified pipeline)
$pngInRoot   = Join-Path $WorkRoot "stage1_png_in"     # DDS -> PNG
$pngAdjRoot  = Join-Path $WorkRoot "stage2_png_adj"    # curve output

if ([string]::IsNullOrWhiteSpace($BackupDir)) {
  $BackupDir = Join-Path $rootParent ("{0}_backup_original_dds_reflectance_fix" -f $rootLeaf)
}

Ensure-Dir $OutRoot
Ensure-Dir $WorkRoot
Ensure-Dir $LogRoot
Ensure-Dir $EncodeTmp
Ensure-Dir $pngInRoot
Ensure-Dir $pngAdjRoot
if ($Apply -and (-not $NoBackup)) { Ensure-Dir $BackupDir }

Write-Host "RootDir   : $rootFull"
Write-Host "OutRoot   : $OutRoot"
Write-Host "WorkRoot  : $WorkRoot"
Write-Host "LogRoot   : $LogRoot"
Write-Host "EncodeTmp : $EncodeTmp"
Write-Host "Mode      : $Mode (Scale=$SpecScale Knee=$Knee PostScale=$PostScale)"
Write-Host "AutoKnee  : $AutoKnee (KneeMin=$KneeMin KneeMax=$KneeMax SigmaLo=$SigmaLo SigmaHi=$SigmaHi) [INVERTED]"
Write-Host "Highlight : H=$HighlightStart  MaxSpec=$MaxSpec"
Write-Host "Throttle  : $ThrottleLimit"
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
  Where-Object { Is-ReflectanceFolderName $_.Name })

if ($folders.Count -eq 0) {
  Write-Host "No hires reflectance (_r) folders found (excluding _l-)."
  return
}
Write-Host ("Target folders (_r): {0}" -f $folders.Count)

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

  $pngInDir  = Join-Path $pngInRoot $dirKey
  $pngAdjDir = Join-Path $pngAdjRoot $dirKey

  $png1   = Join-Path $pngInDir  ($base + ".png")
  $pngAdj = Join-Path $pngAdjDir ($base + "_adj.png")

  $log = Join-Path $LogRoot ("reflfix_" + $fileKey + ".log")

  $encTmp = Join-Path $EncodeTmp ("enc_" + $fileKey)

  $backupPath = if ($Apply -and (-not $NoBackup)) { Join-Path $BackupDir $rel } else { $null }

  [void]$manifest.Add([PSCustomObject]@{
    FullName=$full; Rel=$rel; RelDir=$relDir; WorkKey=$dirKey; FileKey=$fileKey; Base=$base
    OutDir=$outDir; OutDds=$outDds
    PngInDir=$pngInDir; PngAdjDir=$pngAdjDir
    Png1=$png1; PngAdj=$pngAdj
    Log=$log
    EncTmpDir=$encTmp
    BackupPath=$backupPath

    # stage-populated
    Png1Actual=$null; PngAdjActual=$null; OutDdsActual=$null
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

$missing2 = New-Object System.Collections.ArrayList
$missing3 = New-Object System.Collections.ArrayList

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
  # Stage 2: DDS -> PNG (parallel)  [BC1_UNORM_SRGB source]
  # --------------------------------------------------------------------------------------
  Write-Host "Stage 2: DDS -> PNG (parallel)..."
  $stage2Results = Invoke-ParallelStageWithProgress `
    -Activity "Stage 2: DDS -> PNG" `
    -InputObject $todo0 `
    -ThrottleLimit $ThrottleLimit `
    -CountPath $pngInRoot `
    -CountFilter "*.png" `
    -ParallelScript {
      $ok=$false; $err=$null
      try {
        [System.IO.Directory]::CreateDirectory($_.PngInDir) | Out-Null
        [System.IO.Directory]::CreateDirectory($_.OutDir)   | Out-Null
        [System.IO.Directory]::CreateDirectory((Split-Path $_.Log -Parent)) | Out-Null

        $dds  = $_.FullName
        $png1 = $_.Png1
        $wDir = $_.PngInDir
        $log  = $_.Log

        # --- CORE COMMAND (KEEP INTACT) ---
        # DDS input: --ignore-srgb does not apply; decode as-is.
        $tcOut = & $using:TexconvExe -nologo -ignoremips -ft png -y -o $wDir $dds 2>&1 #here IGNOREMIPS for cainhurst but does it break something else?
        $tcOut | Add-Content -LiteralPath $log
        if ($LASTEXITCODE -ne 0) { throw "texconv decode failed (exit=$LASTEXITCODE)" }
        if (-not (Test-Path -LiteralPath $png1)) { throw "texconv did not produce PNG: $png1" }

        # sanity check (optional): expect SRGB source
        if (-not ($tcOut -match '\bBC1_UNORM_SRGB\b')) {
          Add-Content -LiteralPath $log -Value "[WARN] Input DDS did not report BC1_UNORM_SRGB (expected for _r)."
        }

        $ok = $true
      } catch {
        $err = $_.Exception.Message
        try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
      } finally {
        [PSCustomObject]@{ FullName=$_.FullName; Ok=$ok; Error=$err; Done=$true }
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
  # Stage 3: Apply curve to PNG (parallel)
  #   IMPORTANT: For BC1_UNORM_SRGB reflectance maps, operate in sRGB/gamma domain.
  #   We keep PNG chunks stripped so texconv won't reinterpret metadata unexpectedly.
  # --------------------------------------------------------------------------------------
	Write-Host "Stage 3: Apply curve (parallel)..."
	$stage3Results = Invoke-ParallelStageWithProgress `
	  -Activity "Stage 3: Curve" `
	  -InputObject $manifest2a `
	  -ThrottleLimit $ThrottleLimit `
	  -CountPath $pngAdjRoot `
	  -CountFilter "*.png" `
	  -ParallelScript {
		$ok=$false; $err=$null
		try {
		  [System.IO.Directory]::CreateDirectory($_.PngAdjDir) | Out-Null

		  $inPng  = $_.Png1Actual
		  $outPng = $_.PngAdj
		  $log    = $_.Log

		  if (-not $inPng) { throw "Missing Png1Actual" }

		  $Mode      = [string]$using:Mode
		  $SpecScale = [double]$using:SpecScale
		  $Knee      = [double]$using:Knee
		  $PostScale = [double]$using:PostScale
		  $AutoKnee  = [bool]$using:AutoKnee
		  $KneeMin   = [double]$using:KneeMin
		  $KneeMax   = [double]$using:KneeMax
		  $SigmaLo   = [double]$using:SigmaLo
		  $SigmaHi   = [double]$using:SigmaHi

		  $H = [double]$using:HighlightStart
		  $MaxSpec = [double]$using:MaxSpec

		  $FlatBrightMeanMin  = [double]$using:FlatBrightMeanMin
		  $FlatBrightSigmaMax = [double]$using:FlatBrightSigmaMax
		  $FlatBrightScale    = [double]$using:FlatBrightScale

		  if ($Mode -eq "Multiply") {
			& $using:MagickExe $inPng `
			  -alpha off `
			  -colorspace SRGB `
			  -evaluate Multiply $SpecScale -clamp `
			  -define png:exclude-chunk=gAMA,cHRM,iCCP,sRGB -strip `
			  $outPng 2>&1 | Add-Content -LiteralPath $log
		  } else {
			$k = $Knee
			$sigma = 0.0
			$mean  = 0.0

			if ($AutoKnee) {
			  $sigmaStr = & $using:MagickExe $inPng -format "%[fx:standard_deviation]" info: 2>$null
			  if ($sigmaStr -match '([0-9.eE+-]+)') { $sigma = [double]$Matches[1] }

			  $meanStr = & $using:MagickExe $inPng -format "%[fx:mean]" info: 2>$null
			  if ($meanStr -match '([0-9.eE+-]+)') { $mean = [double]$Matches[1] }

			  $den = [Math]::Max(1e-9, ($SigmaHi - $SigmaLo))
			  $t = ($sigma - $SigmaLo) / $den
			  if ($t -lt 0) { $t = 0 } elseif ($t -gt 1) { $t = 1 }
			  $k = ($KneeMin + $t * ($KneeMax - $KneeMin))

			  Add-Content -LiteralPath $log -Value ("[AutoKnee] mean={0} sigma={1} -> K={2}" -f `
				$mean.ToString("0.######"), $sigma.ToString("0.######"), $k.ToString("0.######"))
			}

			# ------------------------------------------------------------------
			# Flat-bright branch:
			# If texture is bright overall AND very flat, apply whole-image multiply
			# This is meant to catch puddles / flat reflectance sheets.
			# ------------------------------------------------------------------
			if ($AutoKnee -and $mean -ge $FlatBrightMeanMin -and $sigma -le $FlatBrightSigmaMax) {
			  Add-Content -LiteralPath $log -Value ("[FlatBright] mean={0} sigma={1} -> Multiply={2}" -f `
				$mean.ToString("0.######"), $sigma.ToString("0.######"), $FlatBrightScale.ToString("0.######"))

			  & $using:MagickExe $inPng `
				-alpha off `
				-colorspace SRGB `
				-evaluate Multiply $FlatBrightScale -clamp `
				-define png:exclude-chunk=gAMA,cHRM,iCCP,sRGB -strip `
				$outPng 2>&1 | Add-Content -LiteralPath $log
			}
			else {
			  if ($H -le 0.0 -or $H -ge 1.0) { $H = 0.65 }  # safety

			  $Hstr = $H.ToString("0.################")
			  $kstr = $k.ToString("0.################")
			  $pstr = $PostScale.ToString("0.################")

			  # Highlight-only knee in u (sRGB domain)
			  $fx = "(u<=${Hstr}) ? u : ( ${Hstr} + (1-${Hstr}) * (1 - pow(1 - ((u-${Hstr})/(1-${Hstr})), ${kstr})) * ${pstr} )"

			  if ($MaxSpec -gt 0.0 -and $MaxSpec -lt 1.0) {
				$mstr = $MaxSpec.ToString("0.################")
				$fx = "min( ${fx}, ${mstr} )"
			  }

			  & $using:MagickExe $inPng `
				-alpha off `
				-colorspace SRGB `
				-fx $fx -clamp `
				-define png:exclude-chunk=gAMA,cHRM,iCCP,sRGB -strip `
				$outPng 2>&1 | Add-Content -LiteralPath $log
			}
		  }

		  if ($LASTEXITCODE -ne 0) { throw "magick adjust failed (exit=$LASTEXITCODE)" }
		  if (-not (Test-Path -LiteralPath $outPng)) { throw "magick did not produce adjusted PNG: $outPng" }

		  $ok = $true
		} catch {
		  $err = $_.Exception.Message
		  try { Add-Content -LiteralPath $_.Log -Value ("[FAIL] " + $err) } catch {}
		} finally {
		  [PSCustomObject]@{ FullName=$_.FullName; Ok=$ok; Error=$err; Done=$true }
		}
	  }

	$s3=@{}; foreach($r in $stage3Results){ $s3[$r.FullName]=$r }

	$manifest3 = New-Object System.Collections.ArrayList
	$missing3.Clear() | Out-Null
	foreach ($m in $manifest2a) {
	  $r = $s3[$m.FullName]
	  $a = Find-ExpectedFile -Path $m.PngAdj
	  if ($r -and $r.Ok -and $a) {
		$m.PngAdjActual = $a
		[void]$manifest3.Add($m)
	  } else {
		$errMsg = "Missing adjusted PNG on disk"
		if ($r -and $r.Error) { $errMsg = [string]$r.Error }
		[void]$missing3.Add([PSCustomObject]@{ File=$m.FullName; Error=$errMsg })
	  }
	}

	Write-Host ("Stage 3 verified on disk. OK={0} MISSING={1}" -f $manifest3.Count, $missing3.Count)
	if ($missing3.Count -gt 0) { $missing3 | Select-Object -First 20 File,Error | Format-Table -AutoSize }

	$manifest3a = [object[]]$manifest3.ToArray()

  # --------------------------------------------------------------------------------------
  # Stage 4: Encode to BC1_UNORM_SRGB DX9 DXT1 (parallel) + rename (parallel)
  # --------------------------------------------------------------------------------------
  Write-Host "Stage 4: Encode BC1_UNORM_SRGB (parallel) + rename (parallel)..."
  $stage4Results = Invoke-ParallelStageWithProgress `
    -Activity "Stage 4: Encode BC1 SRGB" `
    -InputObject $manifest3a `
    -ThrottleLimit $ThrottleLimit `
    -CountPath $OutRoot `
    -CountFilter "*.dds" `
    -ParallelScript {
      $ok=$false; $err=$null
      try {
        [System.IO.Directory]::CreateDirectory($_.OutDir) | Out-Null

        $inPng   = $_.PngAdjActual
        $finalDds = $_.OutDds
        $tmpDir  = $_.EncTmpDir
        $log     = $_.Log

        if (-not $inPng) { throw "Missing PngAdjActual" }

        [System.IO.Directory]::CreateDirectory($tmpDir) | Out-Null
        Get-ChildItem -LiteralPath $tmpDir -Filter *.dds -File -ErrorAction SilentlyContinue |
          Remove-Item -Force -ErrorAction SilentlyContinue

        # --- CORE COMMAND (KEEP INTACT) ---
        # PNG input: ignore any metadata gamma to keep stable behavior. Output format is explicitly SRGB.
        $tc = & $using:TexconvExe -nologo -f BC1_UNORM_SRGB -srgbi -m 1 -y -o $tmpDir $inPng 2>&1 # with -srgbi the image is kept as out from magick without gets bright
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

  $s4=@{}; foreach($r in $stage4Results){ $s4[$r.FullName]=$r }

  $built = 0
  $missing4 = New-Object System.Collections.ArrayList

  foreach ($m in $manifest3a) {
    $r = $s4[$m.FullName]
    $a = Find-ExpectedFile -Path $m.OutDds
    if ($r -and $r.Ok -and $a) {
      $m.OutDdsActual = $a
      $built++
    } else {
      $errMsg = "Missing DDS on disk"
      if ($r -and $r.Error) { $errMsg = [string]$r.Error }
      [void]$missing4.Add([PSCustomObject]@{ File=$m.FullName; Error=$errMsg })
    }
  }

  Write-Host ("Stage 4 verified on disk. OK={0} MISSING={1}" -f $built, $missing4.Count)
  if ($missing4.Count -gt 0) { $missing4 | Select-Object -First 20 File,Error | Format-Table -AutoSize }

  $failAny = ($missing2.Count + $missing3.Count + $missing4.Count)
  Write-Host ""
  Write-Host "Done processing (disk-verified)."
  Write-Host ("OK (built) : {0}" -f $built)
  Write-Host ("FAIL (any) : {0}" -f $failAny)
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

Remove-Item -Recurse -Force $WorkRoot  -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $EncodeTmp -ErrorAction SilentlyContinue

if (-not $NoBackup) {
  Remove-Item -Recurse -Force $BackupDir -ErrorAction SilentlyContinue
}

Remove-Item -Recurse -Force $OutRoot -ErrorAction SilentlyContinue

Write-Host "Cleanup complete."