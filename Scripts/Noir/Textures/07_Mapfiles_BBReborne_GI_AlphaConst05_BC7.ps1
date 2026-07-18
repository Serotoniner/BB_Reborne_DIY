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
  [Parameter(Mandatory=$true)][string]$RootDir,
  [Parameter(Mandatory=$true)][string]$TexconvExe,
  [Parameter(Mandatory=$true)][string]$MagickExe,
  # Alpha to write into the output (0..1). 0=transparent, 1=opaque.
  [ValidateRange(0.0, 1.0)]
  [double]$Alpha = 0.5,
  [switch]$Recurse,
  [switch]$DryRun,
  [switch]$Apply,
  # Keep temp folders (workRoot + backupDir) after success / early exits
  [switch]$Keep,
  
  [int]$ThrottleLimit = [int][Environment]::ProcessorCount -2,

  [int]$TexconvTimeoutSeconds = 300,
  [int]$MagickTimeoutSeconds  = 300
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

Write-Host "SCRIPT VERSION: 2026-07-06 v2 (short hashed external-tool work paths; disk-verified chaining + live progress)"
Write-Host ("Alpha   : {0}" -f $Alpha)
Write-Host ("Keep temps : {0}" -f $Keep)

if ($PSVersionTable.PSVersion.Major -lt 7) {
  throw "This script requires PowerShell 7+. Run with: pwsh -File `"$PSCommandPath`" ..."
}

function Ensure-Dir([string]$p) { [System.IO.Directory]::CreateDirectory($p) | Out-Null }

function Get-ShortWorkKey([string]$Value) {
  $normalized = if ($null -eq $Value) { "" } else { $Value.ToLowerInvariant() }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $hash = $sha.ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 32).ToLowerInvariant())
  }
  finally {
    $sha.Dispose()
  }
}

function Cleanup-TempFolders {
  param(
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [Parameter(Mandatory=$true)][string]$BackupDir,
    [Parameter(Mandatory=$true)][bool]$Apply,
    [Parameter(Mandatory=$true)][bool]$Keep
  )

  if ($Keep) {
    Write-Host "Keep enabled: not deleting temp folders."
    Write-Host "  Work  : $WorkRoot"
    if ($Apply) { Write-Host "  Backup: $BackupDir" }
    return
  }

  Write-Host "Cleaning temp folders..."
  Remove-Item -Recurse -Force $WorkRoot  -ErrorAction SilentlyContinue
  if ($Apply) {
    Remove-Item -Recurse -Force $BackupDir -ErrorAction SilentlyContinue
  }
  Write-Host "Cleanup complete."
}

function Get-DdsInfo([string]$ddsPath) {
  $fs = [System.IO.File]::OpenRead($ddsPath)
  try {
    $br = New-Object System.IO.BinaryReader($fs)
    $magic = $br.ReadUInt32()
    if ($magic -ne 0x20534444) { throw "Not a DDS" } # 'DDS '
    [void]$br.ReadUInt32(); [void]$br.ReadUInt32()
    $height = $br.ReadUInt32()
    $width  = $br.ReadUInt32()
    [void]$br.ReadUInt32(); [void]$br.ReadUInt32()
    $mipMapCount = $br.ReadUInt32()
    if ($mipMapCount -lt 1) { $mipMapCount = 1 }
    [PSCustomObject]@{ Width=[int]$width; Height=[int]$height; Mips=[int]$mipMapCount }
  } finally { $fs.Dispose() }
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
# Temp dirs rooted at parent(RootDir), prefixed with leaf(RootDir)
# --------------------------------------------------------------------------------------
$rootFull   = (Resolve-Path -LiteralPath $RootDir).Path
$rootFull   = $rootFull -replace '[\\/]+$',''
$rootLeaf   = Split-Path $rootFull -Leaf
$rootParent = Split-Path $rootFull -Parent

$workRoot   = Join-Path $rootParent ("{0}_alpha_const_05_work" -f $rootLeaf)
$pngInRoot  = Join-Path $workRoot "stage1_png_in"
$pngOutRoot = Join-Path $workRoot "stage2_png_out"
$ddsOutRoot = Join-Path $workRoot "stage3_dds_out"
$backupDir  = Join-Path $rootParent ("{0}_backup_original_dds" -f $rootLeaf)

if (-not $DryRun) {
  Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
  Ensure-Dir $pngInRoot
  Ensure-Dir $pngOutRoot
  Ensure-Dir $ddsOutRoot

  if ($Apply) {
    Remove-Item -Recurse -Force $backupDir -ErrorAction SilentlyContinue
    Ensure-Dir $backupDir
  }
}

# --------------------------------------------------------------------------------------
# Collect DDS + manifest
# --------------------------------------------------------------------------------------
$opt = @{}; if ($Recurse) { $opt.Recurse = $true }
$files = Get-ChildItem -Path $rootFull -Filter *.dds -File @opt | Sort-Object FullName
Write-Host "Found $($files.Count) DDS files."

$manifest = [System.Collections.ArrayList]::new()
$rootPrefix = $rootFull; if (-not $rootPrefix.EndsWith('\')) { $rootPrefix += '\' }

foreach ($f in $files) {
  $full = $f.FullName
  $rel = if ($full.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { $full.Substring($rootPrefix.Length) }
         else { ($full.Replace($rootFull, '') -replace '^[\\/]+','') }
  $rel = ($rel -replace '/','\')
  $relDir = Split-Path $rel -Parent
  if ([string]::IsNullOrWhiteSpace($relDir)) { $relDir = "" }

  $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
  $info = Get-DdsInfo $full

  $workKey = Get-ShortWorkKey $rel
  $pngInDir  = Join-Path $pngInRoot  $workKey
  $pngOutDir = Join-Path $pngOutRoot $workKey
  $ddsOutDir = Join-Path $ddsOutRoot $workKey

  $pngInPath  = Join-Path $pngInDir  ($base + ".png")
  $pngOutPath = Join-Path $pngOutDir ($base + ".png")
  $ddsOutPath = Join-Path $ddsOutDir ($base + ".dds")

  $backupPath = if ($Apply) { Join-Path $backupDir $rel } else { $null }

  [void]$manifest.Add([PSCustomObject]@{
    FullName=$full; Rel=$rel; Base=$base; Width=$info.Width; Height=$info.Height; Mips=$info.Mips
    BackupPath=$backupPath
    PngInDir=$pngInDir; PngOutDir=$pngOutDir; DdsOutDir=$ddsOutDir
    PngInPath=$pngInPath; PngOutPath=$pngOutPath; DdsOutPath=$ddsOutPath
    PngInActual=$null; PngOutActual=$null; DdsActual=$null
  })
}

Write-Host "Manifest: $($manifest.Count) files."
if ($DryRun) { Write-Host "DRYRUN: not executing stages."; return }

$manifest0 = [object[]]$manifest.ToArray()

# --------------------------------------------------------------------------------------
# Optional: backup originals (serial, reliable)
# --------------------------------------------------------------------------------------
if ($Apply) {
  Write-Host "Stage 1: Backup originals (serial)..."
  $i = 0
  foreach ($m in $manifest0) {
    Ensure-Dir (Split-Path $m.BackupPath -Parent)
    Copy-Item -LiteralPath $m.FullName -Destination $m.BackupPath -Force
    $i++
    if (($i % 500) -eq 0) { Write-Host "  backed up $i / $($manifest0.Count)" }
  }
  Write-Host "Stage 1 done. OK=$i FAIL=0"
}

# --------------------------------------------------------------------------------------
# Stage 2: DDS -> PNG (parallel)  (RETURN 1 object per input -> progress updates)
# --------------------------------------------------------------------------------------
Write-Host "Stage 2: DDS -> PNG (parallel)..."
$null = Invoke-ParallelStageWithProgress `
  -Activity "Stage 2: DDS -> PNG" `
  -InputObject $manifest0 `
  -ThrottleLimit $ThrottleLimit `
  -CountPath $pngInRoot `
  -CountFilter "*.png" `
  -ParallelScript {
    try {
      [System.IO.Directory]::CreateDirectory($_.PngInDir) | Out-Null

      $psi = [System.Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = $using:TexconvExe
      $psi.Arguments = "-nologo -y -ft png -o `"$($_.PngInDir)`" `"$($_.FullName)`""
      $psi.UseShellExecute = $false
      $psi.RedirectStandardError  = $true
      $psi.RedirectStandardOutput = $true
      $p = [System.Diagnostics.Process]::new()
      $p.StartInfo = $psi
      [void]$p.Start()
      if (-not $p.WaitForExit($using:TexconvTimeoutSeconds * 1000)) {
        try { $p.Kill($true) } catch {}
      }
    } catch {}
    # IMPORTANT: always emit one object so progress can count it
    [PSCustomObject]@{ File=$_.FullName; Done=$true }
  }

# verify on disk
$manifest2 = New-Object System.Collections.ArrayList
$missing2  = New-Object System.Collections.ArrayList
foreach ($m in $manifest0) {
  $actual = Find-ExpectedFile -Path $m.PngInPath
  if ($actual) { $m.PngInActual = $actual; [void]$manifest2.Add($m) }
  else { [void]$missing2.Add($m) }
}
Write-Host "Stage 2 verified on disk. OK=$($manifest2.Count) MISSING=$($missing2.Count)"
if ($missing2.Count -gt 0) { $missing2 | Select-Object -First 20 FullName | Format-Table -AutoSize }

$manifest2a = [object[]]$manifest2.ToArray()

# --------------------------------------------------------------------------------------
# Stage 3: remove GI (parallel)  (RETURN per item)
# --------------------------------------------------------------------------------------
Write-Host "Stage 3: Set remove GI (parallel)..."
$null = Invoke-ParallelStageWithProgress `
  -Activity "Stage 3: remove GI" `
  -InputObject $manifest2a `
  -ThrottleLimit $ThrottleLimit `
  -CountPath $pngOutRoot `
  -CountFilter "*.png" `
  -ParallelScript {
    try {
      [System.IO.Directory]::CreateDirectory($_.PngOutDir) | Out-Null
      $pngIn = $_.PngInActual
      if ($pngIn) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $using:MagickExe
        $alphaPct = [int][Math]::Round(100.0 * [double]$using:Alpha)
		if ($alphaPct -lt 0) { $alphaPct = 0 }
		if ($alphaPct -gt 100) { $alphaPct = 100 }
		#$psi.Arguments = "`"$pngIn`" -alpha on ( -size $($_.Width)x$($_.Height) xc:gray50 ) -compose CopyOpacity -composite `"$($_.PngOutPath)`""
		$psi.Arguments = "`"$pngIn`" -alpha on ( -size $($_.Width)x$($_.Height) xc:gray$alphaPct ) -compose CopyOpacity -composite `"$($_.PngOutPath)`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError  = $true
        $psi.RedirectStandardOutput = $true
        $p = [System.Diagnostics.Process]::new()
        $p.StartInfo = $psi
        [void]$p.Start()
        if (-not $p.WaitForExit($using:MagickTimeoutSeconds * 1000)) {
          try { $p.Kill($true) } catch {}
        }
      }
    } catch {}
    [PSCustomObject]@{ File=$_.FullName; Done=$true }
  }

# verify on disk
$manifest3 = New-Object System.Collections.ArrayList
$missing3  = New-Object System.Collections.ArrayList
foreach ($m in $manifest2a) {
  $actual = Find-ExpectedFile -Path $m.PngOutPath
  if ($actual) { $m.PngOutActual = $actual; [void]$manifest3.Add($m) }
  else { [void]$missing3.Add($m) }
}
Write-Host "Stage 3 verified on disk. OK=$($manifest3.Count) MISSING=$($missing3.Count)"
if ($missing3.Count -gt 0) { $missing3 | Select-Object -First 20 FullName | Format-Table -AutoSize }

$manifest3a = [object[]]$manifest3.ToArray()

# --------------------------------------------------------------------------------------
# Stage 4: PNG -> BC7 DDS (parallel)  (RETURN per item)
# --------------------------------------------------------------------------------------
Write-Host "Stage 4: PNG -> BC7 DDS (parallel)..."
$null = Invoke-ParallelStageWithProgress `
  -Activity "Stage 4: PNG -> DDS" `
  -InputObject $manifest3a `
  -ThrottleLimit $ThrottleLimit `
  -CountPath $ddsOutRoot `
  -CountFilter "*.dds" `
  -ParallelScript {
    try {
      [System.IO.Directory]::CreateDirectory($_.DdsOutDir) | Out-Null
      $png = $_.PngOutActual
      if ($png) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $using:TexconvExe
        $psi.Arguments = "-nologo -y -f BC7_UNORM -w $($_.Width) -h $($_.Height) -m $($_.Mips) -o `"$($_.DdsOutDir)`" `"$png`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError  = $true
        $psi.RedirectStandardOutput = $true
        $p = [System.Diagnostics.Process]::new()
        $p.StartInfo = $psi
        [void]$p.Start()
        if (-not $p.WaitForExit($using:TexconvTimeoutSeconds * 1000)) {
          try { $p.Kill($true) } catch {}
        }
      }
    } catch {}
    [PSCustomObject]@{ File=$_.FullName; Done=$true }
  }

# verify on disk
$manifest4 = New-Object System.Collections.ArrayList
$missing4  = New-Object System.Collections.ArrayList
foreach ($m in $manifest3a) {
  $actual = Find-ExpectedFile -Path $m.DdsOutPath
  if ($actual) { $m.DdsActual = $actual; [void]$manifest4.Add($m) }
  else { [void]$missing4.Add($m) }
}
Write-Host "Stage 4 verified on disk. OK=$($manifest4.Count) MISSING=$($missing4.Count)"
if ($missing4.Count -gt 0) { $missing4 | Select-Object -First 20 FullName | Format-Table -AutoSize }

$manifest4a = [object[]]$manifest4.ToArray()

if (-not $Apply) {
  Write-Host ""
  Write-Host "DONE (no -Apply): originals were NOT modified."
  Write-Host "Outputs are in: $workRoot"
  return
}

# --------------------------------------------------------------------------------------
# Stage 5: Apply results back to originals (serial) + cleanup
# --------------------------------------------------------------------------------------
Write-Host "Stage 5: Apply results back to originals (serial)..."
$applyFail = New-Object System.Collections.ArrayList
$applied = 0

foreach ($m in $manifest4a) {
  try {
    if (-not (Test-Path -LiteralPath $m.DdsActual)) { throw "Produced DDS missing: $($m.DdsActual)" }
    Copy-Item -LiteralPath $m.DdsActual -Destination $m.FullName -Force
    $applied++
    if (($applied % 500) -eq 0) { Write-Host "  applied $applied / $($manifest4a.Count)" }
  } catch {
    [void]$applyFail.Add([PSCustomObject]@{ File=$m.FullName; Error=$_.Exception.Message })
  }
}

Write-Host "Stage 5 done. OK=$applied FAIL=$($applyFail.Count)"
if ($applyFail.Count -gt 0) {
  Write-Host "First apply failures:"
  $applyFail | Select-Object -First 20 File,Error | Format-Table -AutoSize
  Write-Host "Keeping temp folders for inspection:"
  Write-Host "  Work:   $workRoot"
  Write-Host "  Backup: $backupDir"
  return
}

Write-Host "Apply succeeded."
Cleanup-TempFolders -WorkRoot $workRoot -BackupDir $backupDir -Apply ([bool]$Apply) -Keep ([bool]$Keep)