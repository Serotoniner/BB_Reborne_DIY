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

    # Optional Noir low-res color pass. The runner must pass -Noir explicitly.
    [string]$MagickExe = "",
    [switch]$Noir,

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

# Minimal Noir Repack L path:
# - target only true _a_l low-resolution albedo textures
# - apply only a simple desaturation pass when -Noir is explicitly supplied
# - preserve the source DXGI format when re-encoding
# - do not touch _n_l / _r_l / _s_l or other data/control low-res textures
$NoirActive = [bool]$Noir
$ResolvedMagickExe = $null

function Resolve-ImageMagickExe {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (Test-Path -LiteralPath $RequestedPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $RequestedPath).Path
        }
        throw "magick.exe not found: $RequestedPath"
    }

    $fromPath = Get-Command magick.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($fromPath -and -not [string]::IsNullOrWhiteSpace([string]$fromPath.Source)) {
        return [string]$fromPath.Source
    }

    $roots = @(
        [Environment]::GetFolderPath('ProgramFiles'),
        [Environment]::GetFolderPath('ProgramFilesX86')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($root in $roots) {
        $dirs = @(
            Get-ChildItem -LiteralPath $root -Directory -Filter 'ImageMagick*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
        )
        foreach ($dir in $dirs) {
            $candidate = Join-Path $dir.FullName 'magick.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }

    return $null
}

function Ensure-Dir([string]$p) {
    [System.IO.Directory]::CreateDirectory($p) | Out-Null
}

function Get-StableWorkKey {
    param([Parameter(Mandatory=$true)][string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    # 128 bits is ample for collision avoidance here and keeps paths short.
    return ([System.Convert]::ToHexString($hash).Substring(0, 32).ToLowerInvariant())
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
    # Minimal path:
    #   _a_l is decoded/desaturated/re-encoded.
    #   _n_l/_r_l/_s_l use the v21 byte-preserving top-mip stripper.
    # No other low-res texture types are rewritten.
    return $name -match '_(a|n|r|s)_l(?=-tpf-dcx$)'
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


function Copy-DdsTopMipOnly {
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [Parameter(Mandatory=$true)][string]$DestinationPath
    )

    [byte[]]$bytes = [System.IO.File]::ReadAllBytes($SourcePath)
    if ($bytes.Length -lt 128) { throw "DDS is too small: $SourcePath" }
    if ([System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'DDS ') {
        throw "Not a DDS file: $SourcePath"
    }

    [uint32]$height = [System.BitConverter]::ToUInt32($bytes, 12)
    [uint32]$width  = [System.BitConverter]::ToUInt32($bytes, 16)
    [uint32]$depth  = [System.BitConverter]::ToUInt32($bytes, 24)
    [uint32]$caps2  = [System.BitConverter]::ToUInt32($bytes, 112)
    $fourCC = [System.Text.Encoding]::ASCII.GetString($bytes, 84, 4)

    if ($width -lt 1 -or $height -lt 1) {
        throw "Invalid DDS dimensions: ${width}x${height}"
    }
    if (($caps2 -band 0x00000200) -ne 0 -or ($caps2 -band 0x00200000) -ne 0) {
        throw "Cubemap/volume DDS is not supported by the top-mip stripper: $SourcePath"
    }

    [int]$dataOffset = 128
    [int]$blockBytes = 0
    [long]$topMipBytes = 0

    if ($fourCC -eq 'DX10') {
        if ($bytes.Length -lt 148) { throw "Truncated DX10 DDS header: $SourcePath" }
        $dataOffset = 148
        [uint32]$dxgiFormat = [System.BitConverter]::ToUInt32($bytes, 128)
        [uint32]$miscFlag   = [System.BitConverter]::ToUInt32($bytes, 136)
        [uint32]$arraySize  = [System.BitConverter]::ToUInt32($bytes, 140)

        if ($arraySize -ne 1 -or ($miscFlag -band 0x4) -ne 0) {
            throw "DDS arrays/cubemaps are not supported by the top-mip stripper: $SourcePath"
        }

        if ($dxgiFormat -in @(70,71,72,79,80,81)) {
            $blockBytes = 8
        }
        elseif ($dxgiFormat -in @(73,74,75,76,77,78,82,83,84,94,95,96,97,98,99)) {
            $blockBytes = 16
        }
        else {
            # Uncompressed DXGI formats used by this pipeline are uncommon. Abort rather
            # than silently producing an invalid DDS or changing the source data.
            throw "Unsupported DXGI format for byte-preserving mip removal: $dxgiFormat ($SourcePath)"
        }
    }
    else {
        if ($fourCC -in @('DXT1','ATI1','BC4U','BC4S')) {
            $blockBytes = 8
        }
        elseif ($fourCC -in @('DXT2','DXT3','DXT4','DXT5','ATI2','BC5U','BC5S')) {
            $blockBytes = 16
        }
        else {
            [uint32]$ddsFlags = [System.BitConverter]::ToUInt32($bytes, 8)
            [uint32]$pitch    = [System.BitConverter]::ToUInt32($bytes, 20)
            [uint32]$rgbBits  = [System.BitConverter]::ToUInt32($bytes, 88)
            if (($ddsFlags -band 0x8) -ne 0 -and $pitch -gt 0) {
                $topMipBytes = [long]$pitch * [long]$height
            }
            elseif ($rgbBits -gt 0) {
                $topMipBytes = [long]$width * [long]$height * [long][Math]::Ceiling($rgbBits / 8.0)
            }
            else {
                throw "Unsupported legacy DDS format '$fourCC': $SourcePath"
            }
        }
    }

    if ($blockBytes -gt 0) {
        [long]$blocksWide = [Math]::Max(1, [Math]::Ceiling($width / 4.0))
        [long]$blocksHigh = [Math]::Max(1, [Math]::Ceiling($height / 4.0))
        $topMipBytes = $blocksWide * $blocksHigh * $blockBytes
    }
    if ($depth -gt 1) { $topMipBytes *= $depth }

    [long]$requiredLength = [long]$dataOffset + $topMipBytes
    if ($topMipBytes -lt 1 -or $requiredLength -gt $bytes.Length) {
        throw "DDS top mip exceeds available payload: need=$requiredLength have=$($bytes.Length) file=$SourcePath"
    }

    [byte[]]$outBytes = [byte[]]::new([int]$requiredLength)
    [System.Array]::Copy($bytes, 0, $outBytes, 0, [int]$requiredLength)

    # Match texconv's valid one-mip headers: mip count 1, texture cap retained,
    # complex/mipmap caps cleared. Keep the MIPMAPCOUNT flag as texconv does.
    [System.BitConverter]::GetBytes([uint32]1).CopyTo($outBytes, 28)
    [uint32]$caps = [System.BitConverter]::ToUInt32($outBytes, 108)
    $caps = [uint32]($caps -band 0xFFBFFFF7)
    [System.BitConverter]::GetBytes($caps).CopyTo($outBytes, 108)

    $destParent = Split-Path $DestinationPath -Parent
    [System.IO.Directory]::CreateDirectory($destParent) | Out-Null
    [System.IO.File]::WriteAllBytes($DestinationPath, $outBytes)

    return [PSCustomObject]@{
        SourceBytes = $bytes.Length
        OutputBytes = $outBytes.Length
        Width       = $width
        Height      = $height
        FourCC      = $fourCC
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

Write-Host "SCRIPT VERSION: v33 (Noir Repack L: _a_l simple desat + v21 data top-mip strip)"
Write-Host "RootDir : $rootFull"
Write-Host "WorkRoot: $WorkRoot"
Write-Host "LogRoot : $LogRoot"
Write-Host "Throttle: $ThrottleLimit"
Write-Host "Noir mode: $NoirActive"
Write-Host "Backup  : " -NoNewline
if ($NoBackup) { Write-Host "disabled" } else { Write-Host $BackupDir }
Write-Host ""

if ($NoirActive) {
    $ResolvedMagickExe = Resolve-ImageMagickExe -RequestedPath $MagickExe
    if ([string]::IsNullOrWhiteSpace($ResolvedMagickExe)) {
        throw 'Noir _a_l desaturation requires ImageMagick, but magick.exe could not be resolved.'
    }
    Write-Host ("ImageMagick: {0}" -f $ResolvedMagickExe)
    Write-Host "Noir _a_l: simple desaturate only (-modulate 100,0), v16-style -srgbi encode; _n/_r/_s_l use v21 byte-preserving top-mip strip."
    Write-Host ""
}

$folders = @(
    Get-ChildItem -LiteralPath $rootFull -Directory -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*-tpf-dcx" -and (Is-LowResRepairFolderName $_.Name) }
)

if ($folders.Count -eq 0) {
    Write-Host "No low-res *_a_l/_n_l/_r_l/_s_l-tpf-dcx folders found."
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
        WorkKey    = Get-StableWorkKey -Text $rel
        BackupPath = $backupPath
    })
}

if (-not $NoBackup) {
    Write-Host "Backing up original *_a_l/_n_l/_r_l/_s_l DDS..."
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
$copyDdsTopMipOnlyDef  = ${function:Copy-DdsTopMipOnly}.ToString()

$results = Invoke-ParallelStageWithProgress `
    -Activity "RepackL standalone: _a_l desat + _n_l/_r_l/_s_l v21 top-mip strip" `
    -InputObject ([object[]]$manifest.ToArray()) `
    -ThrottleLimit $ThrottleLimit `
    -CountPath $ReencRoot `
    -CountFilter "*.dds" `
    -ParallelScript {
        ${function:Get-TexconvFormatInfo} = $using:getTexconvFormatInfoDef
        ${function:Copy-DdsTopMipOnly} = $using:copyDdsTopMipOnlyDef

        $item = $_
        $file = $item.FullName

        $ok = $false
        $usedIgnoreMips = $false
        $rewritten = $false
        $noirProcessed = $false
        $dataTopMipOnly = $false
        $err = $null

        try {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
            $workKey = $item.WorkKey

            $tmpDecode = Join-Path $using:DecodeRoot ($workKey + "_" + $name)
            $tmpReenc  = Join-Path $using:ReencRoot  ($workKey + "_" + $name)
            [System.IO.Directory]::CreateDirectory($tmpDecode) | Out-Null
            [System.IO.Directory]::CreateDirectory($tmpReenc)  | Out-Null

            $log = Join-Path $using:LogRoot ("repack_l_" + $workKey + ".log")
            $leaf = [System.IO.Path]::GetFileNameWithoutExtension($file)
            $outDds = Join-Path $tmpReenc ([System.IO.Path]::GetFileName($file))
            $png = Join-Path $tmpDecode ($name + ".png")
            $encodePng = $png

            $isAlbedoL = ($leaf -match '_a_l(?:$|_)')
            $isDataLowResL = ($leaf -match '_(n|r|s)_l(?:$|_)')

            if ($isDataLowResL) {
                # v21 approach:
                # Preserve the exact compressed top-level data. Do not decode through PNG,
                # do not run ImageMagick, and do not ask texconv to recompress. Strip the
                # mip tail byte-for-byte and update only the DDS mip/caps fields.
                $stripInfo = Copy-DdsTopMipOnly -SourcePath $file -DestinationPath $outDds
                $encOut = @(
                    "byte-preserving DDS top-mip strip",
                    ("sourceBytes={0} outputBytes={1} size={2}x{3} fourCC={4}" -f $stripInfo.SourceBytes, $stripInfo.OutputBytes, $stripInfo.Width, $stripInfo.Height, $stripInfo.FourCC)
                )
                $LASTEXITCODE = 0
                $dataTopMipOnly = $true
                Add-Content -LiteralPath $log -Value ("[REPACKL-DATA-TOP-MIP-ONLY] " + $leaf + " | v21 byte-preserving top mip; no texconv/color conversion")
            }
            else {
                # _a_l path only: decode source DDS -> PNG first, using -ignoremips fallback when needed.
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

                # Noir reset path: only simple desaturation for true low-res albedo.
                # No gamma, no blur/noise/filter, no moon branch, and no blood/selective-red branch.
                if ($using:NoirActive -and $isAlbedoL) {
                    $tmpNoir = Join-Path $tmpDecode "_noir"
                    [System.IO.Directory]::CreateDirectory($tmpNoir) | Out-Null
                    $noirPng = Join-Path $tmpNoir ($name + ".png")

                    $imOut = & $using:ResolvedMagickExe $png `
                        -alpha on `
                        -modulate 100,0 `
                        "PNG32:$noirPng" 2>&1
                    $imOut | Add-Content -LiteralPath $log

                    if ($LASTEXITCODE -ne 0) { throw "Noir _a_l desaturate failed (exit $LASTEXITCODE)" }
                    if (-not (Test-Path -LiteralPath $noirPng)) { throw "Noir _a_l desaturate did not produce PNG" }

                    $encodePng = $noirPng
                    $noirProcessed = $true
                    Add-Content -LiteralPath $log -Value ("[REPACKL-NOIR-A-L-DESAT] " + $file)
                }

                # _a_l: preserve source BC1/BC7 and UNORM/SRGB distinction.
                # In Noir mode restore the v16 brightness behavior: preserved source
                # format + -srgbi + -m 1.
                $fmtInfo = Get-TexconvFormatInfo -TexconvOutput @($tcOut) -FilePath $file
                $albedoFmt = $fmtInfo.Format
                if ($albedoFmt -notin @('BC1_UNORM_SRGB','BC1_UNORM','BC7_UNORM_SRGB','BC7_UNORM')) {
                    $albedoFmt = 'BC1_UNORM_SRGB'
                }

                if ($using:NoirActive) {
                    $encOut = & $using:TexconvExe -nologo -f $albedoFmt -srgbi -m 1 -y -o $tmpReenc $encodePng 2>&1
                    Add-Content -LiteralPath $log -Value ("[REPACKL-ALBEDO-L-FORMAT] " + $albedoFmt + " | Noir v16-style -srgbi encode")
                }
                else {
                    $encOut = & $using:TexconvExe -nologo -f $albedoFmt -m 1 -y -o $tmpReenc $encodePng 2>&1
                    Add-Content -LiteralPath $log -Value ("[REPACKL-ALBEDO-L-FORMAT] " + $albedoFmt + " | normal encode")
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
                NoirProcessed  = $noirProcessed
                DataTopMipOnly = $dataTopMipOnly
                Error          = $err
                Done           = $true
            }
        }
    }

$okCount      = @($results | Where-Object { $_.Ok }).Count
$ignoreCount  = @($results | Where-Object { $_.UsedIgnoreMips }).Count
$rewriteCount = @($results | Where-Object { $_.Rewritten }).Count
$noirCount    = @($results | Where-Object { $_.NoirProcessed }).Count
$dataTopCount = @($results | Where-Object { $_.DataTopMipOnly }).Count
$failList     = @($results | Where-Object { -not $_.Ok })

Write-Host ""
Write-Host ("RepackL standalone done. OK={0} Rewritten={1} NoirAlbedoL={2} DataTopMipOnlyL={3} UsedIgnoreMips={4} FAIL={5}" -f `
    $okCount, $rewriteCount, $noirCount, $dataTopCount, $ignoreCount, $failList.Count)

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