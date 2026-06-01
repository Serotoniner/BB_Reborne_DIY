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
    05_Global_BBReborne_Obj_FromDiffs.ps1

    Harmonized OBJ binder patch workflow for the BB Reborne DIY Tool.

    Purpose:
    - Read object FLVER JSON patch files from:
        <BBReborneDIYTool>\Diffs\obj\_patches
      or a custom -PatchDir.
    - Match each patch to an existing *.objbnd.dcx under the configured game folder.
    - Copy only the matched original object binders into an isolated work folder.
    - Decompress copied binders with WitchyBND.
    - Dump the object FLVERs to JSON paths expected by git apply -p1.
    - Apply all JSON patches.
    - Rebuild patched JSON back to FLVER.
    - Repack copied object binders.
    - Write final patched object binders under:
        <OutputRoot>\BBReborne_obj\<relative game path>

    Original game files are never modified. They are the backup.

    Expected config file from BBReborneDIYTool.ps1:
        <ToolRoot>\BBReborneDIYTool.paths.ps1

    Example direct run:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\05_Global_BBReborne_Obj_FromDiffs.ps1 `
            -ToolPathsPs1 "<BBReborneDIYTool>\Tools\BBReborneDIYTool.paths.ps1"

    Notes:
    - Uses WitchyBND v2.14.4.5 by default, unless -WitchyBndExe is supplied.
    - Uses FlverJsonTool from the DIY tool config.
    - Uses Git for patch application.
    - CpuThrottle controls JSON dump/rebuild parallelism by default.
    - GpuThrottle is accepted for launcher consistency, but this script does not use it internally.
#>

[CmdletBinding()]
param(
    [string]$ToolPathsPs1,
    [string]$GameRoot,
    [string]$OutputRoot,
    [string]$PatchDir,
    [string]$WitchyBndExe,
    [string]$FlverJsonToolExe,
    [string]$GitExe,
    [int]$CpuThrottle = 0,
    [int]$GpuThrottle = 0,

    [int]$WitchyBatchSize = 50,
    [int]$ThrottleLimit = 0,
    [switch]$RecurseOriginal,
    [switch]$DryRun,
    [switch]$KeepWork,

    [bool]$UseWitchySendKeys = $true,
    [string[]]$WitchyKeySequence1 = @('{DOWN}'),
    [string[]]$WitchyKeySequence2 = @('{DOWN}'),
    [string[]]$WitchyKeySequence3 = @('~'),
    [int]$WitchyStartupDelayMs = 1800,
    [int]$WitchyKeyDelayMs = 250,
    [int]$WitchyStepDelayMs = 700,
    [switch]$StrictWitchyExitCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:PSNativeCommandUseErrorActionPreference = $false
$global:PSNativeCommandArgumentPassing = 'Standard'
$script:WitchySendKeysLoaded = $false

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7+. Run it with pwsh.'
}

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

function Resolve-RequiredDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label is empty." }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Label not found: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-RequiredFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label is empty." }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label not found: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-OptionalVariableValue {
    param([Parameter(Mandatory)][string]$Name)
    $var = Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $var) { return $null }
    return $var.Value
}

function Get-FirstConfigValue {
    param([Parameter(Mandatory)][string[]]$Names)

    foreach ($name in $Names) {
        $value = Get-OptionalVariableValue -Name $name
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }

    return $null
}

function Resolve-OptionalConfigPath {
    if ($ToolPathsPs1) {
        return (Resolve-RequiredFile -Path $ToolPathsPs1 -Label 'Tool paths file')
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

        # Dot-sourcing from inside a function creates variables in that function scope.
        # Copy BBR_* variables back to script scope so standalone runs using only
        # -ToolPathsPs1 can resolve saved tool paths.
        . $configPath
        Get-Variable -Scope Local -Name 'BBR_*' -ErrorAction SilentlyContinue | ForEach-Object {
            Set-Variable -Name $_.Name -Value $_.Value -Scope Script
        }
    } else {
        Write-Info 'No tool config file found. Parameters must provide all required paths.'
    }
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

    $relative = 'Diffs\obj\_patches'
    foreach ($root in Get-DIYRootCandidates) {
        $candidate = Join-Path $root $relative
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Patch directory not found. Expected default path: <BBReborneDIYTool>\$relative"
}

function Format-Elapsed {
    param([Parameter(Mandatory)][TimeSpan]$Ts)
    if ($Ts.TotalHours -ge 1) { return ('{0:00}:{1:00}:{2:00}' -f [int]$Ts.TotalHours, $Ts.Minutes, $Ts.Seconds) }
    return ('{0:00}:{1:00}' -f $Ts.Minutes, $Ts.Seconds)
}

function ConvertTo-WindowsRelPath {
    param([Parameter(Mandatory)][string]$Path)
    return ($Path -replace '/', '\').TrimStart('\')
}

function Convert-ToGitPath {
    param([Parameter(Mandatory)][string]$Path)
    return (($Path -replace '\\', '/') -replace '^/+', '')
}

function Get-ObjBaseFromLeaf {
    param([Parameter(Mandatory)][string]$Leaf)
    $n = $Leaf
    foreach ($suffix in @('.objbnd.dcx', '.flver.json', '.flver', '.json', '.dcx')) {
        if ($n.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
            return $n.Substring(0, $n.Length - $suffix.Length)
        }
    }
    return [IO.Path]::GetFileNameWithoutExtension($n)
}

function Get-ObjFolderNameFromDcxLeaf {
    param([Parameter(Mandatory)][string]$DcxLeaf)
    return ($DcxLeaf -replace '\.', '-')
}

function Get-ExpectedObjFolderPath {
    param([Parameter(Mandatory)][string]$DcxPath)
    return (Join-Path (Split-Path -Parent $DcxPath) (Get-ObjFolderNameFromDcxLeaf (Split-Path -Leaf $DcxPath)))
}

function Get-ExpectedObjFlverPath {
    param([Parameter(Mandatory)][string]$DcxPath)
    $base = Get-ObjBaseFromLeaf (Split-Path -Leaf $DcxPath)
    return (Join-Path (Get-ExpectedObjFolderPath $DcxPath) ($base + '.flver'))
}

function Find-ObjFlverAfterWitchy {
    param([Parameter(Mandatory)][string]$DcxPath)

    $expected = Get-ExpectedObjFlverPath $DcxPath
    if (Test-Path -LiteralPath $expected -PathType Leaf) { return $expected }

    $folder = Get-ExpectedObjFolderPath $DcxPath
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return $null }

    $base = Get-ObjBaseFromLeaf (Split-Path -Leaf $DcxPath)
    $matches = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Filter '*.flver' -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -eq $base })

    if ($matches.Count -gt 0) { return $matches[0].FullName }

    $any = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Filter '*.flver' -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($any.Count -gt 0) { return $any[0].FullName }

    return $null
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0),
        [Parameter(Mandatory)][string]$Label
    )

    $out = @(& $Exe @Arguments 2>&1)
    $code = $LASTEXITCODE
    if ($AllowedExitCodes -notcontains $code) {
        foreach ($line in ($out | Select-Object -First 20)) { Write-Info ([string]$line) }
        throw "$Label failed with exit code $code."
    }
    return $out
}

function Initialize-WitchySendKeysSupport {
    $loadedVar = Get-Variable -Name 'WitchySendKeysLoaded' -Scope Script -ErrorAction SilentlyContinue
    if ($loadedVar -and [bool]$loadedVar.Value) { return }

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName Microsoft.VisualBasic | Out-Null
    $script:WitchySendKeysLoaded = $true
}

function Send-WitchyKeySequence {
    param(
        [Parameter(Mandatory)][string[]]$Keys,
        [int]$KeyDelayMs = 250
    )

    Initialize-WitchySendKeysSupport
    foreach ($key in $Keys) {
        [System.Windows.Forms.SendKeys]::SendWait($key)
        Start-Sleep -Milliseconds $KeyDelayMs
    }
}

function ConvertTo-WitchyArgumentText {
    param([Parameter(Mandatory=$true)][string[]]$Paths)

    return (($Paths | ForEach-Object {
        '"' + ($_ -replace '"', '\"') + '"'
    }) -join ' ')
}

function Invoke-WitchyBndBatchSendKeys {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string[]]$Paths,
        [Parameter(Mandatory=$true)][string]$LogFile,
        [Parameter(Mandatory=$true)][string[]]$KeySequence1,
        [Parameter(Mandatory=$true)][string[]]$KeySequence2,
        [Parameter(Mandatory=$true)][string[]]$KeySequence3,
        [int]$StartupDelayMs = 1800,
        [int]$KeyDelayMs = 250,
        [int]$StepDelayMs = 700
    )

    Initialize-WitchySendKeysSupport

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Targets: $($Paths.Count)")
    foreach ($p in $Paths) { $lines.Add("  $p") }
    $lines.Add("WitchyBND: $Exe")
    $lines.Add("Mode: one Start-Process batch + SendKeys")
    $lines.Add("KeySequence1: $($KeySequence1 -join ' ')")
    $lines.Add("KeySequence2: $($KeySequence2 -join ' ')")
    $lines.Add("KeySequence3: $($KeySequence3 -join ' ')")

    $proc = $null
    try {
        $argText = ConvertTo-WitchyArgumentText -Paths $Paths
        $lines.Add("ArgumentText: $argText")

        $proc = Start-Process `
            -FilePath $Exe `
            -ArgumentList $argText `
            -PassThru `
            -WindowStyle Normal

        $lines.Add("ProcessId: $($proc.Id)")
        Start-Sleep -Milliseconds $StartupDelayMs

        if (-not $proc.HasExited) {
            try {
                [void][Microsoft.VisualBasic.Interaction]::AppActivate($proc.Id)
                Start-Sleep -Milliseconds 300
            }
            catch {
                $lines.Add("AppActivate warning: $($_.Exception.Message)")
            }
        }

        if (-not $proc.HasExited -and $KeySequence1.Count -gt 0) {
            Send-WitchyKeySequence -Keys $KeySequence1 -KeyDelayMs $KeyDelayMs
            Start-Sleep -Milliseconds $StepDelayMs
        }
        if (-not $proc.HasExited -and $KeySequence2.Count -gt 0) {
            Send-WitchyKeySequence -Keys $KeySequence2 -KeyDelayMs $KeyDelayMs
            Start-Sleep -Milliseconds $StepDelayMs
        }
        if (-not $proc.HasExited -and $KeySequence3.Count -gt 0) {
            Send-WitchyKeySequence -Keys $KeySequence3 -KeyDelayMs $KeyDelayMs
        }

        if (-not $proc.HasExited) {
            $proc.WaitForExit()
        }

        $lines.Add("ExitCode: $($proc.ExitCode)")
        return $proc.ExitCode
    }
    catch {
        $lines.Add("Exception: $($_.Exception.Message)")
        return -9999
    }
    finally {
        $lines | Set-Content -LiteralPath $LogFile -Encoding UTF8
    }
}

function Invoke-WitchyBndBatchDirect {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$LogFile
    )

    try {
        $out = @(& $Exe @Paths 2>&1)
        $code = $LASTEXITCODE
    } catch {
        $out = @($_.Exception.Message)
        $code = -9999
    }

    $out | Set-Content -LiteralPath $LogFile -Encoding UTF8
    return $code
}

function Invoke-WitchyBndPathBatch {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][int]$BatchNumber,
        [Parameter(Mandatory)][string]$LogsDir,
        [bool]$UseSendKeys = $true,
        [string[]]$KeySequence1 = @('{DOWN}'),
        [string[]]$KeySequence2 = @('{DOWN}'),
        [string[]]$KeySequence3 = @('~'),
        [int]$StartupDelayMs = 1800,
        [int]$KeyDelayMs = 250,
        [int]$StepDelayMs = 700
    )

    Ensure-Dir $LogsDir
    $safePhase = ($Phase -replace '[^A-Za-z0-9_-]', '_')
    $logFile = Join-Path $LogsDir ("witchybnd_{0}_{1:0000}.log.txt" -f $safePhase, $BatchNumber)

    if ($UseSendKeys) {
        return Invoke-WitchyBndBatchSendKeys `
            -Exe $Exe `
            -Paths $Paths `
            -LogFile $logFile `
            -KeySequence1 $KeySequence1 `
            -KeySequence2 $KeySequence2 `
            -KeySequence3 $KeySequence3 `
            -StartupDelayMs $StartupDelayMs `
            -KeyDelayMs $KeyDelayMs `
            -StepDelayMs $StepDelayMs
    }

    return Invoke-WitchyBndBatchDirect -Exe $Exe -Paths $Paths -LogFile $logFile
}

function Get-APathFromPatchHeader {
    param([Parameter(Mandatory)][string]$PatchPath)
    $first = Get-Content -LiteralPath $PatchPath -TotalCount 1
    if (-not $first) { return $null }

    $m = [regex]::Match($first, '^diff --git\s+("([^"]+)"|(\S+))\s+("([^"]+)"|(\S+))\s*$')
    if (-not $m.Success) { return $null }
    if ($m.Groups[2].Success) { return $m.Groups[2].Value }
    return $m.Groups[3].Value
}

function Get-RelAfterP1PosixFromPatch {
    param([Parameter(Mandatory)][string]$PatchPath)

    $aToken = Get-APathFromPatchHeader $PatchPath
    if (-not $aToken) { return $null }

    $aToken = $aToken -replace '\\', '/'
    if ($aToken.StartsWith('a/')) { $aToken = $aToken.Substring(2) }
    if ($aToken.StartsWith('a/')) { $aToken = $aToken.Substring(2) }
    while ($aToken -match '//') { $aToken = $aToken -replace '//', '/' }
    return $aToken.TrimStart('/')
}

function Write-NormalizedPatch {
    param(
        [Parameter(Mandatory)][string]$SrcPatch,
        [Parameter(Mandatory)][string]$DstPatch
    )

    $lines = Get-Content -LiteralPath $SrcPatch
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        if ($ln -match '^(diff --git|--- |\+\+\+ )') {
            $ln = $ln -replace '\\', '/'
            $ln = $ln -replace '("a/)a/', '$1'
            $ln = $ln -replace '("b/)b/', '$1'
            $ln = $ln -replace '(\sa/)a/', '$1'
            $ln = $ln -replace '(\sb/)b/', '$1'
            while ($ln -match '//') { $ln = $ln -replace '//', '/' }
        }
        $lines[$i] = $ln
    }
    Set-Content -LiteralPath $DstPatch -Value $lines -Encoding UTF8
}

function Get-ObjectBaseFromJsonRel {
    param([Parameter(Mandatory)][string]$JsonRelPosix)
    $leaf = Split-Path -Leaf (ConvertTo-WindowsRelPath $JsonRelPosix)
    return Get-ObjBaseFromLeaf $leaf
}

function Get-DcxRelFromJsonRel {
    param([Parameter(Mandatory)][string]$JsonRelPosix)

    $rel = $JsonRelPosix
    if ($rel.EndsWith('.flver.json', [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $rel.Substring(0, $rel.Length - 11) + '.objbnd.dcx'
    } elseif ($rel.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $rel.Substring(0, $rel.Length - 5) + '.objbnd.dcx'
    } else {
        $base = Get-ObjectBaseFromJsonRel $rel
        $dir = Split-Path -Parent (ConvertTo-WindowsRelPath $rel)
        if ([string]::IsNullOrWhiteSpace($dir)) { return ($base + '.objbnd.dcx') }
        return (Join-Path $dir ($base + '.objbnd.dcx'))
    }

    return ConvertTo-WindowsRelPath $rel
}

function Remove-SafeWorkDir {
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

    $full = [IO.Path]::GetFullPath($Path)
    $outputFull = [IO.Path]::GetFullPath($script:OutputRoot)
    if (-not $full.StartsWith($outputFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove work directory outside OutputRoot: $full"
    }

    Remove-Item -LiteralPath $full -Recurse -Force
}

# -------------------- Main --------------------

Import-ToolConfig

if (-not $GameRoot) {
    $GameRoot = Get-FirstConfigValue -Names @(
        'BBR_GameRoot',
        'BBR_GameFolder',
        'BBR_GameFolderPath',
        'BBR_GamePath',
        'BBR_DvdRootPs4',
        'BBR_DvdRootPS4'
    )
}
if (-not $OutputRoot) {
    $OutputRoot = Get-FirstConfigValue -Names @(
        'BBR_OutputRoot',
        'BBR_OutputFolder',
        'BBR_OutputFolderPath',
        'BBR_ModdedFilesRoot',
        'BBR_ModdedOutputRoot'
    )
}
if (-not $WitchyBndExe) {
    $WitchyBndExe = Get-FirstConfigValue -Names @(
        'BBR_WitchyBND_v2_14_4_5',
        'BBR_WitchyBnd_v2_14_4_5',
        'BBR_WitchyBND_v21445',
        'BBR_WitchyBND_21445'
    )
}
if (-not $FlverJsonToolExe) {
    $FlverJsonToolExe = Get-FirstConfigValue -Names @(
        'BBR_FlverJsonToolExe',
        'BBR_FLVERJsonToolExe'
    )
}
if (-not $GitExe) {
    $GitExe = Get-FirstConfigValue -Names @(
        'BBR_GitExe',
        'BBR_GitForWindowsExe'
    )
}
if (-not $GitExe) {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { $GitExe = $cmd.Source }
}
if ($CpuThrottle -le 0) {
    $configuredCpuThrottle = Get-OptionalVariableValue -Name 'BBR_CpuThrottle'
    if ($configuredCpuThrottle) { $CpuThrottle = [int]$configuredCpuThrottle }
}
if ($GpuThrottle -le 0) {
    $configuredGpuThrottle = Get-OptionalVariableValue -Name 'BBR_GpuThrottle'
    if ($configuredGpuThrottle) { $GpuThrottle = [int]$configuredGpuThrottle }
}

$GameRoot = Resolve-GameRoot -Path $GameRoot
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$PatchDir = Resolve-DefaultPatchDir
$WitchyBndExe = Resolve-RequiredFile -Path $WitchyBndExe -Label 'WitchyBND executable'
$FlverJsonToolExe = Resolve-RequiredFile -Path $FlverJsonToolExe -Label 'FlverJsonTool executable'
$GitExe = Resolve-RequiredFile -Path $GitExe -Label 'Git executable'

if ($WitchyBatchSize -lt 1) { $WitchyBatchSize = 1 }
if ($ThrottleLimit -le 0) { $ThrottleLimit = if ($CpuThrottle -gt 0) { $CpuThrottle } else { [Math]::Max(1, [Math]::Min(6, [int]([Environment]::ProcessorCount / 4))) } }
if ($ThrottleLimit -lt 1) { $ThrottleLimit = 1 }

$script:OutputRoot = $OutputRoot
$scriptSw = [Diagnostics.Stopwatch]::StartNew()
$success = $false
$hadFailure = $false
$runWorkDir = $null

try {
    Invoke-NativeChecked -Exe $GitExe -Arguments @('--version') -AllowedExitCodes @(0) -Label 'git --version' | Out-Null

    $patchInputRoot = [IO.Path]::GetFullPath($PatchDir)
    $origRoot = [IO.Path]::GetFullPath($GameRoot)

    $objectsSubdir = Join-Path $patchInputRoot 'objects'
    if (Test-Path -LiteralPath $objectsSubdir -PathType Container) {
        $patchFilesRoot = $objectsSubdir
    } elseif ([IO.Path]::GetFileName($patchInputRoot).Equals('objects', [StringComparison]::OrdinalIgnoreCase)) {
        $patchFilesRoot = $patchInputRoot
    } else {
        $patchFilesRoot = $patchInputRoot
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $runWorkDir = Join-Path (Join-Path $OutputRoot '_work') "obj_from_diffs_$stamp"
    $workRoot = Join-Path $runWorkDir 'patch_apply_work'
    $workDcxRoot = Join-Path $workRoot 'dcx'
    $logsDir = Join-Path $workRoot 'logs'
    $normPatchDir = Join-Path $workRoot 'normalized_patches'
    $objOutputRoot = Join-Path $OutputRoot 'BBReborne_obj'

    Write-Info "GameRoot        = $GameRoot"
    Write-Info "OutputRoot      = $OutputRoot"
    Write-Info "PatchDir        = $PatchDir"
    Write-Info "PatchFilesRoot  = $patchFilesRoot"
    Write-Info "WitchyBND       = $WitchyBndExe"
    Write-Info "FlverJsonTool   = $FlverJsonToolExe"
    Write-Info "GitExe          = $GitExe"
    Write-Info "CpuThrottle     = $CpuThrottle"
    Write-Info "GpuThrottle     = $GpuThrottle"
    Write-Info "ThrottleLimit   = $ThrottleLimit"
    Write-Info "WitchyBatchSize = $WitchyBatchSize"
    Write-Info "OutputObjRoot   = $objOutputRoot"
    Write-Info "WorkRoot        = $workRoot"

    if (-not $DryRun) {
        foreach ($d in @($workDcxRoot, $logsDir, $normPatchDir, $objOutputRoot)) { Ensure-Dir $d }
    }

    Write-Stage ''
    Write-Stage 'Stage #0: Match patches -> original .objbnd.dcx...'

    $patches = @(Get-ChildItem -LiteralPath $patchFilesRoot -File -Filter '*.patch' |
        Where-Object { $_.Length -gt 0 -and $_.Name -ne 'all_changed_flver_json.patch' } |
        Sort-Object Name)

    Write-Info ("  Found {0} non-empty per-object patch file(s)." -f $patches.Count)
    if ($patches.Count -eq 0) {
        Write-Info 'Nothing to do.'
        $success = $true
        return
    }

    $origByBase = @{}
    if ($RecurseOriginal -or $true) {
        $allOrig = @(Get-ChildItem -LiteralPath $origRoot -File -Filter '*.objbnd.dcx' -Recurse | Sort-Object FullName)
        foreach ($f in $allOrig) {
            $b = Get-ObjBaseFromLeaf $f.Name
            if (-not $origByBase.ContainsKey($b)) { $origByBase[$b] = $f.FullName }
        }
        Write-Info ("  Scanned originals: {0} object binder(s)." -f $allOrig.Count)
    }

    $jobs = [System.Collections.Generic.List[object]]::new()
    $skips = [System.Collections.Generic.List[object]]::new()

    foreach ($pf in $patches) {
        $jsonRelPosix = Get-RelAfterP1PosixFromPatch $pf.FullName
        if ([string]::IsNullOrWhiteSpace($jsonRelPosix)) {
            [void]$skips.Add([pscustomobject]@{ Patch=$pf.FullName; Reason='Could not parse diff --git header' })
            Write-Warning ("  SKIP: {0} (could not parse diff --git header)" -f $pf.Name)
            continue
        }

        $baseName = Get-ObjectBaseFromJsonRel $jsonRelPosix
        $dcxRelWin = Get-DcxRelFromJsonRel $jsonRelPosix
        $origDcx = $null

        $candidate = Join-Path $origRoot $dcxRelWin
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $origDcx = $candidate }

        if (-not $origDcx -and $origByBase.ContainsKey($baseName)) {
            $origDcx = $origByBase[$baseName]
            $dcxRelWin = [IO.Path]::GetRelativePath($origRoot, $origDcx)
        }

        if (-not $origDcx) {
            [void]$skips.Add([pscustomobject]@{ Patch=$pf.FullName; Reason="Could not match to existing objbnd.dcx: $dcxRelWin" })
            Write-Warning ("  MISS: {0} -> {1}" -f $pf.Name, $dcxRelWin)
            continue
        }

        $workDcx = Join-Path $workDcxRoot $dcxRelWin
        $jsonRelWin = ConvertTo-WindowsRelPath $jsonRelPosix
        $jsonPath = Join-Path $workRoot $jsonRelWin
        $finalDcx = Join-Path $objOutputRoot $dcxRelWin

        [void]$jobs.Add([pscustomobject]@{
            PatchPath    = $pf.FullName
            PatchName    = $pf.Name
            ObjectBase   = $baseName
            JsonRelPosix = $jsonRelPosix
            JsonRelWin   = $jsonRelWin
            JsonPath     = $jsonPath
            DcxRelWin    = $dcxRelWin
            OrigDcx      = $origDcx
            WorkDcx      = $workDcx
            WorkFolder   = Get-ExpectedObjFolderPath $workDcx
            WorkFlver    = Get-ExpectedObjFlverPath $workDcx
            NormPatch    = Join-Path $normPatchDir $pf.Name
            FinalDcx     = $finalDcx
        })
    }

    Write-Info ("  Matched patches: {0} / {1}" -f $jobs.Count, $patches.Count)
    if ($skips.Count -gt 0) {
        $skipCsv = Join-Path $workRoot 'skipped_patches.csv'
        if (-not $DryRun) { $skips | Export-Csv -LiteralPath $skipCsv -NoTypeInformation -Encoding UTF8 }
        Write-Warning ("  Skipped/missed patches: {0}" -f $skips.Count)
    }

    if ($jobs.Count -eq 0) {
        Write-Info 'No matched object binders; stopping.'
        $success = $true
        return
    }

    Write-Stage ''
    Write-Stage 'Stage #1: Copy original object binders into isolated work folder...'
    foreach ($j in $jobs) {
        if ($DryRun) {
            Write-Info ("  DRY: copy {0} -> {1}" -f $j.OrigDcx, $j.WorkDcx)
            continue
        }
        Ensure-Dir (Split-Path -Parent $j.WorkDcx)
        Copy-Item -LiteralPath $j.OrigDcx -Destination $j.WorkDcx -Force
    }

    Write-Stage ''
    Write-Stage ("Stage #2: Decompress OBJ binder copies with WitchyBND (batchSize={0})..." -f $WitchyBatchSize)
    $dcxList = @($jobs | ForEach-Object { $_.WorkDcx })
    for ($start = 0; $start -lt $dcxList.Count; $start += $WitchyBatchSize) {
        $end = [Math]::Min($start + $WitchyBatchSize, $dcxList.Count)
        $batch = @($dcxList[$start..($end-1)])
        $idx = [int]([Math]::Floor($start / $WitchyBatchSize) + 1)
        Write-Info ("  Batch {0}: files {1}-{2} ({3} file(s))" -f $idx, ($start+1), $end, $batch.Count)

        if (-not $DryRun) {
            $code = Invoke-WitchyBndPathBatch `
                -Exe $WitchyBndExe `
                -Paths $batch `
                -Phase 'decompress' `
                -BatchNumber $idx `
                -LogsDir $logsDir `
                -UseSendKeys $UseWitchySendKeys `
                -KeySequence1 $WitchyKeySequence1 `
                -KeySequence2 $WitchyKeySequence2 `
                -KeySequence3 $WitchyKeySequence3 `
                -StartupDelayMs $WitchyStartupDelayMs `
                -KeyDelayMs $WitchyKeyDelayMs `
                -StepDelayMs $WitchyStepDelayMs

            $missing = @()
            foreach ($dcx in $batch) {
                if ([string]::IsNullOrWhiteSpace((Find-ObjFlverAfterWitchy $dcx))) { $missing += $dcx }
            }
            if ($StrictWitchyExitCode -and $code -ne 0) { throw "WitchyBND decompress batch $idx failed with exit code $code." }
            if ($missing.Count -gt 0) { throw "Aborting: WitchyBND did not produce expected object FLVER(s). First missing: $($missing[0])" }
            if ($code -ne 0) { Write-Warning ("  WitchyBND exit code {0} tolerated because expected FLVERs exist." -f $code) }
        }
    }

    if (-not $DryRun) {
        foreach ($j in $jobs) {
            $found = Find-ObjFlverAfterWitchy $j.WorkDcx
            if (-not [string]::IsNullOrWhiteSpace($found) -and $found -ne $j.WorkFlver) { $j.WorkFlver = $found }
        }
    }

    Write-Stage ''
    Write-Stage ("Stage #3: Dump JSON in parallel (ThrottleLimit={0})..." -f $ThrottleLimit)
    $dumpJobs = @($jobs | ForEach-Object { [pscustomobject]@{ Flv=$_.WorkFlver; Json=$_.JsonPath } })
    if ($DryRun) {
        $dumpJobs | ForEach-Object { Write-Info ("  DRY: dump {0} -> {1}" -f $_.Flv, $_.Json) }
    } else {
        $dumpResults = $dumpJobs | ForEach-Object -Parallel {
            try {
                $exe = $using:FlverJsonToolExe
                if (-not (Test-Path -LiteralPath $_.Flv -PathType Leaf)) { return [pscustomobject]@{ Ok=$false; Json=$_.Json; Error="Missing FLVER: $($_.Flv)" } }
                $jsonDir = Split-Path -Parent $_.Json
                if (-not (Test-Path -LiteralPath $jsonDir -PathType Container)) { New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null }
                & $exe dump $_.Flv $_.Json | Out-Null
                if (Test-Path -LiteralPath $_.Json -PathType Leaf) { return [pscustomobject]@{ Ok=$true; Json=$_.Json; Error='' } }
                return [pscustomobject]@{ Ok=$false; Json=$_.Json; Error='JSON not produced' }
            } catch {
                return [pscustomobject]@{ Ok=$false; Json=$_.Json; Error=$_.Exception.Message }
            }
        } -ThrottleLimit $ThrottleLimit

        $dumpResults | Export-Csv -LiteralPath (Join-Path $workRoot 'dump_results.csv') -NoTypeInformation -Encoding UTF8
        $failDump = @($dumpResults | Where-Object { -not $_.Ok })
        Write-Info ("Stage #3 done. OK={0}  Failed={1}" -f (@($dumpResults | Where-Object Ok).Count), $failDump.Count)
        if ($failDump.Count -gt 0) { throw "Aborting: JSON dump failures occurred. First: $($failDump[0].Error)" }
    }

    Write-Stage ''
    Write-Stage 'Stage #4: Apply patches with git apply -p1...'
    if ($DryRun) {
        foreach ($j in $jobs) { Write-Info ("  DRY: git apply -p1 {0}" -f $j.PatchPath) }
    } else {
        Get-ChildItem -LiteralPath $workRoot -Filter '*.rej' -File -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Push-Location -LiteralPath $workRoot
        try {
            foreach ($j in $jobs) {
                Write-NormalizedPatch -SrcPatch $j.PatchPath -DstPatch $j.NormPatch
                $out = @(& $GitExe apply -p1 --3way --recount --whitespace=nowarn -- $j.NormPatch 2>&1)
                if ($LASTEXITCODE -eq 0) {
                    Write-Info ("  OK: {0}" -f $j.PatchName)
                    continue
                }

                $out2 = @(& $GitExe apply -p1 --recount --reject --whitespace=nowarn -- $j.NormPatch 2>&1)
                $fallbackCode = $LASTEXITCODE
                $rejects = @(Get-ChildItem -LiteralPath $workRoot -Filter '*.rej' -File -Recurse -ErrorAction SilentlyContinue)

                if ($rejects.Count -eq 0 -and $fallbackCode -eq 0) {
                    Write-Info ("  OK: {0} (fallback apply; no reject files)" -f $j.PatchName)
                    continue
                }

                foreach ($line in (@($out) + @($out2) | Select-Object -First 20)) { Write-Info ([string]$line) }
                throw "Patch apply failed for: $($j.PatchName)"
            }
        } finally {
            Pop-Location -ErrorAction SilentlyContinue
        }
    }

    Write-Stage ''
    Write-Stage ("Stage #5: Rebuild FLVER in parallel (ThrottleLimit={0})..." -f $ThrottleLimit)
    $rebuildJobs = @($jobs | ForEach-Object { [pscustomobject]@{ Json=$_.JsonPath; Flv=$_.WorkFlver } })
    if ($DryRun) {
        $rebuildJobs | ForEach-Object { Write-Info ("  DRY: rebuild {0} -> {1}" -f $_.Json, $_.Flv) }
    } else {
        $rebuildResults = $rebuildJobs | ForEach-Object -Parallel {
            try {
                $exe = $using:FlverJsonToolExe
                if (-not (Test-Path -LiteralPath $_.Json -PathType Leaf)) { return [pscustomobject]@{ Ok=$false; Flv=$_.Flv; Error="Missing JSON: $($_.Json)" } }
                & $exe rebuild $_.Json $_.Flv | Out-Null
                if (Test-Path -LiteralPath $_.Flv -PathType Leaf) { return [pscustomobject]@{ Ok=$true; Flv=$_.Flv; Error='' } }
                return [pscustomobject]@{ Ok=$false; Flv=$_.Flv; Error='FLVER not produced' }
            } catch {
                return [pscustomobject]@{ Ok=$false; Flv=$_.Flv; Error=$_.Exception.Message }
            }
        } -ThrottleLimit $ThrottleLimit

        $rebuildResults | Export-Csv -LiteralPath (Join-Path $workRoot 'rebuild_results.csv') -NoTypeInformation -Encoding UTF8
        $failRebuild = @($rebuildResults | Where-Object { -not $_.Ok })
        Write-Info ("Stage #5 done. OK={0}  Failed={1}" -f (@($rebuildResults | Where-Object Ok).Count), $failRebuild.Count)
        if ($failRebuild.Count -gt 0) { throw "Aborting: rebuild failures occurred. First: $($failRebuild[0].Error)" }
    }

    Write-Stage ''
    Write-Stage ("Stage #6: Pack object folders back to OBJ binder DCX (batchSize={0})..." -f $WitchyBatchSize)
    $folderList = @($jobs | ForEach-Object { $_.WorkFolder })
    if (-not $DryRun) {
        foreach ($j in $jobs) {
            if (-not (Test-Path -LiteralPath $j.WorkFolder -PathType Container)) { throw "Missing object folder before repack: $($j.WorkFolder)" }
            if (Test-Path -LiteralPath $j.WorkDcx -PathType Leaf) { Remove-Item -LiteralPath $j.WorkDcx -Force }
        }
    }

    for ($start = 0; $start -lt $folderList.Count; $start += $WitchyBatchSize) {
        $end = [Math]::Min($start + $WitchyBatchSize, $folderList.Count)
        $batch = @($folderList[$start..($end-1)])
        $idx = [int]([Math]::Floor($start / $WitchyBatchSize) + 1)
        Write-Info ("  Batch {0}: folders {1}-{2} ({3} folder(s))" -f $idx, ($start+1), $end, $batch.Count)

        if (-not $DryRun) {
            $code = Invoke-WitchyBndPathBatch `
                -Exe $WitchyBndExe `
                -Paths $batch `
                -Phase 'repack' `
                -BatchNumber $idx `
                -LogsDir $logsDir `
                -UseSendKeys $UseWitchySendKeys `
                -KeySequence1 $WitchyKeySequence1 `
                -KeySequence2 $WitchyKeySequence2 `
                -KeySequence3 $WitchyKeySequence3 `
                -StartupDelayMs $WitchyStartupDelayMs `
                -KeyDelayMs $WitchyKeyDelayMs `
                -StepDelayMs $WitchyStepDelayMs

            $missingOut = @()
            foreach ($j in @($jobs | Where-Object { $batch -contains $_.WorkFolder })) {
                if (-not (Test-Path -LiteralPath $j.WorkDcx -PathType Leaf)) { $missingOut += $j.WorkDcx }
            }
            if ($StrictWitchyExitCode -and $code -ne 0) { throw "WitchyBND repack batch $idx failed with exit code $code." }
            if ($missingOut.Count -gt 0) { throw "Aborting: WitchyBND did not produce expected objbnd.dcx file(s). First missing: $($missingOut[0])" }
            if ($code -ne 0) { Write-Warning ("  WitchyBND exit code {0} tolerated because expected DCX files exist." -f $code) }
        }
    }

    Write-Stage ''
    Write-Stage 'Stage #7: Copy patched object binders to BBReborne_obj output folder...'
    foreach ($j in $jobs) {
        if ($DryRun) {
            Write-Info ("  DRY: output {0} <= {1}" -f $j.FinalDcx, $j.WorkDcx)
            continue
        }
        if (-not (Test-Path -LiteralPath $j.WorkDcx -PathType Leaf)) { throw "Missing final repacked DCX: $($j.WorkDcx)" }
        Ensure-Dir (Split-Path -Parent $j.FinalDcx)
        Copy-Item -LiteralPath $j.WorkDcx -Destination $j.FinalDcx -Force
        Write-Info "  Wrote: $($j.FinalDcx)"
    }

    $finalCount = @($jobs | Where-Object { Test-Path -LiteralPath $_.FinalDcx -PathType Leaf }).Count
    Write-Info "All object patches applied. Output files: $finalCount"
    $success = $true
} catch {
    $hadFailure = $true
    Write-Error $_.Exception.Message
    throw
} finally {
    Write-Stage ''
    Write-Stage 'Stage #8: Cleanup...'
    if ([string]::IsNullOrWhiteSpace($runWorkDir)) {
        Write-Info '  Work folder was not initialized.'
    } elseif ($DryRun) {
        Write-Info "  DRY: would remove work folder: $runWorkDir"
    } elseif ($KeepWork -or $hadFailure -or (-not $success)) {
        Write-Info "  Keeping work folder: $runWorkDir"
        if ($hadFailure -or (-not $success)) { Write-Warning '  Kept because the run did not complete cleanly.' }
    } else {
        try {
            Remove-SafeWorkDir -Path $runWorkDir
            Write-Info "  Removed: $runWorkDir"
        } catch {
            Write-Warning $_.Exception.Message
        }
    }

    Write-Info ("Elapsed: {0}" -f (Format-Elapsed $scriptSw.Elapsed))
}
