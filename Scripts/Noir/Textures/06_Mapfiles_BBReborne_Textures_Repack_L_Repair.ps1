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

    [int]$ThrottleLimit = 1,
    [switch]$Keep,

    # Backup behavior (matches your other scripts style more closely)
    [string]$BackupDir = "",
    [switch]$NoBackup
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

if ($PSVersionTable.PSVersion.Major -lt 7) { throw "Run with PowerShell 7+ (pwsh)." }
if (-not (Test-Path -LiteralPath $RootDir)) { throw "RootDir not found: $RootDir" }
if (-not (Test-Path -LiteralPath $TexconvExe)) { throw "texconv.exe not found: $TexconvExe" }

function Ensure-Dir([string]$p) {
    [System.IO.Directory]::CreateDirectory($p) | Out-Null
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

function Is-LowResRepairFolderName([string]$name) {
    return $name -match '_(a|r|s|n)_l(?=-tpf-dcx$)'
}

function Get-TexconvFormatInfo {
    param(
        [Parameter(Mandatory=$true)][string[]]$TexconvOutput,
        [Parameter(Mandatory=$true)][string]$FilePath
    )

    $joined = ($TexconvOutput -join "`n")
    $fmt = $null

    if     ($joined -match '\bBC1_UNORM_SRGB\b') { $fmt = 'BC1_UNORM_SRGB' }
    elseif ($joined -match '\bBC1_UNORM\b')      { $fmt = 'BC1_UNORM' }
    elseif ($joined -match '\bBC7_UNORM_SRGB\b') { $fmt = 'BC7_UNORM_SRGB' }
    elseif ($joined -match '\bBC7_UNORM\b')      { $fmt = 'BC7_UNORM' }
    elseif ($joined -match '\bBC4_UNORM\b')      { $fmt = 'BC4_UNORM' }
    elseif ($joined -match '\bBC5_UNORM\b')      { $fmt = 'BC5_UNORM' }
    elseif ($joined -match '\bBC3_UNORM_SRGB\b') { $fmt = 'BC3_UNORM_SRGB' }
    elseif ($joined -match '\bBC3_UNORM\b')      { $fmt = 'BC3_UNORM' }
    elseif ($joined -match '\bBC2_UNORM_SRGB\b') { $fmt = 'BC2_UNORM_SRGB' }
    elseif ($joined -match '\bBC2_UNORM\b')      { $fmt = 'BC2_UNORM' }

    if (-not $fmt) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
        if     ($name -match '_s(?:_|$)') { $fmt = 'BC4_UNORM' }
        elseif ($name -match '_n(?:_|$)') { $fmt = 'BC7_UNORM' }
        elseif ($name -match '_a(?:_|$)') { $fmt = 'BC1_UNORM_SRGB' }
        elseif ($name -match '_r(?:_|$)') { $fmt = 'BC1_UNORM' }
    }

    return [PSCustomObject]@{
        Format = $fmt
    }
}

$rootFull   = (Resolve-Path -LiteralPath $RootDir).Path
$rootFull   = $rootFull -replace '[\\/]+$',''
$rootLeaf   = Split-Path $rootFull -Leaf
$rootParent = Split-Path $rootFull -Parent

$RepairRoot = Join-Path $rootParent ("{0}_repack_l_repair" -f $rootLeaf)
$WorkRoot   = Join-Path $RepairRoot "_work"
$LogRoot    = Join-Path $RepairRoot "_logs"
$DecodeRoot = Join-Path $WorkRoot "decode"
$ReencRoot  = Join-Path $WorkRoot "reencoded"

if ([string]::IsNullOrWhiteSpace($BackupDir)) {
    $BackupDir = Join-Path $rootParent ("{0}_backup_original_dds_repack_l" -f $rootLeaf)
}

Ensure-Dir $RepairRoot
Ensure-Dir $WorkRoot
Ensure-Dir $LogRoot
Ensure-Dir $DecodeRoot
Ensure-Dir $ReencRoot
if (-not $NoBackup) {
    Ensure-Dir $BackupDir
}

Write-Host "SCRIPT VERSION: repack_l standalone"
Write-Host "RootDir : $rootFull"
Write-Host "WorkRoot: $WorkRoot"
Write-Host "LogRoot : $LogRoot"
Write-Host "Throttle: $ThrottleLimit"
Write-Host "Backup  : " -NoNewline
if ($NoBackup) { Write-Host "disabled" } else { Write-Host $BackupDir }
Write-Host ""

$folders = @(
    Get-ChildItem -LiteralPath $rootFull -Directory -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*-tpf-dcx" -and (Is-LowResRepairFolderName $_.Name) }
)

if ($folders.Count -eq 0) {
    Write-Host "No low-res *_l-tpf-dcx folders found."
    return
}

$ddsList = New-Object System.Collections.ArrayList
foreach ($fld in $folders) {
    $dds = @(Get-ChildItem -LiteralPath $fld.FullName -Filter *.dds -File -ErrorAction SilentlyContinue)
    foreach ($d in $dds) { [void]$ddsList.Add($d.FullName) }
}

Write-Host ("Target folders: {0}" -f $folders.Count)
Write-Host ("Target DDS    : {0}" -f $ddsList.Count)
Write-Host ""

if ($ddsList.Count -eq 0) { return }

$rootPrefix = $rootFull
if (-not $rootPrefix.EndsWith('\')) { $rootPrefix += '\' }

$manifest = New-Object System.Collections.ArrayList
foreach ($full in $ddsList) {
    $rel = if ($full.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $full.Substring($rootPrefix.Length)
    } else {
        [System.IO.Path]::GetFileName($full)
    }

    $backupPath = if (-not $NoBackup) { Join-Path $BackupDir $rel } else { $null }

    [void]$manifest.Add([PSCustomObject]@{
        FullName   = $full
        Rel        = $rel
        BackupPath = $backupPath
    })
}

if (-not $NoBackup) {
    Write-Host "Backing up original *_l DDS..."
    $i = 0
    foreach ($m in $manifest) {
        Ensure-Dir (Split-Path $m.BackupPath -Parent)
        Copy-Item -LiteralPath $m.FullName -Destination $m.BackupPath -Force
        $i++
    }
    Write-Host ("Backed up: {0}" -f $i)
    Write-Host ""
}

$getTexconvFormatInfoDef = ${function:Get-TexconvFormatInfo}.ToString()

$results = Invoke-ParallelStageWithProgress `
    -Activity "RepackL standalone: repair *_l DDS" `
    -InputObject ([object[]]$manifest.ToArray()) `
    -ThrottleLimit $ThrottleLimit `
    -CountPath $ReencRoot `
    -CountFilter "*.dds" `
    -ParallelScript {
        ${function:Get-TexconvFormatInfo} = $using:getTexconvFormatInfoDef

        $item = $_
        $file = $item.FullName

        $ok = $false
        $usedIgnoreMips = $false
        $rewritten = $false
        $err = $null

        try {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
            $parentDir = Split-Path $file -Parent
            $dirHash = [Convert]::ToHexString([System.Text.Encoding]::UTF8.GetBytes($parentDir))
            if ($dirHash.Length -gt 32) { $dirHash = $dirHash.Substring(0,32) }

            $tmpDecode = Join-Path $using:DecodeRoot ($dirHash + "_" + $name)
            $tmpReenc  = Join-Path $using:ReencRoot  ($dirHash + "_" + $name)
            [System.IO.Directory]::CreateDirectory($tmpDecode) | Out-Null
            [System.IO.Directory]::CreateDirectory($tmpReenc)  | Out-Null

            $log = Join-Path $using:LogRoot ("repack_l_" + $dirHash + ".log")
            $leaf = [System.IO.Path]::GetFileNameWithoutExtension($file)
            $outDds = Join-Path $tmpReenc ([System.IO.Path]::GetFileName($file))
            $png = Join-Path $tmpDecode ($name + ".png")

            # Decode source DDS -> PNG first, using -ignoremips fallback when needed.
            $tcOut = & $using:TexconvExe -nologo -ft png -y -o $tmpDecode $file 2>&1
            $tcOut | Add-Content -LiteralPath $log

            if (($LASTEXITCODE -ne 0) -or (-not (Test-Path -LiteralPath $png))) {
                Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue
                $tcOut = & $using:TexconvExe -nologo -ignoremips -ft png -y -o $tmpDecode $file 2>&1
                $tcOut | Add-Content -LiteralPath $log
                $usedIgnoreMips = $true
            }

            if (($LASTEXITCODE -ne 0) -or (-not (Test-Path -LiteralPath $png))) {
                throw "decode failed (normal and -ignoremips)"
            }

            # Re-encode according to the corresponding non-_l main-line scripts.
            if ($leaf -match '_s_l(?:$|_)') {
                # Matches 06_specular_fix.ps1 style
                $encOut = & $using:TexconvExe -nologo -f BC4_UNORM -dx9 --ignore-srgb -m 1 -y -o $tmpReenc $png 2>&1
            }
            elseif ($leaf -match '_a_l(?:$|_)') {
                # Matches 02_upscale_a_diffuse_2x_ai.ps1 style
                $encOut = & $using:TexconvExe -nologo -f BC1_UNORM_SRGB -srgbi -m 1 -y -o $tmpReenc $png 2>&1
            }
            elseif ($leaf -match '_r_l(?:$|_)') {
                # Matches 03_upscale_data_linear_rgba_bc1.ps1 style
                $encOut = & $using:TexconvExe -nologo -f BC1_UNORM -m 1 -y -o $tmpReenc $png 2>&1
            }
            elseif ($leaf -match '_n_l(?:$|_)') {
                # Best match to the main-line normal/height handling
                $encOut = & $using:TexconvExe -nologo -f BC7_UNORM --ignore-srgb -m 1 -y -o $tmpReenc $png 2>&1
            }
            else {
                $fmtInfo = Get-TexconvFormatInfo -TexconvOutput @($tcOut) -FilePath $file
                $fmt = $fmtInfo.Format
                if ([string]::IsNullOrWhiteSpace($fmt)) {
                    throw "could not determine output format"
                }

                if ($fmt -like 'BC4_*') {
                    $encOut = & $using:TexconvExe -nologo -f $fmt -dx9 --ignore-srgb -m 1 -y -o $tmpReenc $png 2>&1
                } else {
                    $encOut = & $using:TexconvExe -nologo -f $fmt --ignore-srgb -m 1 -y -o $tmpReenc $png 2>&1
                }
            }

            $encOut | Add-Content -LiteralPath $log

            if ($LASTEXITCODE -ne 0) { throw "re-encode failed (exit $LASTEXITCODE)" }
            if (-not (Test-Path -LiteralPath $outDds)) { throw "re-encode did not produce DDS" }

            # Validate rebuilt DDS
            $valDir = Join-Path $tmpReenc "_validate"
            [System.IO.Directory]::CreateDirectory($valDir) | Out-Null
            $valPng = Join-Path $valDir ($name + ".png")
            $valOut = & $using:TexconvExe -nologo -ft png -y -o $valDir $outDds 2>&1
            $valOut | Add-Content -LiteralPath $log

            if ($LASTEXITCODE -ne 0) { throw "validation decode failed (exit $LASTEXITCODE)" }
            if (-not (Test-Path -LiteralPath $valPng)) { throw "validation decode did not produce PNG" }

            $srcInfo = Get-Item -LiteralPath $outDds
            $dstBefore = if (Test-Path -LiteralPath $file) { (Get-Item -LiteralPath $file).Length } else { -1 }
            Add-Content -LiteralPath $log -Value ("[REPACKL-COPY-BEFORE] file=" + $file + " dstBytes=" + $dstBefore + " newBytes=" + $srcInfo.Length)

            Copy-Item -LiteralPath $outDds -Destination $file -Force

            $dstAfter = (Get-Item -LiteralPath $file).Length
            Add-Content -LiteralPath $log -Value ("[REPACKL-COPY-AFTER] file=" + $file + " dstBytes=" + $dstAfter)

            # Verify the final in-place file still decodes
            $verifyDir = Join-Path $tmpReenc "_postcopy_verify"
            [System.IO.Directory]::CreateDirectory($verifyDir) | Out-Null
            $verifyOut = & $using:TexconvExe -nologo -ft png -y -o $verifyDir $file 2>&1
            $verifyOut | Add-Content -LiteralPath $log

            if ($LASTEXITCODE -ne 0) {
                throw "post-copy verification decode failed (exit $LASTEXITCODE)"
            }

            Add-Content -LiteralPath $log -Value ("[REPACKL-OK] rewrote in place: " + $file)

            $rewritten = $true
            $ok = $true
        }
        catch {
            $err = $_.Exception.Message
            try {
                Add-Content -LiteralPath $log -Value ("[REPACKL-FAIL] " + $file + " | " + $err)
            } catch {}
        }
        finally {
            [PSCustomObject]@{
                File           = $file
                Ok             = $ok
                UsedIgnoreMips = $usedIgnoreMips
                Rewritten      = $rewritten
                Error          = $err
                Done           = $true
            }
        }
    }

$okCount      = @($results | Where-Object { $_.Ok }).Count
$ignoreCount  = @($results | Where-Object { $_.UsedIgnoreMips }).Count
$rewriteCount = @($results | Where-Object { $_.Rewritten }).Count
$failList     = @($results | Where-Object { -not $_.Ok })

Write-Host ""
Write-Host ("RepackL standalone done. OK={0} Rewritten={1} UsedIgnoreMips={2} FAIL={3}" -f `
    $okCount, $rewriteCount, $ignoreCount, $failList.Count)

if ($failList.Count -gt 0) {
    $failList | Select-Object -First 50 File,Error | Format-Table -AutoSize
}

if ($Keep) {
    Write-Host ""
    Write-Host "Keeping repair work folders:"
    Write-Host ("  RepairRoot: {0}" -f $RepairRoot)
    Write-Host ("  WorkRoot  : {0}" -f $WorkRoot)
    Write-Host ("  LogRoot   : {0}" -f $LogRoot)
    if (-not $NoBackup) { Write-Host ("  BackupDir : {0}" -f $BackupDir) }
}
else {
    Remove-Item -Recurse -Force $WorkRoot -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host ("Logs kept at: {0}" -f $LogRoot)
    if (-not $NoBackup) { Write-Host ("Backup kept at: {0}" -f $BackupDir) }
}