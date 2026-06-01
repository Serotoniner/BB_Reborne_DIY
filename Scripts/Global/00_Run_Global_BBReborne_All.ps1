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
    00_Run_Global_BBReborne_All.ps1

    Isolated global script caller for the BB Reborne DIY Tool.

    Intended save path:
        <BBReborneDIYTool>\Scripts\Global\00_Run_Global_BBReborne_All.ps1

    Purpose:
    - Keep the WPF tool code small.
    - Run all global patch scripts in a fixed order.
    - Run every child script in its own PowerShell 7 process.
    - Pass only normal script parameters to child scripts.
    - Avoid wrapping or interpreting WitchyBND calls. WitchyBND is called only by the child scripts.
    - Use -ExecutionPolicy Bypass for every child script.
    - Optionally remove Mark-of-the-Web from the public script/diff folders.
    - Write per-script logs and a machine-readable summary report.

    Global scripts called:
        01_Global_BBReborne_SFX_RemovePlayerLight.ps1
        02_Global_BBReborne_SFX_M25.ps1
        03_Global_BBReborne_Menu_fe.ps1
        04_Global_BBReborne_Gparam_GameParam.ps1
        05_Global_BBReborne_Obj_FromDiffs.ps1
        06_Global_BBReborne_Param_DefaultDrawparam.ps1

    Expected config file from BBReborneDIYTool.ps1:
        <ToolRoot>\BBReborneDIYTool.paths.ps1

    Example direct run:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\00_Run_Global_BBReborne_All.ps1 `
            -ToolPathsPs1 "<BBReborneDIYTool>\Tools\BBReborneDIYTool.paths.ps1"
#>

[CmdletBinding()]
param(
    [string]$ToolPathsPs1,
    [string]$GameRoot,
    [string]$OutputRoot,
    [int]$CpuThrottle = 0,
    [int]$GpuThrottle = 0,

    [string]$PwshExe,
    [string]$ScriptsRoot,
    [string]$DiffsRoot,

    [switch]$NoUnblock,
    [switch]$KeepChildWork,
    [switch]$ContinueOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:PSNativeCommandUseErrorActionPreference = $false
$global:PSNativeCommandArgumentPassing = 'Standard'

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

function Resolve-RequiredFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label is empty." }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label not found: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
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

function Get-OptionalVariableValue {
    param([Parameter(Mandatory)][string]$Name)

    $var = Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $var) { return $null }
    return $var.Value
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
        . $configPath
        return $configPath
    }

    Write-Info 'No tool config file found. Parameters must provide all required paths.'
    return $null
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

function Resolve-PwshExe {
    if ($PwshExe) {
        return (Resolve-RequiredFile -Path $PwshExe -Label 'PowerShell 7 executable')
    }

    foreach ($varName in @('BBR_PowerShell7Exe', 'BBR_PwshExe')) {
        $fromConfig = Get-OptionalVariableValue -Name $varName
        if (-not [string]::IsNullOrWhiteSpace([string]$fromConfig)) {
            if (Test-Path -LiteralPath ([string]$fromConfig) -PathType Leaf) {
                return (Resolve-Path -LiteralPath ([string]$fromConfig)).Path
            }
        }
    }

    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }

    throw 'PowerShell 7 executable was not found. Run Step 1 setup first.'
}

function Get-DIYRootFromThisScript {
    $root = $PSScriptRoot
    if (-not $root) { throw 'PSScriptRoot is empty; cannot determine tool root.' }

    $parent = Split-Path -Parent $root
    if (-not $parent) { return $root }

    $grandParent = Split-Path -Parent $parent
    if ($grandParent) { return $grandParent }
    return $parent
}

function Resolve-ScriptsRoot {
    if ($ScriptsRoot) {
        return (Resolve-RequiredDirectory -Path $ScriptsRoot -Label 'Scripts root')
    }

    return (Resolve-RequiredDirectory -Path $PSScriptRoot -Label 'Global scripts root')
}

function Resolve-DiffsRoot {
    if ($DiffsRoot) {
        return (Resolve-RequiredDirectory -Path $DiffsRoot -Label 'Diffs root')
    }

    $toolRoot = Get-DIYRootFromThisScript
    $candidate = Join-Path $toolRoot 'Diffs'
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    Write-Warning "Diffs folder was not found yet: $candidate"
    return $candidate
}

function Resolve-ToolFileFromConfigOrSearch {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$VariableNames,
        [Parameter(Mandatory)][string]$SearchRoot,
        [Parameter(Mandatory)][string]$FileName,
        [string]$PathMustContain = '',
        [switch]$AllowPathCommand
    )

    foreach ($varName in $VariableNames) {
        $value = Get-OptionalVariableValue -Name $varName
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            if (Test-Path -LiteralPath ([string]$value) -PathType Leaf) {
                return (Resolve-Path -LiteralPath ([string]$value)).Path
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SearchRoot) -and (Test-Path -LiteralPath $SearchRoot -PathType Container)) {
        $matches = @(Get-ChildItem -LiteralPath $SearchRoot -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($PathMustContain)) {
            $matches = @($matches | Where-Object { $_.FullName -like "*$PathMustContain*" })
        }

        $matches = @($matches | Sort-Object FullName)
        if ($matches.Count -gt 0) {
            return $matches[0].FullName
        }
    }

    if ($AllowPathCommand) {
        $cmd = Get-Command $FileName -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) {
            return $cmd.Source
        }
    }

    throw "$Label was not found. Checked config variables: $($VariableNames -join ', '), searched under: $SearchRoot, and PATH fallback was $AllowPathCommand."
}


function Get-WitchyRoamingSettingsPath {
    $appData = [Environment]::GetFolderPath('ApplicationData')
    return (Join-Path (Join-Path $appData 'WitchyBND') 'appsettings.user.json')
}

function Get-WitchyBnd3001RoamingSettingsJson {
    $settings = [ordered]@{
        Bnd                        = $true
        ParamDefaultValueThreshold = 1
        ParamCellStyle             = 0
        Recursive                  = $true
        EndDelay                   = 100
        PauseOnError               = $false
        Parallel                   = $true
        Expert                     = $false
        Offline                    = $true
        TaeFolder                  = $false
        DeferTools                 = [ordered]@{}
        Flexible                   = $true
        LastUpdateCheck            = '2026-01-15T20:01:33.8508924-03:00'
        SkipUpdateVersion          = '3.0.0.0'
        LastLaunchedVersion        = '3.0.0.1'
        BackupMethod               = 1
        GitBackup                  = $false
    }

    return ($settings | ConvertTo-Json -Depth 8)
}

function Get-WitchyBnd21445RoamingSettingsJson {
    $settings = [ordered]@{
        Bnd                        = $false
        Dcx                        = $false
        ParamDefaultValueThreshold = 1
        ParamCellStyle             = 0
        Recursive                  = $true
        EndDelay                   = 100
        PauseOnError               = $true
        Parallel                   = $true
        Expert                     = $false
        Offline                    = $true
        TaeFolder                  = $false
        DeferTools                 = [ordered]@{}
        Flexible                   = $false
        LastUpdateCheck            = '2026-01-15T20:01:33.8508924-03:00'
        SkipUpdateVersion          = '3.0.0.0'
        LastLaunchedVersion        = '2.14.4.5'
        BackupMethod               = 1
        GitBackup                  = $false
    }

    return ($settings | ConvertTo-Json -Depth 8)
}

function Get-WitchyBnd2401LocalSettingsJson {
    $settings = [ordered]@{
        Bnd                = $false
        Dcx                = $false
        ParamDefaultValues = $true
        Recursive          = $true
        EndDelay           = 100
        PauseOnError       = $false
        Parallel           = $false
        Expert             = $false
        Offline            = $false
    }

    return ($settings | ConvertTo-Json -Depth 8)
}

function Write-JsonNoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Json
    )

    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    [System.IO.File]::WriteAllText(
        $Path,
        $Json,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Write-WitchySettingsForGlobalStep {
    param(
        [Parameter(Mandatory)][ValidateSet('v3.0.0.1','v2.14.4.5','v2.4.0.1','None')][string]$Version,
        [AllowNull()][string]$WitchyExe
    )

    if ($Version -eq 'None') {
        return
    }

    if ($Version -eq 'v3.0.0.1') {
        $path = Get-WitchyRoamingSettingsPath
        Write-JsonNoBom -Path $path -Json (Get-WitchyBnd3001RoamingSettingsJson)
        Write-Info "WitchyBND settings prepared for v3.0.0.1: $path"
        return
    }

    if ($Version -eq 'v2.14.4.5') {
        $path = Get-WitchyRoamingSettingsPath
        Write-JsonNoBom -Path $path -Json (Get-WitchyBnd21445RoamingSettingsJson)
        Write-Info "WitchyBND settings prepared for v2.14.4.5: $path"
        return
    }

    if ($Version -eq 'v2.4.0.1') {
        if ([string]::IsNullOrWhiteSpace($WitchyExe)) {
            throw 'Cannot prepare WitchyBND v2.4.0.1 settings because WitchyExe is empty.'
        }

        $installDir = Split-Path -Parent $WitchyExe
        $json = Get-WitchyBnd2401LocalSettingsJson

        $paths = @(
            (Join-Path $installDir 'appsettings.user.json'),
            (Join-Path $installDir 'appsettings.json')
        ) | Select-Object -Unique

        foreach ($path in $paths) {
            Write-JsonNoBom -Path $path -Json $json
            Write-Info "WitchyBND settings prepared for v2.4.0.1: $path"
        }

        return
    }
}

function Unblock-BBRebornePublicFiles {
    param(
        [Parameter(Mandatory)][string]$ScriptsRootPath,
        [Parameter(Mandatory)][string]$DiffsRootPath
    )

    $roots = @($ScriptsRootPath)
    if (Test-Path -LiteralPath $DiffsRootPath -PathType Container) {
        $roots += $DiffsRootPath
    }

    foreach ($root in $roots) {
        Write-Info "Unblocking files under: $root"
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue)
        foreach ($file in $files) {
            try {
                Unblock-File -LiteralPath $file.FullName -ErrorAction SilentlyContinue
            } catch {
                Write-Warning "Could not unblock: $($file.FullName) :: $($_.Exception.Message)"
            }
        }
    }
}

function Invoke-ChildScript {
    param(
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$ToolPathsPath,
        [Parameter(Mandatory)][string]$GameRootPath,
        [Parameter(Mandatory)][string]$OutputRootPath,
        [Parameter(Mandatory)][int]$CpuThrottleValue,
        [Parameter(Mandatory)][int]$GpuThrottleValue,
        [string[]]$ExtraArguments = @(),
        [switch]$KeepWork
    )

    $args = @(
        '-STA',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath,
        '-ToolPathsPs1', $ToolPathsPath,
        '-GameRoot', $GameRootPath,
        '-OutputRoot', $OutputRootPath,
        '-CpuThrottle', ([string]$CpuThrottleValue),
        '-GpuThrottle', ([string]$GpuThrottleValue)
    )

    if ($ExtraArguments -and $ExtraArguments.Count -gt 0) {
        $args += $ExtraArguments
    }

    if ($KeepWork) {
        $args += '-KeepWork'
    }

    Write-Info "BBR_GLOBAL_STEP_START|$Label|$ScriptPath"
    Write-Info "Launching visible child PowerShell. Do not click other windows while WitchyBND prompts are active."

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $PwshPath
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal

    foreach ($arg in $args) {
        [void]$psi.ArgumentList.Add($arg)
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $proc) {
        throw "Failed to start child script process for: $Label"
    }

    $proc.WaitForExit()
    $sw.Stop()

    @(
        "Label=$Label"
        "ScriptPath=$ScriptPath"
        "ExitCode=$($proc.ExitCode)"
        "ElapsedSeconds=$([Math]::Round($sw.Elapsed.TotalSeconds, 3))"
        "Elapsed=$($sw.Elapsed.ToString())"
        "Output was not redirected. Check the visible child PowerShell window and child script work/log folders for details."
    ) | Set-Content -LiteralPath $LogPath -Encoding UTF8

    $result = [pscustomobject]@{
        Label          = $Label
        ScriptPath     = $ScriptPath
        LogPath        = $LogPath
        ExitCode       = $proc.ExitCode
        Ok             = ($proc.ExitCode -eq 0)
        ElapsedSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 3)
        Elapsed        = $sw.Elapsed.ToString()
    }

    Write-Info ("BBR_GLOBAL_STEP_DONE|{0}|ExitCode={1}|ElapsedSeconds={2}|Log={3}" -f $Label, $result.ExitCode, $result.ElapsedSeconds, $LogPath)

    return $result
}

# -------------------- Main --------------------

$configPath = Import-ToolConfig

if (-not $GameRoot) { $GameRoot = Get-OptionalVariableValue -Name 'BBR_GameRoot' }
if (-not $OutputRoot) { $OutputRoot = Get-OptionalVariableValue -Name 'BBR_OutputRoot' }
if ($CpuThrottle -le 0) {
    $configuredCpuThrottle = Get-OptionalVariableValue -Name 'BBR_CpuThrottle'
    if ($configuredCpuThrottle) { $CpuThrottle = [int]$configuredCpuThrottle }
}
if ($GpuThrottle -le 0) {
    $configuredGpuThrottle = Get-OptionalVariableValue -Name 'BBR_GpuThrottle'
    if ($configuredGpuThrottle) { $GpuThrottle = [int]$configuredGpuThrottle }
}

if (-not $configPath) {
    if (-not $ToolPathsPs1) { throw 'ToolPathsPs1 is required when the config file cannot be auto-detected.' }
    $configPath = Resolve-RequiredFile -Path $ToolPathsPs1 -Label 'Tool paths file'
}

$GameRoot = Resolve-GameRoot -Path $GameRoot
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$PwshExe = Resolve-PwshExe
$ScriptsRoot = Resolve-ScriptsRoot
$DiffsRoot = Resolve-DiffsRoot
$ToolRoot = Split-Path -Parent $configPath

if ($CpuThrottle -le 0) { $CpuThrottle = [Math]::Max(1, [Environment]::ProcessorCount - 2) }
if ($GpuThrottle -le 0) { $GpuThrottle = 1 }

$logsRoot = Join-Path $OutputRoot '_logs\global'
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$runLogDir = Join-Path $logsRoot $stamp
Ensure-Dir $runLogDir

Write-Info "GameRoot    = $GameRoot"
Write-Info "OutputRoot  = $OutputRoot"
Write-Info "ToolPaths   = $configPath"
Write-Info "PwshExe     = $PwshExe"
Write-Info "ScriptsRoot = $ScriptsRoot"
Write-Info "DiffsRoot   = $DiffsRoot"
Write-Info "ToolRoot    = $ToolRoot"
Write-Info "CpuThrottle = $CpuThrottle"
Write-Info "GpuThrottle = $GpuThrottle"
Write-Info "RunLogDir   = $runLogDir"

if (-not $NoUnblock) {
    Write-Stage ''
    Write-Stage 'Preparing public scripts/diffs for execution...'
    Unblock-BBRebornePublicFiles -ScriptsRootPath $ScriptsRoot -DiffsRootPath $DiffsRoot
}


$WitchyBnd3001 = Resolve-ToolFileFromConfigOrSearch `
    -Label 'WitchyBND v3.0.0.1' `
    -VariableNames @('BBR_WitchyBND_v3_0_0_1','BBR_WitchyBnd_v3_0_0_1','BBR_WitchyBND_v3001','BBR_WitchyBND_3001') `
    -SearchRoot $ToolRoot `
    -FileName 'WitchyBND.exe' `
    -PathMustContain '3.0.0.1'

$WitchyBnd21445 = Resolve-ToolFileFromConfigOrSearch `
    -Label 'WitchyBND v2.14.4.5' `
    -VariableNames @('BBR_WitchyBND_v2_14_4_5','BBR_WitchyBnd_v2_14_4_5','BBR_WitchyBND_v21445','BBR_WitchyBND_21445') `
    -SearchRoot $ToolRoot `
    -FileName 'WitchyBND.exe' `
    -PathMustContain '2.14.4.5'

$WitchyBnd2401 = Resolve-ToolFileFromConfigOrSearch `
    -Label 'WitchyBND v2.4.0.1' `
    -VariableNames @('BBR_WitchyBND_v2_4_0_1','BBR_WitchyBnd_v2_4_0_1','BBR_WitchyBND_v2401','BBR_WitchyBND_2401') `
    -SearchRoot $ToolRoot `
    -FileName 'WitchyBND.exe' `
    -PathMustContain '2.4.0.1'

$GitExeResolved = Resolve-ToolFileFromConfigOrSearch `
    -Label 'Git executable' `
    -VariableNames @('BBR_GitExe','BBR_GitForWindowsExe') `
    -SearchRoot $ToolRoot `
    -FileName 'git.exe' `
    -AllowPathCommand

$FlverJsonToolExeResolved = Resolve-ToolFileFromConfigOrSearch `
    -Label 'FlverJsonTool executable' `
    -VariableNames @('BBR_FlverJsonToolExe','BBR_FLVERJsonToolExe') `
    -SearchRoot $ToolRoot `
    -FileName 'FlverJsonTool.exe'

$steps = @(
    [pscustomobject]@{
        Label = '01 SFX remove player light'
        Script = '01_Global_BBReborne_SFX_RemovePlayerLight.ps1'
        WitchySettings = 'v3.0.0.1'
        WitchyExe = $WitchyBnd3001
        ExtraArguments = @('-WitchyBndExe', $WitchyBnd3001)
    },
    [pscustomobject]@{
        Label = '02 SFX M25 merge'
        Script = '02_Global_BBReborne_SFX_M25.ps1'
        WitchySettings = 'v2.14.4.5'
        WitchyExe = $WitchyBnd21445
        ExtraArguments = @('-WitchyBndExe', $WitchyBnd21445)
    },
    [pscustomobject]@{
        Label = '03 Menu fe.gfx'
        Script = '03_Global_BBReborne_Menu_fe.ps1'
        WitchySettings = 'None'
        WitchyExe = ''
        ExtraArguments = @('-GitExe', $GitExeResolved)
    },
    [pscustomobject]@{
        Label = '04 Gparam gameparam'
        Script = '04_Global_BBReborne_Gparam_GameParam.ps1'
        WitchySettings = 'v2.4.0.1'
        WitchyExe = $WitchyBnd2401
        ExtraArguments = @('-WitchyBndExe', $WitchyBnd2401, '-GitExe', $GitExeResolved)
    },
    [pscustomobject]@{
        Label = '05 OBJ from diffs'
        Script = '05_Global_BBReborne_Obj_FromDiffs.ps1'
        WitchySettings = 'v2.14.4.5'
        WitchyExe = $WitchyBnd21445
        ExtraArguments = @('-WitchyBndExe', $WitchyBnd21445, '-FlverJsonToolExe', $FlverJsonToolExeResolved, '-GitExe', $GitExeResolved)
    },
    [pscustomobject]@{
        Label = '06 Param drawparam default'
        Script = '06_Global_BBReborne_Param_DefaultDrawparam.ps1'
        WitchySettings = 'v2.14.4.5'
        WitchyExe = $WitchyBnd21445
        ExtraArguments = @('-WitchyBndExe', $WitchyBnd21445, '-GitExe', $GitExeResolved)
    }
)

$overall = [System.Diagnostics.Stopwatch]::StartNew()
$results = [System.Collections.Generic.List[object]]::new()
$failed = $false

foreach ($step in $steps) {
    $scriptPath = Join-Path $ScriptsRoot $step.Script
    $scriptPath = Resolve-RequiredFile -Path $scriptPath -Label $step.Label
    $safeName = ($step.Script -replace '[^A-Za-z0-9_\.-]', '_')
    $logPath = Join-Path $runLogDir ($safeName + '.log.txt')

    Write-Stage ''
    Write-Stage "Running: $($step.Label)"

    Write-WitchySettingsForGlobalStep -Version $step.WitchySettings -WitchyExe $step.WitchyExe

    $result = Invoke-ChildScript `
        -PwshPath $PwshExe `
        -ScriptPath $scriptPath `
        -Label $step.Label `
        -LogPath $logPath `
        -ToolPathsPath $configPath `
        -GameRootPath $GameRoot `
        -OutputRootPath $OutputRoot `
        -CpuThrottleValue $CpuThrottle `
        -GpuThrottleValue $GpuThrottle `
        -ExtraArguments $step.ExtraArguments `
        -KeepWork:$KeepChildWork

    [void]$results.Add($result)

    if (-not $result.Ok) {
        $failed = $true
        if (-not $ContinueOnError) { break }
    }
}

$overall.Stop()

$summary = [pscustomobject]@{
    Ok                  = (-not $failed)
    StartedAt           = $stamp
    FinishedAt          = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    TotalElapsedSeconds = [Math]::Round($overall.Elapsed.TotalSeconds, 3)
    TotalElapsed        = $overall.Elapsed.ToString()
    CompletedSteps      = @($results | Where-Object { $_.Ok }).Count
    TotalSteps          = $steps.Count
    ConfigPath          = $configPath
    GameRoot            = $GameRoot
    OutputRoot          = $OutputRoot
    RunLogDir           = $runLogDir
    Results             = @($results)
}

$summaryJson = Join-Path $runLogDir 'global_run_summary.json'
$summaryCsv = Join-Path $runLogDir 'global_run_summary.csv'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryJson -Encoding UTF8
$results | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Encoding UTF8

Write-Stage ''
Write-Stage 'Global run summary'
Write-Info ("Completed: {0} / {1}" -f $summary.CompletedSteps, $summary.TotalSteps)
Write-Info ("Elapsed:   {0}" -f $summary.TotalElapsed)
Write-Info "Summary:   $summaryJson"
Write-Info "CSV:       $summaryCsv"
Write-Info "BBR_GLOBAL_REPORT|SummaryJson=$summaryJson|SummaryCsv=$summaryCsv|Completed=$($summary.CompletedSteps)|Total=$($summary.TotalSteps)|ElapsedSeconds=$($summary.TotalElapsedSeconds)"

if ($failed) {
    throw "Global run failed. Completed $($summary.CompletedSteps) / $($summary.TotalSteps). See: $summaryJson"
}
