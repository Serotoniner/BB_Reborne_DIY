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
    04_Global_BBReborne_Gparam_GameParam.ps1

    Harmonized gameparam workflow for the BB Reborne DIY Tool.

    Purpose:
    - Copy param\gameparam\gameparam.parambnd.dcx from the configured game folder.
    - Extract the copied archive with WitchyBND.
    - Apply all non-empty patches from:
        <BBReborneDIYTool>\Diffs\param\gameparam\gameparam-parambnd-dcx\_patches
    - Repack the copied archive.
    - Verify the repacked archive is larger than the configured minimum size.
      If it is not, repack again up to MaxRepackAttempts.
    - Produce the patched file under:
        <OutputRoot>\BBReborne_gparam\param\gameparam\gameparam.parambnd.dcx

    Original game files are never modified. They are the backup.

    Expected config file from BBReborneDIYTool.ps1:
        <ToolRoot>\BBReborneDIYTool.paths.ps1

    Example direct run:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\04_Global_BBReborne_Gparam_GameParam.ps1 `
            -ToolPathsPs1 "<BBReborneDIYTool>\Tools\BBReborneDIYTool.paths.ps1"

    Notes:
    - Uses WitchyBND v2.4.0.1 by default and preserves the original Extract_gameparam/Repack_gameparam key flows.
    - Uses Git for patch application.
    - CpuThrottle/GpuThrottle are accepted for launcher consistency, but this workflow is sequential.
#>

param(
    [string]$ToolPathsPs1,
    [string]$GameRoot,
    [string]$OutputRoot,
    [string]$WitchyBndExe,
    [string]$GitExe,
    [int]$CpuThrottle = 0,
    [int]$GpuThrottle = 0,

    [string]$SourceArchiveRelativePath = 'param\gameparam\gameparam.parambnd.dcx',
    [string]$PatchDir,
    [string]$OutputRelativePath = 'param\gameparam\gameparam.parambnd.dcx',

    [int]$MinRepackedSizeKB = 1455,
    [int]$MaxRepackAttempts = 10,

    [int]$StartupDelayMs = 1800,
    [int]$KeyDelayMs = 250,
    [int]$StepDelayMs = 700,

    [switch]$KeepWork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

function Write-Stage {
    param([AllowNull()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-Host ''
        return
    }
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Info {
    param([AllowNull()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    Write-Host $Message
}

function Ensure-Dir {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-OptionalVariableValue {
    param([Parameter(Mandatory)][string]$Name)

    $var = Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $var) { return $null }
    return $var.Value
}

function Resolve-OptionalConfigPath {
    if ($ToolPathsPs1) {
        if (-not (Test-Path -LiteralPath $ToolPathsPs1 -PathType Leaf)) {
            throw "Tool paths file not found: $ToolPathsPs1"
        }
        return (Resolve-Path -LiteralPath $ToolPathsPs1).Path
    }

    $candidates = @(
        (Join-Path $PSScriptRoot '..\..\Tools\BBReborneDIYTool.paths.ps1'),
        (Join-Path $PSScriptRoot '..\Tools\BBReborneDIYTool.paths.ps1'),
        (Join-Path $PSScriptRoot 'Tools\BBReborneDIYTool.paths.ps1'),
        (Join-Path $PSScriptRoot 'BBReborneDIYTool.paths.ps1')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Import-ToolConfig {
    $configPath = Resolve-OptionalConfigPath
    if ($configPath) {
        Write-Info "Using tool config: $configPath"

        # Dot-sourcing from inside a function creates variables in function scope.
        # Copy BBR_* variables back to script scope so standalone runs with only
        # -ToolPathsPs1 can resolve saved paths reliably.
        . $configPath
        Get-Variable -Scope Local -Name 'BBR_*' -ErrorAction SilentlyContinue | ForEach-Object {
            Set-Variable -Name $_.Name -Value $_.Value -Scope Script
        }
    } else {
        Write-Info 'No tool config file found. Parameters must provide all required paths.'
    }
}

function Resolve-RequiredDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label is empty."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-RequiredFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label is empty."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-GameRoot {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-RequiredDirectory -Path $Path -Label 'Game root'
    $leaf = Split-Path -Leaf ($resolved.TrimEnd('\', '/'))
    if ($leaf -ne 'dvdroot_ps4') {
        throw "Game root must end with dvdroot_ps4. Current path: $resolved"
    }

    return $resolved
}

function Resolve-GameArchive {
    param(
        [Parameter(Mandatory)][string]$GameRootPath,
        [Parameter(Mandatory)][string]$RelativeOrAbsolutePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativeOrAbsolutePath)) {
        $archive = Resolve-RequiredFile -Path $RelativeOrAbsolutePath -Label 'Source gameparam archive'
        return [pscustomobject]@{
            FullPath     = $archive
            RelativePath = Split-Path -Leaf $archive
        }
    }

    $candidate = Join-Path $GameRootPath $RelativeOrAbsolutePath
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Source gameparam archive not found: $candidate"
    }

    return [pscustomobject]@{
        FullPath     = (Resolve-Path -LiteralPath $candidate).Path
        RelativePath = ($RelativeOrAbsolutePath -replace '/', '\')
    }
}

function Get-DIYRootCandidates {
    $list = New-Object System.Collections.Generic.List[string]

    if ($PSScriptRoot) {
        [void]$list.Add($PSScriptRoot)
        $parent = Split-Path -Parent $PSScriptRoot
        if ($parent) { [void]$list.Add($parent) }
        $grandParent = Split-Path -Parent $parent
        if ($grandParent) { [void]$list.Add($grandParent) }
    }

    return @($list | Select-Object -Unique)
}

function Resolve-DefaultPatchDir {
    if ($PatchDir) {
        return (Resolve-RequiredDirectory -Path $PatchDir -Label 'Patch directory')
    }

    $relative = 'Diffs\param\gameparam\gameparam-parambnd-dcx\_patches'
    foreach ($root in Get-DIYRootCandidates) {
        $candidate = Join-Path $root $relative
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Patch directory not found. Expected default path: <BBReborneDIYTool>\$relative"
}

function Send-KeySequence {
    param(
        [Parameter(Mandatory)][string[]]$Keys,
        [int]$KeyDelayMs = 250
    )

    foreach ($k in $Keys) {
        [System.Windows.Forms.SendKeys]::SendWait($k)
        Start-Sleep -Milliseconds $KeyDelayMs
    }
}

function Invoke-WitchyExtractGameParam {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$TargetPath,
        [int]$StartupDelayMs = 1800,
        [int]$KeyDelayMs = 250,
        [int]$StepDelayMs = 700
    )

    if (-not (Test-Path -LiteralPath $script:WitchyBndExe -PathType Leaf)) {
        throw "WitchyExe not found: $script:WitchyBndExe"
    }

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        throw "TargetPath not found: $TargetPath"
    }

    Write-Host ""
    Write-Host $Label -ForegroundColor Cyan

    $proc = Start-Process `
        -FilePath $script:WitchyBndExe `
        -ArgumentList @($TargetPath) `
        -PassThru `
        -WindowStyle Normal

    Start-Sleep -Milliseconds $StartupDelayMs

    [void][Microsoft.VisualBasic.Interaction]::AppActivate($proc.Id)
    Start-Sleep -Milliseconds 800

    # Original Extract_gameparam.ps1 flow:
    # ENTER
    # DOWN
    # DOWN
    # ENTER
    # 0
    # ENTER
    Send-KeySequence -Keys @("~") -KeyDelayMs $KeyDelayMs
    Start-Sleep -Milliseconds $StepDelayMs
    Send-KeySequence -Keys @("{DOWN}", "{DOWN}", "~") -KeyDelayMs $KeyDelayMs
    Start-Sleep -Milliseconds $StepDelayMs
    Send-KeySequence -Keys @("0", "~") -KeyDelayMs $KeyDelayMs

    $proc.WaitForExit()

    if ($proc.ExitCode -ne 0) {
        throw "${Label} failed with exit code $($proc.ExitCode)"
    }
}

function Invoke-WitchyRepackGameParam {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$TargetPath,
        [int]$StartupDelayMs = 1800,
        [int]$KeyDelayMs = 250,
        [int]$StepDelayMs = 700
    )

    if (-not (Test-Path -LiteralPath $script:WitchyBndExe -PathType Leaf)) {
        throw "WitchyExe not found: $script:WitchyBndExe"
    }

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        throw "TargetPath not found: $TargetPath"
    }

    Write-Host ""
    Write-Host $Label -ForegroundColor Cyan

    $proc = Start-Process `
        -FilePath $script:WitchyBndExe `
        -ArgumentList @($TargetPath) `
        -PassThru `
        -WindowStyle Normal

    Start-Sleep -Milliseconds $StartupDelayMs

    [void][Microsoft.VisualBasic.Interaction]::AppActivate($proc.Id)
    Start-Sleep -Milliseconds 300

    # Original Repack_gameparam.ps1 flow:
    # ENTER
    Send-KeySequence -Keys @("~") -KeyDelayMs $KeyDelayMs
    Start-Sleep -Milliseconds $StartupDelayMs

    $proc.WaitForExit()

    if ($proc.ExitCode -ne 0) {
        throw "${Label} failed with exit code $($proc.ExitCode)"
    }
}

function Get-WitchyExtractDir {
    param([Parameter(Mandatory)][string]$ArchivePath)

    $parent = Split-Path -Parent $ArchivePath
    $leaf = Split-Path -Leaf $ArchivePath
    $dir = $leaf -replace '\.', '-'
    return (Join-Path $parent $dir)
}

function Wait-ForExtractDir {
    param(
        [Parameter(Mandatory)][string]$ExtractDir,
        [int]$TimeoutSeconds = 30
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path -LiteralPath $ExtractDir -PathType Container) {
            return
        }
        Start-Sleep -Milliseconds 250
    }

    throw "Timed out waiting for extracted folder: $ExtractDir"
}

function Get-APathFromPatchHeader {
    param([Parameter(Mandatory)][string]$PatchPath)

    $first = Get-Content -LiteralPath $PatchPath -TotalCount 1 -Encoding UTF8
    if (-not $first) { return $null }

    $m = [regex]::Match($first, '^diff --git\s+("([^"]+)"|(\S+))\s+("([^"]+)"|(\S+))\s*$')
    if (-not $m.Success) { return $null }

    if ($m.Groups[2].Success) { return $m.Groups[2].Value }
    return $m.Groups[3].Value
}

function Get-RelAfterP1Posix {
    param([Parameter(Mandatory)][string]$PatchPath)

    $aToken = Get-APathFromPatchHeader -PatchPath $PatchPath
    if (-not $aToken) { return $null }

    if ($aToken.StartsWith('a/') -or $aToken.StartsWith('a\')) {
        $aToken = $aToken.Substring(2)
    }

    $aToken = $aToken -replace '\\', '/'
    while ($aToken -match '//') { $aToken = $aToken -replace '//', '/' }

    return $aToken.TrimStart('/')
}

function Write-NormalizedPatch {
    param(
        [Parameter(Mandatory)][string]$SourcePatch,
        [Parameter(Mandatory)][string]$DestPatch
    )

    $lines = @(Get-Content -LiteralPath $SourcePatch -Encoding UTF8)

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($line -match '^(diff --git|--- |\+\+\+ )') {
            $line = $line -replace '\\', '/'
            $line = $line -replace '("a/)a/', '$1'
            $line = $line -replace '("b/)b/', '$1'
            $line = $line -replace '(\sa/)a/', '$1'
            $line = $line -replace '(\sb/)b/', '$1'
            while ($line -match '//') { $line = $line -replace '//', '/' }
        }

        $lines[$i] = $line
    }

    Set-Content -LiteralPath $DestPatch -Value $lines -Encoding UTF8
}

function Get-XmlRowIdFromLine {
    param([AllowNull()][string]$Line)

    if ($null -eq $Line) { return $null }
    $m = [regex]::Match($Line, '<row\s+id="(-?\d+)"')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $null
}

function Get-XmlRowPatchInfo {
    param([Parameter(Mandatory)][string]$PatchPath)

    $lines = Get-Content -LiteralPath $PatchPath -Encoding UTF8

    $addedRows = New-Object System.Collections.Generic.List[string]
    $prevContextRowId = $null
    $nextContextRowId = $null
    $seenAdditions = $false
    $inHunk = $false

    foreach ($line in $lines) {
        if ($line -match '^@@ ') {
            $inHunk = $true
            continue
        }

        if (-not $inHunk) { continue }
        if ($line -match '^\+\+\+ ' -or $line -match '^--- ') { continue }

        if ($line.StartsWith('+')) {
            $payload = $line.Substring(1)
            if ($payload -match '^\s*<row\b.+/>\s*$') {
                $addedRows.Add($payload)
                $seenAdditions = $true
            }
            continue
        }

        if ($line.StartsWith(' ')) {
            $payload = $line.Substring(1)
            $rowId = Get-XmlRowIdFromLine -Line $payload
            if ($null -ne $rowId) {
                if (-not $seenAdditions) {
                    $prevContextRowId = $rowId
                } elseif ($null -eq $nextContextRowId) {
                    $nextContextRowId = $rowId
                }
            }
            continue
        }
    }

    return [pscustomobject]@{
        AddedRows        = @($addedRows)
        PrevContextRowId = $prevContextRowId
        NextContextRowId = $nextContextRowId
    }
}

function Apply-XmlRowPatchFallback {
    param(
        [Parameter(Mandatory)][string]$TargetXmlPath,
        [Parameter(Mandatory)][string]$PatchPath
    )

    $info = Get-XmlRowPatchInfo -PatchPath $PatchPath
    $addedRows = @($info.AddedRows)

    if ($addedRows.Count -eq 0) {
        return $false
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-Content -LiteralPath $TargetXmlPath -Encoding UTF8)) {
        $lines.Add($line)
    }

    $existingIds = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($line in $lines) {
        $id = Get-XmlRowIdFromLine -Line $line
        if ($null -ne $id) {
            [void]$existingIds.Add($id)
        }
    }

    $rowsToInsert = New-Object System.Collections.Generic.List[string]
    foreach ($row in $addedRows) {
        $id = Get-XmlRowIdFromLine -Line $row
        if ($null -eq $id) { continue }
        if (-not $existingIds.Contains($id)) {
            $rowsToInsert.Add($row)
        }
    }

    if ($rowsToInsert.Count -eq 0) {
        Write-Info ("  XML fallback: already applied -> {0}" -f (Split-Path -Leaf $TargetXmlPath))
        return $true
    }

    $insertIndex = -1

    if ($null -ne $info.NextContextRowId) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $id = Get-XmlRowIdFromLine -Line $lines[$i]
            if ($null -ne $id -and $id -eq $info.NextContextRowId) {
                $insertIndex = $i
                break
            }
        }
    }

    if ($insertIndex -lt 0 -and $null -ne $info.PrevContextRowId) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $id = Get-XmlRowIdFromLine -Line $lines[$i]
            if ($null -ne $id -and $id -eq $info.PrevContextRowId) {
                $insertIndex = $i + 1
                break
            }
        }
    }

    if ($insertIndex -lt 0) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*</rows>\s*$') {
                $insertIndex = $i
                break
            }
        }
    }

    if ($insertIndex -lt 0) {
        throw "XML fallback could not find insertion point in: $TargetXmlPath"
    }

    foreach ($row in $rowsToInsert) {
        $lines.Insert($insertIndex, '    ' + $row.Trim())
        $insertIndex++
    }

    Set-Content -LiteralPath $TargetXmlPath -Value $lines -Encoding UTF8
    Write-Info ("  XML fallback applied -> {0} (inserted {1} row(s))" -f (Split-Path -Leaf $TargetXmlPath), $rowsToInsert.Count)

    return $true
}

function Find-TargetXmlForPatch {
    param(
        [Parameter(Mandatory)][string]$ExtractDir,
        [Parameter(Mandatory)][string]$RelPosix
    )

    $relWin = $RelPosix -replace '/', '\'
    $direct = Join-Path $ExtractDir $relWin
    if (Test-Path -LiteralPath $direct -PathType Leaf) {
        return [pscustomobject]@{ FullPath = $direct; RelWin = $relWin; RelPosix = $RelPosix }
    }

    $leaf = Split-Path -Leaf $relWin
    $matches = @(Get-ChildItem -LiteralPath $ExtractDir -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue)
    if ($matches.Count -eq 1) {
        $full = $matches[0].FullName
        $relative = $full.Substring($ExtractDir.TrimEnd('\', '/').Length).TrimStart('\', '/')
        $relative = $relative -replace '/', '\'
        return [pscustomobject]@{ FullPath = $full; RelWin = $relative; RelPosix = ($relative -replace '\\', '/') }
    }

    return $null
}

function Apply-GameParamPatches {
    param(
        [Parameter(Mandatory)][string]$PatchRoot,
        [Parameter(Mandatory)][string]$ExtractDir,
        [Parameter(Mandatory)][string]$GitExe
    )

    $patches = @(Get-ChildItem -LiteralPath $PatchRoot -File -Filter '*.patch' | Where-Object Length -gt 0)
    Write-Info ("Found {0} patch file(s) under: {1}" -f $patches.Count, $PatchRoot)

    if ($patches.Count -eq 0) {
        throw "No non-empty patch files found in: $PatchRoot"
    }

    $patchWork = Join-Path $script:RunWorkDir 'patch_apply_work'
    Ensure-Dir $patchWork

    $jobs = New-Object System.Collections.Generic.List[object]

    foreach ($patch in $patches) {
        $relPosix = Get-RelAfterP1Posix -PatchPath $patch.FullName
        if (-not $relPosix) {
            Write-Warning "SKIP: $($patch.Name) could not parse diff header."
            continue
        }

        $target = Find-TargetXmlForPatch -ExtractDir $ExtractDir -RelPosix $relPosix
        if ($null -eq $target) {
            Write-Warning "MISS: $($patch.Name) -> $relPosix"
            continue
        }

        $jobs.Add([pscustomobject]@{
            PatchPath = $patch.FullName
            PatchName = $patch.Name
            TargetXml = $target.FullPath
            RelWin    = $target.RelWin
            RelPosix  = $target.RelPosix
        })
    }

    Write-Info ("Matched patches: {0} / {1}" -f $jobs.Count, $patches.Count)
    if ($jobs.Count -eq 0) {
        throw 'No patches matched extracted XML files.'
    }

    foreach ($job in $jobs) {
        $destXml = Join-Path $patchWork $job.RelWin
        Ensure-Dir (Split-Path -Parent $destXml)
        Copy-Item -LiteralPath $job.TargetXml -Destination $destXml -Force
    }

    Push-Location $patchWork
    try {
        foreach ($job in $jobs) {
            $normPatch = Join-Path $patchWork ("_norm_{0}" -f $job.PatchName)
            Write-NormalizedPatch -SourcePatch $job.PatchPath -DestPatch $normPatch

            Write-Info "Applying patch: $($job.PatchName)"
            $out = & $GitExe apply -p1 --recount --reject --whitespace=nowarn --ignore-space-change --ignore-whitespace -- $normPatch 2>&1

            if ($LASTEXITCODE -ne 0) {
                $patchedWorkXml = Join-Path $patchWork $job.RelWin
                $fallbackOk = $false

                try {
                    $fallbackOk = Apply-XmlRowPatchFallback -TargetXmlPath $patchedWorkXml -PatchPath $job.PatchPath
                } catch {
                    $fallbackOk = $false
                }

                if (-not $fallbackOk) {
                    foreach ($line in @($out | Select-Object -First 10)) { Write-Info ([string]$line) }
                    throw "Patch apply failed for: $($job.PatchPath)"
                }
            }
        }
    }
    finally {
        Pop-Location -ErrorAction SilentlyContinue
    }

    foreach ($job in $jobs) {
        $patchedXml = Join-Path $patchWork $job.RelWin
        if (-not (Test-Path -LiteralPath $patchedXml -PathType Leaf)) {
            throw "Patched work XML missing: $patchedXml"
        }

        Copy-Item -LiteralPath $patchedXml -Destination $job.TargetXml -Force
    }

    return [pscustomobject]@{
        PatchCount = $patches.Count
        MatchCount = $jobs.Count
        AppliedCount = $jobs.Count
    }
}

function Invoke-GameParamRepackAttempt {
    param(
        [Parameter(Mandatory)][string]$ExtractDir,
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][int]$AttemptNumber
    )

    $beforeSize = if (Test-Path -LiteralPath $ArchivePath -PathType Leaf) { (Get-Item -LiteralPath $ArchivePath).Length } else { 0 }
    $beforeWrite = if (Test-Path -LiteralPath $ArchivePath -PathType Leaf) { (Get-Item -LiteralPath $ArchivePath).LastWriteTimeUtc } else { [datetime]::MinValue }

    Write-Stage ''
    Write-Stage ("Repack attempt {0}/{1}..." -f $AttemptNumber, $script:MaxRepackAttempts)

    Invoke-WitchyRepackGameParam `
        -Label "Repack gameparam with WitchyBND" `
        -TargetPath $ExtractDir `
        -StartupDelayMs $script:StartupDelayMs `
        -KeyDelayMs $script:KeyDelayMs `
        -StepDelayMs $script:StepDelayMs

    $afterItem = Get-Item -LiteralPath $ArchivePath
    $afterSize = $afterItem.Length
    $afterWrite = $afterItem.LastWriteTimeUtc
    $minBytes = [int64]$script:MinRepackedSizeKB * 1024

    Write-Info ("  Size before: {0:N0} bytes" -f $beforeSize)
    Write-Info ("  Size after : {0:N0} bytes" -f $afterSize)
    Write-Info ("  Min size   : {0:N0} bytes ({1} KB)" -f $minBytes, $script:MinRepackedSizeKB)

    return [pscustomobject]@{
        SizeBefore = $beforeSize
        SizeAfter  = $afterSize
        TimestampChanged = ($afterWrite -gt $beforeWrite)
        SizeOk = ($afterSize -gt $minBytes)
    }
}

function Remove-SafeWorkDir {
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

    $full = [System.IO.Path]::GetFullPath($Path)
    $outputFull = [System.IO.Path]::GetFullPath($script:OutputRoot)
    if (-not $full.StartsWith($outputFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove work directory outside OutputRoot: $full"
    }

    Remove-Item -LiteralPath $full -Recurse -Force
}

# -------------------- Main --------------------

Import-ToolConfig

if (-not $GameRoot) { $GameRoot = Get-OptionalVariableValue -Name 'BBR_GameRoot' }
if (-not $OutputRoot) { $OutputRoot = Get-OptionalVariableValue -Name 'BBR_OutputRoot' }
if (-not $WitchyBndExe) { $WitchyBndExe = Get-OptionalVariableValue -Name 'BBR_WitchyBND_v2_4_0_1' }
if (-not $GitExe) { $GitExe = Get-OptionalVariableValue -Name 'BBR_GitExe' }
if ($CpuThrottle -le 0) {
    $configuredCpuThrottle = Get-OptionalVariableValue -Name 'BBR_CpuThrottle'
    if ($configuredCpuThrottle) { $CpuThrottle = [int]$configuredCpuThrottle }
}
if ($GpuThrottle -le 0) {
    $configuredGpuThrottle = Get-OptionalVariableValue -Name 'BBR_GpuThrottle'
    if ($configuredGpuThrottle) { $GpuThrottle = [int]$configuredGpuThrottle }
}

$GameRoot = Resolve-GameRoot -Path $GameRoot
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$WitchyBndExe = Resolve-RequiredFile -Path $WitchyBndExe -Label 'WitchyBND v2.4.0.1 executable'
$GitExe = Resolve-RequiredFile -Path $GitExe -Label 'Git executable'
$PatchDir = Resolve-DefaultPatchDir

$script:OutputRoot = $OutputRoot
$script:WitchyBndExe = $WitchyBndExe
$script:MinRepackedSizeKB = $MinRepackedSizeKB
$script:MaxRepackAttempts = $MaxRepackAttempts
$script:StartupDelayMs = $StartupDelayMs
$script:KeyDelayMs = $KeyDelayMs
$script:StepDelayMs = $StepDelayMs

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

$sourceArchive = Resolve-GameArchive -GameRootPath $GameRoot -RelativeOrAbsolutePath $SourceArchiveRelativePath
$gparamOutputRoot = Join-Path $OutputRoot 'BBReborne_gparam'
$finalArchivePath = Join-Path $gparamOutputRoot $OutputRelativePath
$finalArchiveDir = Split-Path -Parent $finalArchivePath
Ensure-Dir $finalArchiveDir

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$workRoot = Join-Path $OutputRoot '_work'
$runWorkDir = Join-Path $workRoot "gparam_gameparam_$stamp"
$archiveWorkDir = Join-Path $runWorkDir 'archive'
Ensure-Dir $archiveWorkDir
$script:RunWorkDir = $runWorkDir

$workingArchivePath = Join-Path $archiveWorkDir (Split-Path -Leaf $sourceArchive.FullPath)
$extractDir = Get-WitchyExtractDir -ArchivePath $workingArchivePath

Write-Info "GameRoot      = $GameRoot"
Write-Info "OutputRoot    = $OutputRoot"
Write-Info "WitchyBND     = $WitchyBndExe"
Write-Info "GitExe        = $GitExe"
Write-Info "CpuThrottle   = $CpuThrottle"
Write-Info "GpuThrottle   = $GpuThrottle"
Write-Info "SourceArchive = $($sourceArchive.FullPath)"
Write-Info "PatchDir      = $PatchDir"
Write-Info "FinalArchive  = $finalArchivePath"
Write-Info "WorkDir       = $runWorkDir"
Write-Info "MinRepackSize = $MinRepackedSizeKB KB"

$overall = [System.Diagnostics.Stopwatch]::StartNew()
$completed = $false
$patchReport = $null
$repackReport = $null

try {
    Write-Stage ''
    Write-Stage '1/5 Copy source gameparam archive into isolated work folder...'
    Copy-Item -LiteralPath $sourceArchive.FullPath -Destination $workingArchivePath -Force

    Write-Stage ''
    Write-Stage '2/5 Extract copied gameparam archive with WitchyBND...'
    Invoke-WitchyExtractGameParam `
        -Label 'Extract gameparam with WitchyBND' `
        -TargetPath $workingArchivePath `
        -StartupDelayMs $StartupDelayMs `
        -KeyDelayMs $KeyDelayMs `
        -StepDelayMs $StepDelayMs

    Wait-ForExtractDir -ExtractDir $extractDir -TimeoutSeconds 30
    Write-Info "ExtractDir = $extractDir"

    Write-Stage ''
    Write-Stage '3/5 Apply gameparam XML patches...'
    $patchReport = Apply-GameParamPatches -PatchRoot $PatchDir -ExtractDir $extractDir -GitExe $GitExe
    Write-Info ("Patch summary: found={0}, matched={1}, applied={2}" -f $patchReport.PatchCount, $patchReport.MatchCount, $patchReport.AppliedCount)

    Write-Stage ''
    Write-Stage '4/5 Repack gameparam archive and verify size...'
    for ($attempt = 1; $attempt -le $MaxRepackAttempts; $attempt++) {
        $repackReport = Invoke-GameParamRepackAttempt -ExtractDir $extractDir -ArchivePath $workingArchivePath -AttemptNumber $attempt

        if ($repackReport.SizeOk) {
            Write-Info "Repack size check passed on attempt $attempt."
            break
        }

        if ($attempt -lt $MaxRepackAttempts) {
            Write-Warning ("Repacked archive is not larger than {0} KB. Repacking again..." -f $MinRepackedSizeKB)
            Start-Sleep -Seconds 1
        }
    }

    if (-not $repackReport.SizeOk) {
        throw ("Repacked archive is still not larger than {0} KB after {1} attempt(s). Final size: {2:N0} bytes" -f `
            $MinRepackedSizeKB, $MaxRepackAttempts, $repackReport.SizeAfter)
    }

    Write-Stage ''
    Write-Stage '5/5 Copy patched gameparam archive to output folder...'
    Copy-Item -LiteralPath $workingArchivePath -Destination $finalArchivePath -Force

    $finalInfo = Get-Item -LiteralPath $finalArchivePath
    $finalHash = (Get-FileHash -LiteralPath $finalArchivePath -Algorithm SHA256).Hash

    Write-Info "Patched archive written: $finalArchivePath"
    Write-Info ("Final size: {0:N0} bytes" -f $finalInfo.Length)
    Write-Info "Final SHA256: $finalHash"

    $completed = $true
}
finally {
    $overall.Stop()
    if ($completed -and -not $KeepWork) {
        try {
            Remove-SafeWorkDir -Path $runWorkDir
            Write-Info "Removed isolated work folder: $runWorkDir"
        } catch {
            Write-Warning $_.Exception.Message
        }
    } else {
        Write-Info "Kept work folder: $runWorkDir"
    }
}

Write-Stage ''
Write-Stage 'Done.'
Write-Info ('Elapsed: {0}' -f $overall.Elapsed)
