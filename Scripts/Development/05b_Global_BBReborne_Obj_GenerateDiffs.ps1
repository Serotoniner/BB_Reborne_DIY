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
    05_Global_BBReborne_Obj_GenerateDiffs.ps1

    Development/reference helper for generating OBJ FLVER JSON patches used by:
        05_Global_BBReborne_Obj_FromDiffs.ps1

    Intended save path:
        <BBReborneDIYTool>\Scripts\Development\05_Global_BBReborne_Obj_GenerateDiffs.ps1

    Purpose:
    - Compare original *.objbnd.dcx files from the configured game folder against changed object binders.
    - Default changed object binder root:
        <OutputRoot>\BBReborne_obj
    - Copy only changed/added/removed binders into an isolated temp work folder.
    - Extract copied binders with WitchyBND.
    - Dump contained object FLVER files to JSON with FlverJsonTool.
    - Export portable Git patch files to:
        <BBReborneDIYTool>\Diffs\obj\_patches

    This script is for development/reference only and is not intended to be called by the DIY Tool UI.

    Original game files and changed input files are never modified.
    The script cleans only its own temp work folder under the system temp directory.

    Example:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\05_Global_BBReborne_Obj_GenerateDiffs.ps1 `
            -ToolPathsPs1 "<BBReborneDIYTool>\Tools\BBReborneDIYTool.paths.ps1"

    Notes:
    - If WitchyBND version is not supplied, this script defaults to BBR_WitchyBND_v2_14_4_5.
    - CpuThrottle controls JSON dump parallelism unless -DumpThrottle is supplied.
    - GpuThrottle is accepted for launcher consistency but is not used internally.
#>

[CmdletBinding()]
param(
    [string]$ToolPathsPs1,
    [string]$GameRoot,
    [string]$OutputRoot,
    [string]$ChangedObjRoot,
    [string]$PatchOutDir,
    [string]$WitchyBND,
    [string]$FlverTool,
    [string]$GitExe,
    [int]$CpuThrottle = 0,
    [int]$GpuThrottle = 0,

    [bool]$Recurse = $true,
    [switch]$DryRun,
    [switch]$KeepWork,

    [string]$IncludeRegex = '',
    [int]$MaxObjects = 0,
    [int]$StartAt = 0,

    [ValidateSet('SHA256','SHA1','MD5')]
    [string]$HashAlgorithm = 'SHA256',

    [int]$WitchyBatchSize = 50,
    [bool]$UseWitchySendKeys = $true,
    [string[]]$WitchyKeySequence1 = @('{DOWN}'),
    [string[]]$WitchyKeySequence2 = @('{DOWN}'),
    [string[]]$WitchyKeySequence3 = @('~'),
    [int]$WitchyStartupDelayMs = 1800,
    [int]$WitchyKeyDelayMs = 250,
    [int]$WitchyStepDelayMs = 700,
    [switch]$StrictWitchyExitCode,

    [int]$DumpThrottle = 0
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
    if ([string]::IsNullOrWhiteSpace($Message)) { Write-Host ''; return }
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

function Resolve-DefaultPatchOutDir {
    if ($PatchOutDir) {
        Ensure-Dir $PatchOutDir
        return ([IO.Path]::GetFullPath($PatchOutDir))
    }

    $relative = 'Diffs\obj\_patches'
    foreach ($root in Get-DIYRootCandidates) {
        $candidate = Join-Path $root $relative
        $diffRoot = Split-Path -Parent (Split-Path -Parent $candidate)
        if (Test-Path -LiteralPath $diffRoot -PathType Container) {
            Ensure-Dir $candidate
            return ([IO.Path]::GetFullPath($candidate))
        }
    }

    if ($PSScriptRoot) {
        $fallbackRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        if ($fallbackRoot) {
            $candidate = Join-Path $fallbackRoot $relative
            Ensure-Dir $candidate
            return ([IO.Path]::GetFullPath($candidate))
        }
    }

    throw 'Could not determine default OBJ patch output directory. Use -PatchOutDir explicitly.'
}

function Get-RelPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Full
    )

    $rootN = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $fullN = [IO.Path]::GetFullPath($Full)
    if (-not $fullN.StartsWith($rootN, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is not under root. Root='$rootN' Full='$fullN'"
    }
    return $fullN.Substring($rootN.Length)
}

function Format-Elapsed {
    param([Parameter(Mandatory)][TimeSpan]$Ts)
    if ($Ts.TotalHours -ge 1) { return ('{0:00}:{1:00}:{2:00}' -f [int]$Ts.TotalHours, $Ts.Minutes, $Ts.Seconds) }
    return ('{0:00}:{1:00}' -f $Ts.Minutes, $Ts.Seconds)
}

function Get-PatchLeafForJsonRel {
    param([Parameter(Mandatory)][string]$JsonRel)
    $leaf = ($JsonRel -replace '[\/]+', '__')
    $leaf = ($leaf -replace '\.flver\.json$', '.patch')
    if (-not $leaf.EndsWith('.patch', [StringComparison]::OrdinalIgnoreCase)) { $leaf = $leaf + '.patch' }
    return $leaf
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

function Get-FileHashText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Algorithm
    )
    return (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLowerInvariant()
}

function Get-ObjectIndex {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][bool]$DoRecurse,
        [AllowNull()][string]$RegexText
    )

    $gciParams = @{
        LiteralPath = $Root
        Filter      = '*.objbnd.dcx'
        File        = $true
    }
    if ($DoRecurse) { $gciParams.Recurse = $true }

    $files = @(Get-ChildItem @gciParams | Sort-Object FullName)

    if (-not [string]::IsNullOrWhiteSpace($RegexText)) {
        $re = [regex]::new($RegexText, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $files = @($files | Where-Object { $re.IsMatch($_.Name) -or $re.IsMatch($_.FullName) })
    }

    $map = @{}
    foreach ($f in $files) {
        $rel = Get-RelPath -Root $Root -Full $f.FullName
        $key = $rel.ToLowerInvariant()
        $map[$key] = [pscustomobject]@{
            Rel      = $rel
            FullName = $f.FullName
            Name     = $f.Name
            Length   = [int64]$f.Length
        }
    }

    return $map
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
        [Parameter(Mandatory=$true)][string[]]$DcxPaths,
        [Parameter(Mandatory=$true)][string]$LogFile,
        [string[]]$KeySequence1 = @('{DOWN}'),
        [string[]]$KeySequence2 = @('{DOWN}'),
        [string[]]$KeySequence3 = @('~'),
        [int]$StartupDelayMs = 1800,
        [int]$KeyDelayMs = 250,
        [int]$StepDelayMs = 700
    )

    Initialize-WitchySendKeysSupport

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Targets: $($DcxPaths.Count)")
    foreach ($p in $DcxPaths) { $lines.Add("  $p") }
    $lines.Add("WitchyBND: $Exe")
    $lines.Add("Mode: one Start-Process batch + SendKeys")
    $lines.Add("KeySequence1: $($KeySequence1 -join ' ')")
    $lines.Add("KeySequence2: $($KeySequence2 -join ' ')")
    $lines.Add("KeySequence3: $($KeySequence3 -join ' ')")

    $proc = $null
    try {
        $argText = ConvertTo-WitchyArgumentText -Paths $DcxPaths
        $lines.Add("ArgumentText: $argText")

        # Keep WitchyBND launch style identical to the original working OBJ generator.
        $proc = Start-Process `
            -FilePath $Exe `
            -ArgumentList $argText `
            -PassThru `
            -WindowStyle Normal

        $lines.Add("ProcessId: $($proc.Id)")
        Start-Sleep -Milliseconds $StartupDelayMs

        try {
            [void][Microsoft.VisualBasic.Interaction]::AppActivate($proc.Id)
            Start-Sleep -Milliseconds 300
        }
        catch {
            $lines.Add("AppActivate warning: $($_.Exception.Message)")
        }

        if ($KeySequence1.Count -gt 0) {
            Send-WitchyKeySequence -Keys $KeySequence1 -KeyDelayMs $KeyDelayMs
            Start-Sleep -Milliseconds $StepDelayMs
        }
        if ($KeySequence2.Count -gt 0) {
            Send-WitchyKeySequence -Keys $KeySequence2 -KeyDelayMs $KeyDelayMs
            Start-Sleep -Milliseconds $StepDelayMs
        }
        if ($KeySequence3.Count -gt 0) {
            Send-WitchyKeySequence -Keys $KeySequence3 -KeyDelayMs $KeyDelayMs
        }

        $proc.WaitForExit()
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
        [Parameter(Mandatory)][string[]]$DcxPaths,
        [Parameter(Mandatory)][string]$LogFile
    )

    try {
        $out = @(& $Exe @DcxPaths 2>&1)
        $code = $LASTEXITCODE
    } catch {
        $out = @($_.Exception.Message)
        $code = -9999
    }

    $out | Set-Content -LiteralPath $LogFile -Encoding UTF8
    return $code
}

function Invoke-WitchyBndObjectBatch {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$DcxPaths,
        [Parameter(Mandatory)][int]$BatchNumber,
        [Parameter(Mandatory)][string]$LogsDir,
        [bool]$UseSendKeys = $true,
        [string[]]$KeySequence1 = @('{DOWN}'),
        [string[]]$KeySequence2 = @('{DOWN}'),
        [string[]]$KeySequence3 = @('~'),
        [int]$StartupDelayMs = 1800,
        [int]$KeyDelayMs = 250,
        [int]$StepDelayMs = 700,
        [switch]$StrictExitCode
    )

    Ensure-Dir $LogsDir
    $logFile = Join-Path $LogsDir ("witchybnd_batch_{0:0000}.log.txt" -f $BatchNumber)
    if ($UseSendKeys) {
        $code = Invoke-WitchyBndBatchSendKeys -Exe $Exe -DcxPaths $DcxPaths -LogFile $logFile -KeySequence1 $KeySequence1 -KeySequence2 $KeySequence2 -KeySequence3 $KeySequence3 -StartupDelayMs $StartupDelayMs -KeyDelayMs $KeyDelayMs -StepDelayMs $StepDelayMs
    } else {
        $code = Invoke-WitchyBndBatchDirect -Exe $Exe -DcxPaths $DcxPaths -LogFile $logFile
    }

    $detailRows = [System.Collections.Generic.List[object]]::new()
    foreach ($dcx in $DcxPaths) {
        $flver = Find-ObjFlverAfterWitchy $dcx
        $missing = [string]::IsNullOrWhiteSpace($flver)
        $ok = ($code -eq 0 -or ((-not $StrictExitCode) -and (-not $missing)))
        [void]$detailRows.Add([pscustomobject]@{
            Dcx           = $dcx
            ExitCode      = $code
            ExpectedFlver = Get-ExpectedObjFlverPath $dcx
            FoundFlver    = $flver
            MissingFlver  = $missing
            Ok            = $ok
            Tolerated     = ($code -ne 0 -and (-not $StrictExitCode) -and (-not $missing))
            LogFile       = $logFile
        })
    }

    $detailCsv = Join-Path $LogsDir ("witchybnd_batch_{0:0000}_details.csv" -f $BatchNumber)
    $detailRows | Export-Csv -LiteralPath $detailCsv -NoTypeInformation -Encoding UTF8

    $failures = @($detailRows | Where-Object { -not $_.Ok })
    $missing  = @($detailRows | Where-Object { $_.MissingFlver })
    $tolerated = @($detailRows | Where-Object { $_.Tolerated })

    return [pscustomobject]@{
        Ok           = ($failures.Count -eq 0)
        ExitCode     = $code
        DetailCsv    = $detailCsv
        MissingCount = $missing.Count
        Tolerated    = ($tolerated.Count -gt 0)
    }
}

function Remove-SafeTempDir {
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

    $full = [IO.Path]::GetFullPath($Path)
    $tempFull = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $full.StartsWith($tempFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove temp directory outside system temp: $full"
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
if (-not $WitchyBND) {
    $WitchyBND = Get-FirstConfigValue -Names @(
        'BBR_WitchyBND_v2_14_4_5',
        'BBR_WitchyBnd_v2_14_4_5',
        'BBR_WitchyBND_v21445',
        'BBR_WitchyBND_21445'
    )
}
if (-not $FlverTool) {
    $FlverTool = Get-FirstConfigValue -Names @(
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
if (-not $ChangedObjRoot) {
    if (-not $OutputRoot) { throw 'OutputRoot is required when ChangedObjRoot is not supplied.' }
    $ChangedObjRoot = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) 'BBReborne_obj'
}
$ChangedObjRoot = Resolve-RequiredDirectory -Path $ChangedObjRoot -Label 'Changed OBJ root'
$PatchOutDir = Resolve-DefaultPatchOutDir
$WitchyBND = Resolve-RequiredFile -Path $WitchyBND -Label 'WitchyBND v2.14.4.5 executable'
$FlverTool = Resolve-RequiredFile -Path $FlverTool -Label 'FlverJsonTool executable'
$GitExe = Resolve-RequiredFile -Path $GitExe -Label 'Git executable'

if ($WitchyBatchSize -lt 1) { $WitchyBatchSize = 1 }
if ($DumpThrottle -le 0) { $DumpThrottle = if ($CpuThrottle -gt 0) { $CpuThrottle } else { [Math]::Max(1, [Math]::Min(6, [int]([Environment]::ProcessorCount / 4))) } }
if ($DumpThrottle -lt 1) { $DumpThrottle = 1 }

$scriptSw = [System.Diagnostics.Stopwatch]::StartNew()
$success = $false
$workRoot = ''
$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("bb_reborne_obj_patchdiff_" + [guid]::NewGuid().ToString('N'))

try {
    Invoke-NativeChecked -Exe $GitExe -Arguments @('--version') -AllowedExitCodes @(0) -Label 'git --version' | Out-Null

    $oldRoot = [IO.Path]::GetFullPath($GameRoot)
    $newRoot = [IO.Path]::GetFullPath($ChangedObjRoot)
    $patchDir = [IO.Path]::GetFullPath($PatchOutDir)
    $objectPatchDir = $patchDir
    $workRoot = Join-Path $script:TempRoot '_patch_work'
    $workA = Join-Path $workRoot 'a'
    $workB = Join-Path $workRoot 'b'
    $logsDir = Join-Path $workRoot 'logs'

    Write-Info "GameRoot        = $oldRoot"
    Write-Info "ChangedObjRoot  = $newRoot"
    Write-Info "PatchOutDir     = $patchDir"
    Write-Info "WitchyBND       = $WitchyBND"
    Write-Info "FlverJsonTool   = $FlverTool"
    Write-Info "GitExe          = $GitExe"
    Write-Info "CpuThrottle     = $CpuThrottle"
    Write-Info "GpuThrottle     = $GpuThrottle"
    Write-Info "DumpThrottle    = $DumpThrottle"
    Write-Info "WitchyBatchSize = $WitchyBatchSize"
    Write-Info "WorkRoot        = $workRoot"
    if (-not $DryRun) {
        Ensure-Dir $patchDir
        # Do not clear PatchOutDir/Diffs. Existing files are replaced only after
        # a successful temp-file write, and stale files are left for manual review.
        foreach ($d in @($workA, $workB, $logsDir)) { Ensure-Dir $d }
    }

    Write-Stage ''
    Write-Stage 'Stage #0: discovering and hashing object binders...'

    $oldIndex = Get-ObjectIndex -Root $oldRoot -DoRecurse ([bool]$Recurse) -RegexText $IncludeRegex
    $newIndex = Get-ObjectIndex -Root $newRoot -DoRecurse ([bool]$Recurse) -RegexText $IncludeRegex
    $allKeys = @($oldIndex.Keys + $newIndex.Keys | Sort-Object -Unique)
    $allKeys = @($allKeys | Where-Object { -not $_.StartsWith('_patches\', [StringComparison]::OrdinalIgnoreCase) -and -not $_.StartsWith('_patch_work\', [StringComparison]::OrdinalIgnoreCase) })

    if ($StartAt -gt 0) {
        if ($StartAt -ge $allKeys.Count) { throw "-StartAt $StartAt >= object count $($allKeys.Count)" }
        $allKeys = @($allKeys[$StartAt..($allKeys.Count - 1)])
    }
    if ($MaxObjects -gt 0 -and $allKeys.Count -gt $MaxObjects) {
        $allKeys = @($allKeys | Select-Object -First $MaxObjects)
    }

    if ($allKeys.Count -eq 0) {
        Write-Info 'No *.objbnd.dcx files found after filters.'
        $success = $true
        return
    }

    $compareRows = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($key in $allKeys) {
        $n++
        if (($n % 25) -eq 0 -or $n -eq $allKeys.Count) {
            $pct = [int](100.0 * $n / $allKeys.Count)
            Write-Progress -Activity 'Hash object binders' -Status ("{0}/{1}" -f $n, $allKeys.Count) -PercentComplete $pct
        }

        $oldFile = if ($oldIndex.ContainsKey($key)) { $oldIndex[$key] } else { $null }
        $newFile = if ($newIndex.ContainsKey($key)) { $newIndex[$key] } else { $null }

        $rel = if ($null -ne $newFile) { $newFile.Rel } else { $oldFile.Rel }
        $oldPath = if ($null -ne $oldFile) { $oldFile.FullName } else { '' }
        $newPath = if ($null -ne $newFile) { $newFile.FullName } else { '' }
        $oldHash = if ($oldPath) { Get-FileHashText -Path $oldPath -Algorithm $HashAlgorithm } else { '' }
        $newHash = if ($newPath) { Get-FileHashText -Path $newPath -Algorithm $HashAlgorithm } else { '' }
        $oldSize = if ($null -ne $oldFile) { [int64]$oldFile.Length } else { 0 }
        $newSize = if ($null -ne $newFile) { [int64]$newFile.Length } else { 0 }

        $status = 'Same'
        if (-not $oldPath -and $newPath) { $status = 'Added' }
        elseif ($oldPath -and -not $newPath) { $status = 'Removed' }
        elseif ($oldHash -ne $newHash) { $status = 'Changed' }

        $objBase = Get-ObjBaseFromLeaf (Split-Path -Leaf $rel)
        $relDir = Split-Path -Parent $rel
        $jsonRel = if ([string]::IsNullOrWhiteSpace($relDir)) { $objBase + '.flver.json' } else { Join-Path $relDir ($objBase + '.flver.json') }

        [void]$compareRows.Add([pscustomobject]@{
            ObjectBase = $objBase
            Rel        = $rel
            JsonRel    = $jsonRel
            BinderLeaf = Split-Path -Leaf $rel
            Status     = $status
            OldPath    = $oldPath
            NewPath    = $newPath
            OldSize    = $oldSize
            NewSize    = $newSize
            OldHash    = $oldHash
            NewHash    = $newHash
        })
    }
    Write-Progress -Activity 'Hash object binders' -Completed

    $compareCsv = Join-Path $patchDir 'compare_binders.csv'
    if (-not $DryRun) { $compareRows | Sort-Object Rel | Export-Csv -LiteralPath $compareCsv -NoTypeInformation -Encoding UTF8 }

    $sameCount    = @($compareRows | Where-Object Status -eq 'Same').Count
    $changedCount = @($compareRows | Where-Object Status -eq 'Changed').Count
    $addedCount   = @($compareRows | Where-Object Status -eq 'Added').Count
    $removedCount = @($compareRows | Where-Object Status -eq 'Removed').Count

    Write-Info ("Binder compare done. Same={0} Changed={1} Added={2} Removed={3}" -f $sameCount, $changedCount, $addedCount, $removedCount)
    if (-not $DryRun) { Write-Info "Compare CSV: $compareCsv" }

    $changedRows = @($compareRows | Where-Object { $_.Status -in @('Changed','Added','Removed') } | Sort-Object Rel)
    if ($changedRows.Count -eq 0) {
        Write-Info 'No changed object binders. Nothing to decompress or patch.'
        $success = $true
        return
    }

    if ($DryRun) {
        Write-Info 'DRYRUN: stopping after hash compare.'
        $success = $true
        return
    }

    Write-Stage ''
    Write-Stage ("Stage #1: copying {0} changed/added/removed object binders into temp work folder..." -f $changedRows.Count)

    $workRows = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $changedRows) {
        $oldCopy = ''
        $newCopy = ''

        if ($r.OldPath) {
            $oldCopy = Join-Path $workA $r.Rel
            Ensure-Dir (Split-Path -Parent $oldCopy)
            Copy-Item -LiteralPath $r.OldPath -Destination $oldCopy -Force
        }
        if ($r.NewPath) {
            $newCopy = Join-Path $workB $r.Rel
            Ensure-Dir (Split-Path -Parent $newCopy)
            Copy-Item -LiteralPath $r.NewPath -Destination $newCopy -Force
        }

        $oldJson = if ($oldCopy) { Join-Path $workA $r.JsonRel } else { '' }
        $newJson = if ($newCopy) { Join-Path $workB $r.JsonRel } else { '' }

        [void]$workRows.Add([pscustomobject]@{
            ObjectBase = $r.ObjectBase
            Rel        = $r.Rel
            JsonRel    = $r.JsonRel
            BinderLeaf = $r.BinderLeaf
            Status     = $r.Status
            OldDcxCopy = $oldCopy
            NewDcxCopy = $newCopy
            OldJson    = $oldJson
            NewJson    = $newJson
        })
    }

    Write-Stage ''
    Write-Stage ("Stage #2: decompressing object binders with WitchyBND, batchSize={0}, sendKeys={1}..." -f $WitchyBatchSize, $UseWitchySendKeys)

    $dcxToDecompress = @(
        @($workRows | Where-Object { $_.OldDcxCopy } | ForEach-Object { $_.OldDcxCopy }) +
        @($workRows | Where-Object { $_.NewDcxCopy } | ForEach-Object { $_.NewDcxCopy })
    )

    $witchyBatchResults = [System.Collections.Generic.List[object]]::new()
    $totalDcx = $dcxToDecompress.Count
    for ($start = 0; $start -lt $totalDcx; $start += $WitchyBatchSize) {
        $endExclusive = [Math]::Min($start + $WitchyBatchSize, $totalDcx)
        $batch = @($dcxToDecompress[$start..($endExclusive - 1)])
        $batchNumber = [int]([Math]::Floor($start / $WitchyBatchSize) + 1)
        Write-Info ("  WitchyBND batch {0}: files {1}-{2} ({3} files)" -f $batchNumber, ($start + 1), $endExclusive, $batch.Count)

        $result = Invoke-WitchyBndObjectBatch `
            -Exe $WitchyBND `
            -DcxPaths $batch `
            -BatchNumber $batchNumber `
            -LogsDir $logsDir `
            -UseSendKeys $UseWitchySendKeys `
            -KeySequence1 $WitchyKeySequence1 `
            -KeySequence2 $WitchyKeySequence2 `
            -KeySequence3 $WitchyKeySequence3 `
            -StartupDelayMs $WitchyStartupDelayMs `
            -KeyDelayMs $WitchyKeyDelayMs `
            -StepDelayMs $WitchyStepDelayMs `
            -StrictExitCode:$StrictWitchyExitCode

        [void]$witchyBatchResults.Add($result)
        if (-not $result.Ok) { throw "WitchyBND batch $batchNumber failed. See: $($result.DetailCsv)" }
    }

    $toleratedCount = @($witchyBatchResults | Where-Object { $_.Tolerated }).Count
    if ($toleratedCount -gt 0) {
        Write-Warning ("  Tolerated non-zero WitchyBND exit in {0} batch(es) because expected FLVERs existed." -f $toleratedCount)
    }

    Write-Stage ''
    Write-Stage ("Stage #3: dumping object FLVER JSON, throttle={0}..." -f $DumpThrottle)

    $dumpItems = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $workRows) {
        if ($r.OldDcxCopy) {
            [void]$dumpItems.Add([pscustomobject]@{ ObjectBase=$r.ObjectBase; Rel=$r.Rel; JsonRel=$r.JsonRel; Side='old'; Dcx=$r.OldDcxCopy; Flver=(Find-ObjFlverAfterWitchy $r.OldDcxCopy); Json=$r.OldJson })
        }
        if ($r.NewDcxCopy) {
            [void]$dumpItems.Add([pscustomobject]@{ ObjectBase=$r.ObjectBase; Rel=$r.Rel; JsonRel=$r.JsonRel; Side='new'; Dcx=$r.NewDcxCopy; Flver=(Find-ObjFlverAfterWitchy $r.NewDcxCopy); Json=$r.NewJson })
        }
    }

    $missingFlver = @($dumpItems | Where-Object { -not $_.Flver })
    if ($missingFlver.Count -gt 0) {
        $missingCsv = Join-Path $patchDir 'missing_flver_after_witchy.csv'
        $missingFlver | Export-Csv -LiteralPath $missingCsv -NoTypeInformation -Encoding UTF8
        throw "Could not locate FLVER for $($missingFlver.Count) decompressed object binder(s). See: $missingCsv"
    }

    foreach ($it in $dumpItems) { Ensure-Dir (Split-Path -Parent $it.Json) }

    $dumpResults = @($dumpItems | ForEach-Object -Parallel {
        $ErrorActionPreference = 'Stop'
        $global:PSNativeCommandUseErrorActionPreference = $false
        $global:PSNativeCommandArgumentPassing = 'Standard'
        $it = $_
        try {
            if (-not (Test-Path -LiteralPath $it.Flver -PathType Leaf)) { throw "FLVER not found: $($it.Flver)" }
            & $using:FlverTool dump $it.Flver $it.Json | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "FlverJsonTool dump failed with exit code $LASTEXITCODE" }
            if (-not (Test-Path -LiteralPath $it.Json -PathType Leaf)) { throw "Dump did not produce JSON: $($it.Json)" }
            $hash = (Get-FileHash -LiteralPath $it.Json -Algorithm $using:HashAlgorithm).Hash.ToLowerInvariant()
            [pscustomobject]@{ ObjectBase=$it.ObjectBase; Rel=$it.Rel; JsonRel=$it.JsonRel; Side=$it.Side; Dcx=$it.Dcx; Flver=$it.Flver; Json=$it.Json; Ok=$true; JsonHash=$hash; Error='' }
        } catch {
            [pscustomobject]@{ ObjectBase=$it.ObjectBase; Rel=$it.Rel; JsonRel=$it.JsonRel; Side=$it.Side; Dcx=$it.Dcx; Flver=$it.Flver; Json=$it.Json; Ok=$false; JsonHash=''; Error=$_.Exception.Message }
        }
    } -ThrottleLimit $DumpThrottle)

    $dumpManifest = Join-Path $patchDir 'dump_manifest.csv'
    $dumpResults | Sort-Object Rel, Side | Export-Csv -LiteralPath $dumpManifest -NoTypeInformation -Encoding UTF8
    $dumpFailures = @($dumpResults | Where-Object { -not $_.Ok })
    if ($dumpFailures.Count -gt 0) { throw "FLVER JSON dump failed for $($dumpFailures.Count) file(s). See: $dumpManifest" }
    Write-Info "Dump manifest: $dumpManifest"

    Write-Stage ''
    Write-Stage 'Stage #4: comparing dumped JSON hashes...'

    $dumpBySide = @{}
    foreach ($d in $dumpResults) { $dumpBySide[("{0}|{1}" -f $d.Rel.ToLowerInvariant(), $d.Side)] = $d }

    $jsonRows = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $workRows) {
        $oldDump = $dumpBySide[("{0}|old" -f $r.Rel.ToLowerInvariant())]
        $newDump = $dumpBySide[("{0}|new" -f $r.Rel.ToLowerInvariant())]
        $oldJson = if ($null -ne $oldDump) { $oldDump.Json } else { '' }
        $newJson = if ($null -ne $newDump) { $newDump.Json } else { '' }
        $oldHash = if ($null -ne $oldDump) { $oldDump.JsonHash } else { '' }
        $newHash = if ($null -ne $newDump) { $newDump.JsonHash } else { '' }

        $jsonStatus = 'Same'
        if (-not $oldJson -and $newJson) { $jsonStatus = 'Added' }
        elseif ($oldJson -and -not $newJson) { $jsonStatus = 'Removed' }
        elseif ($oldHash -ne $newHash) { $jsonStatus = 'Changed' }

        [void]$jsonRows.Add([pscustomobject]@{
            ObjectBase=$r.ObjectBase; Rel=$r.Rel; JsonRel=$r.JsonRel; BinderStatus=$r.Status; JsonStatus=$jsonStatus;
            OldJson=$oldJson; NewJson=$newJson; OldJsonHash=$oldHash; NewJsonHash=$newHash; PatchPath=''
        })
    }

    $jsonChangedRows = @($jsonRows | Where-Object { $_.JsonStatus -ne 'Same' } | Sort-Object JsonRel)

    foreach ($r in @($jsonRows | Where-Object { $_.JsonStatus -eq 'Same' })) {
        $stalePatch = Join-Path $objectPatchDir (Get-PatchLeafForJsonRel $r.JsonRel)
        if (Test-Path -LiteralPath $stalePatch -PathType Leaf) {
            Write-Warning ("  UNCHANGED: leaving existing patch untouched for manual review: {0}" -f $stalePatch)
        }
    }

    $jsonManifestPre = Join-Path $patchDir 'json_patch_manifest.csv'
    if ($jsonChangedRows.Count -eq 0) {
        $jsonRows | Sort-Object JsonRel | Export-Csv -LiteralPath $jsonManifestPre -NoTypeInformation -Encoding UTF8
        Write-Info 'All changed DCX binders produced identical FLVER JSON. No patch files were generated.'
        Write-Info 'Existing aggregate/per-object patches were left untouched for manual review.'
        Write-Info "JSON manifest: $jsonManifestPre"
        $success = $true
        return
    }

    Write-Info ("  JSON-changing objects: {0}" -f $jsonChangedRows.Count)

    Write-Stage ''
    Write-Stage ("Stage #5: exporting Git patches to Diffs\obj\_patches for {0} JSON-changing object(s)..." -f $jsonChangedRows.Count)

    $allPatch = Join-Path $patchDir 'all_changed_flver_json.patch'
    $allPatchTemp = Join-Path $workRoot 'all_changed_flver_json.patch.generated.tmp'
    if (Test-Path -LiteralPath $allPatchTemp -PathType Leaf) { Remove-Item -LiteralPath $allPatchTemp -Force }

    $patchExportFailures = [System.Collections.Generic.List[object]]::new()

    foreach ($r in $jsonChangedRows) {
        $patchPath = Join-Path $objectPatchDir (Get-PatchLeafForJsonRel $r.JsonRel)
        $patchTemp = Join-Path $workRoot ((Get-PatchLeafForJsonRel $r.JsonRel) + '.generated.tmp')

        $oldJson = $r.OldJson
        $newJson = $r.NewJson

        if (-not (Test-Path -LiteralPath $oldJson -PathType Leaf) -or -not (Test-Path -LiteralPath $newJson -PathType Leaf)) {
            [void]$patchExportFailures.Add([pscustomobject]@{ ObjectBase=$r.ObjectBase; JsonRel=$r.JsonRel; Error='Missing old/new JSON file for direct diff' })
            continue
        }

        $oldRelToWork = [IO.Path]::GetRelativePath($workRoot, $oldJson) -replace '\\','/'
        $newRelToWork = [IO.Path]::GetRelativePath($workRoot, $newJson) -replace '\\','/'

        Push-Location -LiteralPath $workRoot
        try {
            $diffText = @(& $GitExe `
                -c core.autocrlf=false `
                -c core.safecrlf=false `
                diff --no-index --binary --full-index --src-prefix=a/ --dst-prefix=b/ -- `
                $oldRelToWork $newRelToWork 2>&1)
            $code = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        if ($code -eq 1) {
            $diffText | Set-Content -LiteralPath $patchTemp -Encoding UTF8
            if ((Get-Item -LiteralPath $patchTemp).Length -le 0) {
                throw "Generated temp patch is empty: $patchTemp"
            }
            Move-Item -LiteralPath $patchTemp -Destination $patchPath -Force
            $r.PatchPath = $patchPath
            if (Test-Path -LiteralPath $allPatchTemp -PathType Leaf) { Add-Content -LiteralPath $allPatchTemp -Value '' -Encoding UTF8 }
            Add-Content -LiteralPath $allPatchTemp -Value $diffText -Encoding UTF8
        } elseif ($code -eq 0) {
            Write-Warning ("  {0} JSON hashes differed, but git diff produced no patch." -f $r.ObjectBase)
        } else {
            $first = ($diffText | Select-Object -First 1)
            [void]$patchExportFailures.Add([pscustomobject]@{ ObjectBase=$r.ObjectBase; JsonRel=$r.JsonRel; Error="git diff failed with exit code $code. $first" })
        }
    }

    if ($patchExportFailures.Count -gt 0) {
        $failCsv = Join-Path $patchDir 'patch_export_failures.csv'
        $patchExportFailures | Export-Csv -LiteralPath $failCsv -NoTypeInformation -Encoding UTF8
        throw "Patch export failed for $($patchExportFailures.Count) object(s). See: $failCsv"
    }

    if (Test-Path -LiteralPath $allPatchTemp -PathType Leaf) {
        Move-Item -LiteralPath $allPatchTemp -Destination $allPatch -Force
    } else {
        Write-Info 'No aggregate patch was generated; existing aggregate patch was left untouched.'
    }

    $jsonManifest = Join-Path $patchDir 'json_patch_manifest.csv'
    $jsonRows | Sort-Object JsonRel | Export-Csv -LiteralPath $jsonManifest -NoTypeInformation -Encoding UTF8

    $patchCount = @($jsonRows | Where-Object { $_.PatchPath }).Count
    Write-Stage ''
    Write-Host '================ FINAL SUMMARY ================'
    Write-Info ("Objects compared:          {0}" -f $allKeys.Count)
    Write-Info ("DCX changed/added/removed: {0}" -f $changedRows.Count)
    Write-Info ("JSON changed/added/removed:{0}" -f $jsonChangedRows.Count)
    Write-Info ("Per-object patches:        {0}" -f $patchCount)
    Write-Info ("PatchOutDir:               {0}" -f $patchDir)
    Write-Info ("Aggregate patch:           {0}" -f $allPatch)
    Write-Info ("Compare CSV:               {0}" -f $compareCsv)
    Write-Info ("Dump manifest:             {0}" -f $dumpManifest)
    Write-Info ("JSON manifest:             {0}" -f $jsonManifest)
    Write-Info ("WorkRoot:                  {0}" -f $workRoot)
    Write-Info ("Elapsed:                   {0}" -f (Format-Elapsed $scriptSw.Elapsed))

    $success = $true
} catch {
    Write-Error $_.Exception.Message
    throw
} finally {
    if (-not [string]::IsNullOrWhiteSpace($script:TempRoot) -and (Test-Path -LiteralPath $script:TempRoot -PathType Container)) {
        if ($DryRun) {
            Write-Info 'DRYRUN: temp work folder was not used.'
        } elseif ($success -and -not $KeepWork) {
            Write-Stage ''
            Write-Stage 'Stage #6: cleanup temp work folder...'
            try {
                Remove-SafeTempDir -Path $script:TempRoot
                Write-Info "  Removed: $script:TempRoot"
            } catch {
                Write-Warning $_.Exception.Message
            }
        } elseif (-not $success) {
            Write-Stage ''
            Write-Warning "Keeping temp work folder after failure for inspection: $script:TempRoot"
        } else {
            Write-Stage ''
            Write-Info "Keeping temp work folder because -KeepWork was used: $script:TempRoot"
        }
    }
}
