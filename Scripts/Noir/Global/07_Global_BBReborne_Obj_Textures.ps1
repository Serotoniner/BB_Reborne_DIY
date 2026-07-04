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
    07_Global_BBReborne_Obj_Textures.ps1

    NOIR FORK:
    - Intended save path: <BBReborneDIYTool>\Scripts\Noir\Global\07_Global_BBReborne_Obj_Textures.ps1
    - Writes final binders under <OutputRoot>\BBReborne_noir_obj\obj.
    - Uses Scripts\Noir\Textures for diffuse/data passes.
    - Passes -Noir to the diffuse pass when launched with -Noir.

    Embedded OBJ texture workflow for the BB Reborne DIY Tool.

    Purpose:
    - Enumerate all original object binders from <GameRoot>\obj by default.
    - If <OutputRoot>\BBReborne_noir_obj already contains a patched/copy of the same object from Noir Step 05, use that
      patched binder as the per-object source so earlier Noir Global OBJ diff patches are preserved.
    - Copy the selected binders into an isolated work folder.
    - Unpack copied object binders with the configured WitchyBND executable non-recursively.
      This avoids recursive ANIBND/TAE serialization and therefore avoids Paramdex prompts.
    - Find embedded .tpf/.tpf.dcx files inside the unpacked object folders.
    - Unpack only those TPF files to DDS folders.
    - Route embedded diffuse DDS files (*_a.dds, excluding *_l.dds) through the existing AI diffuse texture pass in output-only mode.
    - Route embedded data DDS files (*_n.dds, *_r.dds, *_s.dds, *_m.dds, excluding *_l.dds) through the existing linear texture pass in output-only mode.
    - Apply the linear-pass DDS outputs back onto the exact staged DDS paths by manifest before downstream shine-fix passes, so _r/_s fixes run on the upscaled DDS files.
    - Route embedded reflectance DDS files (*_r.dds) through the same reflectance-fix pass used by the main texture workflow.
    - Route embedded specular DDS files (*_s.dds) through the same specular-fix pass used by the main texture workflow.
    - Copy processed DDS files back into the unpacked object folders, preferring reflectance/specular outputs for _r/_s and falling back to the linear outputs when needed.
    - Repack only modified TPF folders first, remove their temporary extracted folders, then repack only object folders that actually had embedded DDS files routed through the texture passes.
    - Write final object binders under <OutputRoot>\BBReborne_noir_obj\obj.

    Original game files are never modified. Any cleanup is limited to this script's own
    work directory under <OutputRoot>\_work.
#>

[CmdletBinding()]
param(
    [string]$ToolPathsPs1,
    [string]$GameRoot,
    [string]$OutputRoot,
    [string]$SourceObjRoot,
    [string]$PatchDir,

    [string]$PwshExe,
    [string]$WitchyBndExe,
    [string]$TexconvExe,
    [string]$RealEsrganExe,
    [string]$RealEsrganModelName = '',
    [string]$RealEsrganModelFile = '',
    [string]$MagickExe,
    [string]$DiffuseScript,
    [string]$LinearScript,
    [string]$ReflectanceScript,
    [string]$SpecularScript,

    [string[]]$ObjectList = @(),
    [string]$ObjectFilter = '*.objbnd.dcx',
    [int]$CpuThrottle = 0,
    [int]$GpuThrottle = 0,
    [int]$WitchyBatchSize = 100,
    [ValidateSet('DirectConsole','StartProcessNoNewWindow','StartProcessVisible','StartProcessCmdKeepOpen','ShellDragDrop')]
    [string]$WitchyLaunchMode = 'ShellDragDrop',
    [switch]$StrictWitchyExitCode,

    [switch]$Noir,
    [switch]$DryRun,
    [switch]$KeepWork,
    [switch]$ContinueOnError,
    [switch]$NoUpscale,
    [switch]$ForceGameRootSource,
    [switch]$PauseOnError
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

function Get-FirstConfigValue {
    param([Parameter(Mandatory)][string[]]$Names)
    foreach ($name in $Names) {
        $value = Get-OptionalVariableValue -Name $name
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
    }
    return ''
}

function Resolve-OptionalToolPathsPs1 {
    if ($ToolPathsPs1) { return (Resolve-RequiredFile -Path $ToolPathsPs1 -Label 'Tool paths file') }

    $candidates = @(
        (Join-Path $PSScriptRoot '..\..\Tools\BBReborneDIYTool.paths.ps1'),
        (Join-Path $PSScriptRoot '..\Tools\BBReborneDIYTool.paths.ps1'),
        (Join-Path $PSScriptRoot 'Tools\BBReborneDIYTool.paths.ps1'),
        (Join-Path $PSScriptRoot 'BBReborneDIYTool.paths.ps1')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }

    return $null
}

function Get-BBReborneProjectRoot {
    param([AllowNull()][string]$ToolPathsFile)

    if (-not [string]::IsNullOrWhiteSpace($ToolPathsFile)) {
        $toolPathsFull = [IO.Path]::GetFullPath($ToolPathsFile)
        $toolRootFromFile = Split-Path -Parent $toolPathsFull
        if ((Split-Path -Leaf $toolRootFromFile) -ieq 'Tools') {
            return (Split-Path -Parent $toolRootFromFile)
        }
    }

    $scriptsRoot = Split-Path -Parent $PSScriptRoot
    if ($scriptsRoot) { return (Split-Path -Parent $scriptsRoot) }
    return (Split-Path -Parent $PSScriptRoot)
}

function Find-ToolFile {
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
        if (-not [string]::IsNullOrWhiteSpace([string]$value) -and (Test-Path -LiteralPath ([string]$value) -PathType Leaf)) {
            return (Resolve-Path -LiteralPath ([string]$value)).Path
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SearchRoot) -and (Test-Path -LiteralPath $SearchRoot -PathType Container)) {
        $matches = @(Get-ChildItem -LiteralPath $SearchRoot -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($PathMustContain)) {
            $matches = @($matches | Where-Object { $_.FullName -like "*$PathMustContain*" })
        }
        $matches = @($matches | Sort-Object FullName)
        if ($matches.Count -gt 0) { return $matches[0].FullName }
    }

    if ($AllowPathCommand) {
        $cmd = Get-Command $FileName -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) { return $cmd.Source }
    }

    throw "$Label was not found."
}

function Resolve-PwshPath {
    if ($PwshExe -and (Test-Path -LiteralPath $PwshExe -PathType Leaf)) { return (Resolve-Path -LiteralPath $PwshExe).Path }

    foreach ($varName in @('BBR_PowerShell7Exe', 'BBR_PwshExe', 'BBR_Pwsh7Exe')) {
        $value = Get-OptionalVariableValue -Name $varName
        if (-not [string]::IsNullOrWhiteSpace([string]$value) -and (Test-Path -LiteralPath ([string]$value) -PathType Leaf)) {
            return (Resolve-Path -LiteralPath ([string]$value)).Path
        }
    }

    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }

    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }

    throw 'PowerShell 7 executable was not found.'
}

function Get-RelativePathSafe {
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Full
    )

    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd([char[]]@('\','/'))
    $fullPath = [IO.Path]::GetFullPath($Full)
    if ($fullPath.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($baseFull.Length).TrimStart([char[]]@('\','/'))
    }
    return (Split-Path -Leaf $Full)
}

function ConvertTo-ObjectId {
    param([Parameter(Mandatory)][string]$Value)
    $leaf = Split-Path -Leaf $Value
    $n = $leaf.Trim()
    foreach ($suffix in @('.objbnd.dcx', '.objbnd', '.dcx')) {
        if ($n.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
            $n = $n.Substring(0, $n.Length - $suffix.Length)
        }
    }
    return $n.ToLowerInvariant()
}

function Get-ObjFolderNameFromDcxLeaf {
    param([Parameter(Mandatory)][string]$DcxLeaf)
    return ($DcxLeaf -replace '\.', '-')
}

function Get-ExpectedObjFolderPath {
    param([Parameter(Mandatory)][string]$DcxPath)
    return (Join-Path (Split-Path -Parent $DcxPath) (Get-ObjFolderNameFromDcxLeaf (Split-Path -Leaf $DcxPath)))
}

function ConvertTo-TextureStageFolderName {
    param(
        [Parameter(Mandatory)][string]$TpfFolder,
        [Parameter(Mandatory)][string]$DdsPath
    )

    $stem = [IO.Path]::GetFileNameWithoutExtension($DdsPath)
    $safeRelTpf = (Get-RelativePathSafe -Base $script:RunWorkDir -Full $TpfFolder) -replace '[\\/:*?"<>|]', '_'
    if ([string]::IsNullOrWhiteSpace($safeRelTpf)) { $safeRelTpf = '_root' }
    return (Join-Path $safeRelTpf ($stem + '-tpf-dcx'))
}

function Get-EmbeddedTextureKind {
    param([Parameter(Mandatory)][string]$DdsName)

    $stem = [IO.Path]::GetFileNameWithoutExtension($DdsName)

    # Preserve the existing map texture rule: low-res *_l variants are not upscaled.
    if ($stem -match '(?i)_l$') { return '' }

    if ($stem -match '(?i)_a(?:_|$)') { return 'Diffuse' }
    if ($stem -match '(?i)_(n|r|s|m)(?:_|$)') { return 'Data' }
    return ''
}

function Find-EmbeddedTpfFolders {
    param([Parameter(Mandatory)][string]$ObjectFolder)

    if (-not (Test-Path -LiteralPath $ObjectFolder -PathType Container)) { return @() }

    $folders = @(Get-ChildItem -LiteralPath $ObjectFolder -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Name -match '(?i)-tpf(?:-dcx)?$') -and
            @(Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.dds' -ErrorAction SilentlyContinue).Count -gt 0
        })

    return @($folders | Sort-Object FullName)
}

function Find-EmbeddedTpfFiles {
    param([Parameter(Mandatory)][string]$ObjectFolder)

    if (-not (Test-Path -LiteralPath $ObjectFolder -PathType Container)) { return @() }

    $files = @(Get-ChildItem -LiteralPath $ObjectFolder -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)\.tpf(\.dcx)?$' } |
        Sort-Object FullName)

    return @($files)
}

function Get-ExpectedPayloadFolderPath {
    param([Parameter(Mandatory)][string]$PayloadFilePath)

    return (Join-Path (Split-Path -Parent $PayloadFilePath) (Get-ObjFolderNameFromDcxLeaf (Split-Path -Leaf $PayloadFilePath)))
}

function Remove-SafeWorkSubdirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\','/'))
    $runRoot = [IO.Path]::GetFullPath($script:RunWorkDir).TrimEnd([char[]]@('\','/'))
    if (-not $full.StartsWith($runRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove directory outside OBJ texture work directory: $full"
    }

    Remove-Item -LiteralPath $full -Recurse -Force
}

function Find-ExpectedDdsOutput {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Resolve-Path -LiteralPath $Path).Path }

    $dir = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }

    $base = [IO.Path]::GetFileNameWithoutExtension($Path)
    $ext  = [IO.Path]::GetExtension($Path)

    foreach ($candidate in @(
        (Join-Path $dir ($base + $ext.ToLowerInvariant())),
        (Join-Path $dir ($base + $ext.ToUpperInvariant()))
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }

    try {
        $hit = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object {
                ([IO.Path]::GetFileNameWithoutExtension($_.Name) -ieq $base) -and
                ([IO.Path]::GetExtension($_.Name) -ieq $ext)
            } |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    } catch {}

    return $null
}

function Get-TexturePassOutRoot {
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [Parameter(Mandatory)][ValidateSet('Diffuse','Data','Reflectance','Specular')][string]$Kind
    )

    $rootFull = [IO.Path]::GetFullPath($RootDir).TrimEnd([char[]]@('\','/'))
    $rootLeaf = Split-Path $rootFull -Leaf
    $rootParent = Split-Path $rootFull -Parent

    if ($Kind -eq 'Diffuse') {
        return (Join-Path $rootParent ("{0}_upscaled_2x_ai_a_bc1_bc7" -f $rootLeaf))
    }
    if ($Kind -eq 'Reflectance') {
        return (Join-Path $rootParent ("{0}_reflectance_fix_r" -f $rootLeaf))
    }
    if ($Kind -eq 'Specular') {
        return (Join-Path $rootParent ("{0}_specular_fix_s" -f $rootLeaf))
    }

    return (Join-Path $rootParent ("{0}_upscaled_2x_data_magick_bc1_bc4_dx9bc4" -f $rootLeaf))
}

function Apply-TexturePassOutputsToStageRoot {
    param(
        [Parameter(Mandatory)][string]$OutRoot,
        [Parameter(Mandatory)][string]$StageRoot
    )

    if (-not (Test-Path -LiteralPath $OutRoot -PathType Container)) { return 0 }
    if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) { throw "StageRoot not found: $StageRoot" }

    $count = 0
    $files = @(Get-ChildItem -LiteralPath $OutRoot -Recurse -File -Filter '*.dds' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '[\\/](?:_work|_logs|_encode_tmp)(?:[\\/]|$)'
        })

    foreach ($f in $files) {
        $rel = Get-RelativePathSafe -Base $OutRoot -Full $f.FullName
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $dst = Join-Path $StageRoot $rel
        Ensure-Dir (Split-Path -Parent $dst)
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
        $count++
    }

    return $count
}

function Apply-LinearOutputsToStagedDataByManifest {
    param(
        [Parameter(Mandatory)][object[]]$DataManifest,
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$DataOutRoot,
        [Parameter(Mandatory)][string]$ReportPath
    )

    $result = [pscustomobject]@{
        Applied = 0
        Missing = 0
        ReportPath = $ReportPath
    }

    if ($DataManifest.Count -eq 0) { return $result }
    if (-not (Test-Path -LiteralPath $DataOutRoot -PathType Container)) {
        throw "Linear output root not found before applying staged data outputs: $DataOutRoot"
    }

    $missingRows = [System.Collections.Generic.List[object]]::new()
    $stageRootFull = [IO.Path]::GetFullPath($StageRoot).TrimEnd([char[]]@('\','/'))

    foreach ($entry in $DataManifest) {
        $stageDds = [string]$entry.StageDds
        $stageFull = [IO.Path]::GetFullPath($stageDds)

        if (-not $stageFull.StartsWith($stageRootFull, [StringComparison]::OrdinalIgnoreCase)) {
            [void]$missingRows.Add([pscustomobject]@{
                StageDds = $stageDds
                ExpectedOutput = ''
                Reason = 'StageDds is outside StageRoot'
            })
            continue
        }

        $rel = $stageFull.Substring($stageRootFull.Length).TrimStart([char[]]@('\','/'))
        $expected = Join-Path $DataOutRoot $rel
        $processed = Find-ExpectedDdsOutput -Path $expected

        if ([string]::IsNullOrWhiteSpace($processed) -or -not (Test-Path -LiteralPath $processed -PathType Leaf)) {
            [void]$missingRows.Add([pscustomobject]@{
                StageDds = $stageDds
                ExpectedOutput = $expected
                Reason = 'Linear pass output not found'
            })
            continue
        }

        Ensure-Dir (Split-Path -Parent $stageDds)
        Copy-Item -LiteralPath $processed -Destination $stageDds -Force
        $result.Applied++
    }

    $result.Missing = $missingRows.Count
    if ($missingRows.Count -gt 0) {
        $missingRows | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8
    }

    return $result
}

function Get-TexturePassOutputRootsForManifestEntry {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$DiffuseOutRoot,
        [Parameter(Mandatory)][string]$DataOutRoot,
        [Parameter(Mandatory)][string]$ReflectanceOutRoot,
        [Parameter(Mandatory)][string]$SpecularOutRoot
    )

    $stageDds = [string]$Entry.StageDds
    $stem = [IO.Path]::GetFileNameWithoutExtension($stageDds)

    if ([string]$Entry.Kind -eq 'Diffuse') { return @($DiffuseOutRoot) }
    if ($stem -match '(?i)_r(?:_|$)') {
        $roots = @()
        if (-not [string]::IsNullOrWhiteSpace($ReflectanceOutRoot)) { $roots += $ReflectanceOutRoot }
        if (-not [string]::IsNullOrWhiteSpace($DataOutRoot))        { $roots += $DataOutRoot }
        return @($roots)
    }
    if ($stem -match '(?i)_s(?:_|$)') {
        $roots = @()
        if (-not [string]::IsNullOrWhiteSpace($SpecularOutRoot)) { $roots += $SpecularOutRoot }
        if (-not [string]::IsNullOrWhiteSpace($DataOutRoot))     { $roots += $DataOutRoot }
        return @($roots)
    }

    return @($DataOutRoot)
}

function Get-TextureOutputForManifestEntry {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$DiffuseOutRoot,
        [Parameter(Mandatory)][string]$DataOutRoot,
        [Parameter(Mandatory)][string]$ReflectanceOutRoot,
        [Parameter(Mandatory)][string]$SpecularOutRoot
    )

    $stageDds = [string]$Entry.StageDds
    $stageFull = [IO.Path]::GetFullPath($stageDds)
    $stageRootFull = [IO.Path]::GetFullPath($StageRoot).TrimEnd([char[]]@('\','/'))

    if (-not $stageFull.StartsWith($stageRootFull, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $rel = $stageFull.Substring($stageRootFull.Length).TrimStart([char[]]@('\','/'))
    $candidateRoots = @(Get-TexturePassOutputRootsForManifestEntry -Entry $Entry -DiffuseOutRoot $DiffuseOutRoot -DataOutRoot $DataOutRoot -ReflectanceOutRoot $ReflectanceOutRoot -SpecularOutRoot $SpecularOutRoot)
    foreach ($baseOutRoot in $candidateRoots) {
        if ([string]::IsNullOrWhiteSpace($baseOutRoot)) { continue }
        $expected = Join-Path $baseOutRoot $rel
        $hit = Find-ExpectedDdsOutput -Path $expected
        if ($hit) { return $hit }
    }

    return $null
}

function Remove-SafeTexturePassOutput {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\','/'))
    $runRoot = [IO.Path]::GetFullPath($script:RunWorkDir).TrimEnd([char[]]@('\','/'))
    if (-not $full.StartsWith($runRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove texture pass output outside OBJ texture work directory: $full"
    }

    Remove-Item -LiteralPath $full -Recurse -Force
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][object[]]$Arguments,
        [Parameter(Mandatory)][string]$Label,
        [int[]]$AllowedExitCodes = @(0)
    )

    Write-Info ("  {0}" -f $Label)
    $out = @(& $Exe @Arguments 2>&1)
    $code = $LASTEXITCODE
    if ($AllowedExitCodes -notcontains $code) {
        foreach ($line in ($out | Select-Object -First 30)) { Write-Info ([string]$line) }
        throw "$Label failed with exit code $code."
    }
    return $out
}

function Invoke-PwshTextureScript {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][object[]]$Args
    )

    Write-Stage $Label
    & $script:PwshExeResolved -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Args
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "$Label failed with exit code $code." }
}


function ConvertTo-WitchyArgumentText {
    param([Parameter(Mandatory)][string[]]$Paths)

    return (($Paths | ForEach-Object {
        '"' + ($_ -replace '"', '\"') + '"'
    }) -join ' ')
}

function Get-WitchyBatchCallPlan {
    param([Parameter(Mandatory)][string[]]$Paths)

    $fullPaths = @($Paths | ForEach-Object { [IO.Path]::GetFullPath($_) })
    $parents = @($fullPaths | ForEach-Object { Split-Path -Parent $_ } | Sort-Object -Unique)

    if ($parents.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($parents[0])) {
        return [pscustomobject]@{
            WorkingDirectory = $parents[0]
            Arguments        = @($fullPaths | ForEach-Object { Split-Path -Leaf $_ })
            UsesLeafArgs     = $true
        }
    }

    return [pscustomobject]@{
        WorkingDirectory = ''
        Arguments        = $fullPaths
        UsesLeafArgs     = $false
    }
}

function Invoke-WitchyBndBatchDirect {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$LogFile
    )

    $fullPathArgs = @($Paths | ForEach-Object { [IO.Path]::GetFullPath($_) })
    $plan = Get-WitchyBatchCallPlan -Paths $Paths

    # ShellDragDrop intentionally mimics manual drag-and-drop onto WitchyBND:
    # - launch through ShellExecute instead of a console-hosted process
    # - pass full absolute file paths, not leaf names
    # - use WitchyBND's own folder as the process working directory
    # This avoids a different code path than manual drag/drop and keeps output next to each input binder.
    if ($WitchyLaunchMode -eq 'ShellDragDrop') {
        $callArgs = @($fullPathArgs)
        $workingDirectory = Split-Path -Parent $Exe
        $usesLeafArgs = $false
    } else {
        $callArgs = @($plan.Arguments)
        $workingDirectory = [string]$plan.WorkingDirectory
        $usesLeafArgs = [bool]$plan.UsesLeafArgs
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Targets: $($Paths.Count)")
    foreach ($p in $Paths) { $lines.Add("  $p") }
    $lines.Add("WitchyBND: $Exe")
    $lines.Add("Mode: $WitchyLaunchMode; no key sequence; no output capture")
    $lines.Add("WorkingDirectory: $workingDirectory")
    $lines.Add("UsesLeafArgs: $usesLeafArgs")
    $lines.Add("ArgumentsPassed:")
    foreach ($a in $callArgs) { $lines.Add("  $a") }
    try { $lines.Add("ConsoleOutputRedirectedBeforeCall: $([Console]::IsOutputRedirected)") } catch { $lines.Add("ConsoleOutputRedirectedBeforeCall: unknown") }
    $lines.Add('')
    $lines.Add('Note: WitchyBND output is intentionally not captured. In debug mode the child PowerShell stays open.')
    $lines.Add('')
    $lines | Set-Content -LiteralPath $LogFile -Encoding UTF8

    Write-Info ("  Witchy log: {0}" -f $LogFile)
    if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) {
        Write-Info ("  Witchy working dir: {0}" -f $workingDirectory)
    }
    Write-Info ("  Witchy launch mode: {0}" -f $WitchyLaunchMode)

    try {
        switch ($WitchyLaunchMode) {
            'DirectConsole' {
                if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) { Push-Location -LiteralPath $workingDirectory }
                try {
                    & $Exe @callArgs
                    $code = $LASTEXITCODE
                    if ($null -eq $code) { $code = 0 }
                } finally {
                    if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) { Pop-Location }
                }
            }

            'StartProcessNoNewWindow' {
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName = $Exe
                foreach ($arg in $callArgs) { [void]$psi.ArgumentList.Add($arg) }
                if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) { $psi.WorkingDirectory = $workingDirectory }
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $false
                $psi.RedirectStandardOutput = $false
                $psi.RedirectStandardError = $false

                $proc = [System.Diagnostics.Process]::new()
                $proc.StartInfo = $psi
                [void]$proc.Start()
                $proc.WaitForExit()
                $code = [int]$proc.ExitCode
            }

            'StartProcessVisible' {
                $argText = ConvertTo-WitchyArgumentText -Paths $callArgs
                Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value ("ArgumentText: {0}" -f $argText)
                $startParams = @{
                    FilePath    = $Exe
                    ArgumentList = $argText
                    PassThru    = $true
                    Wait        = $true
                    WindowStyle = 'Normal'
                }
                if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) { $startParams.WorkingDirectory = $workingDirectory }
                $proc = Start-Process @startParams
                $code = [int]$proc.ExitCode
            }

            'StartProcessCmdKeepOpen' {
                $argText = ConvertTo-WitchyArgumentText -Paths $callArgs
                $escapedExe = '"' + ($Exe -replace '"', '\"') + '"'
                $cmd = if ([string]::IsNullOrWhiteSpace($workingDirectory)) {
                    "$escapedExe $argText"
                } else {
                    "cd /d `"$workingDirectory`" && $escapedExe $argText"
                }
                Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value ("CmdKeepOpen: {0}" -f $cmd)
                $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', $cmd) -PassThru -Wait -WindowStyle Normal
                $code = [int]$proc.ExitCode
            }

            'ShellDragDrop' {
                $argText = ConvertTo-WitchyArgumentText -Paths $callArgs
                Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value ("ShellDragDropArgumentText: {0}" -f $argText)

                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName = $Exe
                $psi.Arguments = $argText
                if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) { $psi.WorkingDirectory = $workingDirectory }
                $psi.UseShellExecute = $true
                $psi.CreateNoWindow = $false
                $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal

                $proc = [System.Diagnostics.Process]::Start($psi)
                if ($null -eq $proc) { throw 'ShellExecute did not return a process handle for WitchyBND.' }
                $proc.WaitForExit()
                $code = [int]$proc.ExitCode
            }
        }
    } catch {
        $code = -9999
        Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value @(
            "ExitCode: $code",
            "Exception: $($_.Exception.Message)"
        )
        return $code
    }

    Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value ("ExitCode: {0}" -f $code)
    return [int]$code
}

function Invoke-WitchyBndPathBatch {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][int]$BatchNumber,
        [Parameter(Mandatory)][string]$LogsDir
    )

    Ensure-Dir $LogsDir
    $safePhase = ($Phase -replace '[^A-Za-z0-9_-]', '_')
    $logFile = Join-Path $LogsDir ("witchybnd_{0}_{1:0000}.log.txt" -f $safePhase, $BatchNumber)

    return Invoke-WitchyBndBatchDirect -Exe $Exe -Paths $Paths -LogFile $logFile
}

function Invoke-WitchyObjectUnpackBatches {
    param([Parameter(Mandatory)][object[]]$Jobs)

    if ($Jobs.Count -eq 0) { return }

    for ($start = 0; $start -lt $Jobs.Count; $start += $WitchyBatchSize) {
        $end = [Math]::Min($start + $WitchyBatchSize, $Jobs.Count)
        $batchJobs = @($Jobs[$start..($end - 1)])
        $batchPaths = @($batchJobs | ForEach-Object { $_.WorkDcx })
        $idx = [int]([Math]::Floor($start / $WitchyBatchSize) + 1)
        Write-Info ("  Batch {0}: object binders {1}-{2} ({3} file(s))" -f $idx, ($start + 1), $end, $batchPaths.Count)

        $code = Invoke-WitchyBndPathBatch `
            -Exe $WitchyBndExe `
            -Paths $batchPaths `
            -Phase 'obj_textures_unpack' `
            -BatchNumber $idx `
            -LogsDir $script:WitchyLogsDir

        $missing = @()
        foreach ($j in $batchJobs) {
            if (-not (Test-Path -LiteralPath $j.WorkFolder -PathType Container)) { $missing += $j.WorkFolder }
        }

        if ($StrictWitchyExitCode -and $code -ne 0) { throw "WitchyBND object unpack batch $idx failed with exit code $code." }
        if ($missing.Count -gt 0) { throw "Aborting: WitchyBND did not produce expected unpacked object folder(s). First missing: $($missing[0])" }
        if ($code -ne 0) { Write-Warning ("  WitchyBND exit code {0} tolerated because expected unpacked object folders exist." -f $code) }
    }
}


function Invoke-WitchyTpfUnpackBatches {
    param([Parameter(Mandatory)][object[]]$TpfJobs)

    if ($TpfJobs.Count -eq 0) { return }

    for ($start = 0; $start -lt $TpfJobs.Count; $start += $WitchyBatchSize) {
        $end = [Math]::Min($start + $WitchyBatchSize, $TpfJobs.Count)
        $batchJobs = @($TpfJobs[$start..($end - 1)])
        $batchPaths = @($batchJobs | ForEach-Object { $_.TpfFile })
        $idx = [int]([Math]::Floor($start / $WitchyBatchSize) + 1)
        Write-Info ("  Batch {0}: TPF files {1}-{2} ({3} file(s))" -f $idx, ($start + 1), $end, $batchPaths.Count)

        $code = Invoke-WitchyBndPathBatch `
            -Exe $WitchyBndExe `
            -Paths $batchPaths `
            -Phase 'obj_textures_tpf_unpack' `
            -BatchNumber $idx `
            -LogsDir $script:WitchyLogsDir

        $missing = @()
        foreach ($j in $batchJobs) {
            if (-not (Test-Path -LiteralPath $j.TpfFolder -PathType Container)) { $missing += $j.TpfFolder }
        }

        if ($StrictWitchyExitCode -and $code -ne 0) { throw "WitchyBND TPF unpack batch $idx failed with exit code $code." }
        if ($missing.Count -gt 0) { throw "Aborting: WitchyBND did not produce expected TPF folder(s). First missing: $($missing[0])" }
        if ($code -ne 0) { Write-Warning ("  WitchyBND exit code {0} tolerated because expected TPF folders exist." -f $code) }
    }
}

function Invoke-WitchyTpfRepackBatches {
    param([Parameter(Mandatory)][object[]]$TpfJobs)

    if ($TpfJobs.Count -eq 0) { return }

    for ($start = 0; $start -lt $TpfJobs.Count; $start += $WitchyBatchSize) {
        $end = [Math]::Min($start + $WitchyBatchSize, $TpfJobs.Count)
        $batchJobs = @($TpfJobs[$start..($end - 1)])
        $batchPaths = @($batchJobs | ForEach-Object { $_.TpfFolder })
        $idx = [int]([Math]::Floor($start / $WitchyBatchSize) + 1)
        Write-Info ("  Batch {0}: TPF folders {1}-{2} ({3} folder(s))" -f $idx, ($start + 1), $end, $batchPaths.Count)

        foreach ($j in $batchJobs) {
            if (-not (Test-Path -LiteralPath $j.TpfFolder -PathType Container)) { throw "Missing TPF folder before repack: $($j.TpfFolder)" }
            if (Test-Path -LiteralPath $j.TpfFile -PathType Leaf) { Remove-Item -LiteralPath $j.TpfFile -Force }
        }

        $code = Invoke-WitchyBndPathBatch `
            -Exe $WitchyBndExe `
            -Paths $batchPaths `
            -Phase 'obj_textures_tpf_repack' `
            -BatchNumber $idx `
            -LogsDir $script:WitchyLogsDir

        $missing = @()
        foreach ($j in $batchJobs) {
            if (-not (Test-Path -LiteralPath $j.TpfFile -PathType Leaf)) { $missing += $j.TpfFile }
        }

        if ($StrictWitchyExitCode -and $code -ne 0) { throw "WitchyBND TPF repack batch $idx failed with exit code $code." }
        if ($missing.Count -gt 0) { throw "Aborting: WitchyBND did not produce expected TPF file(s). First missing: $($missing[0])" }
        if ($code -ne 0) { Write-Warning ("  WitchyBND exit code {0} tolerated because expected TPF files exist." -f $code) }

        foreach ($j in $batchJobs) {
            Remove-SafeWorkSubdirectory -Path $j.TpfFolder
        }
    }
}

function Invoke-WitchyObjectRepackBatches {
    param([Parameter(Mandatory)][object[]]$Jobs)

    if ($Jobs.Count -eq 0) { return }

    for ($start = 0; $start -lt $Jobs.Count; $start += $WitchyBatchSize) {
        $end = [Math]::Min($start + $WitchyBatchSize, $Jobs.Count)
        $batchJobs = @($Jobs[$start..($end - 1)])
        $batchPaths = @($batchJobs | ForEach-Object { $_.WorkFolder })
        $idx = [int]([Math]::Floor($start / $WitchyBatchSize) + 1)
        Write-Info ("  Batch {0}: object folders {1}-{2} ({3} folder(s))" -f $idx, ($start + 1), $end, $batchPaths.Count)

        $code = Invoke-WitchyBndPathBatch `
            -Exe $WitchyBndExe `
            -Paths $batchPaths `
            -Phase 'obj_textures_repack' `
            -BatchNumber $idx `
            -LogsDir $script:WitchyLogsDir

        $missing = @()
        foreach ($j in $batchJobs) {
            if (-not (Test-Path -LiteralPath $j.WorkDcx -PathType Leaf)) { $missing += $j.WorkDcx }
        }

        if ($StrictWitchyExitCode -and $code -ne 0) { throw "WitchyBND object repack batch $idx failed with exit code $code." }
        if ($missing.Count -gt 0) { throw "Aborting: WitchyBND did not produce expected object binder(s). First missing: $($missing[0])" }
        if ($code -ne 0) { Write-Warning ("  WitchyBND exit code {0} tolerated because expected object binders exist." -f $code) }
    }
}

function Get-ObjectIdsFromPatchDir {
    param([AllowNull()][string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }

    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $patchFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.patch' -ErrorAction SilentlyContinue)

    foreach ($pf in $patchFiles) {
        try {
            $lines = @(Get-Content -LiteralPath $pf.FullName -TotalCount 40 -ErrorAction Stop)
            foreach ($line in $lines) {
                if ($line -match '(?i)(o\d{6})') { [void]$ids.Add($Matches[1].ToLowerInvariant()) }
            }
        } catch {}
    }

    return @($ids | Sort-Object)
}

function Build-ObjectJobs {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$FinalRoot,
        [string[]]$AllowedIds = @(),
        [AllowNull()][string]$OverlayRoot = '',
        [string[]]$OverlayAllowedIds = @()
    )

    # Important: the job list is built from SourceRoot, which should normally be
    # <GameRoot>\obj. This makes the embedded texture pass inspect every object binder,
    # not only the few binders already produced by the OBJ diff step.
    $sourceFiles = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Filter $ObjectFilter -ErrorAction SilentlyContinue | Sort-Object FullName)

    if ($AllowedIds -and $AllowedIds.Count -gt 0) {
        $allowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($id in $AllowedIds) { [void]$allowed.Add((ConvertTo-ObjectId $id)) }
        $sourceFiles = @($sourceFiles | Where-Object { $allowed.Contains((ConvertTo-ObjectId $_.Name)) })
    }

    # Output root structure intentionally mirrors the mod package layout:
    #   <OutputRoot>\BBReborne_noir_obj\obj\*.objbnd.dcx
    # SourceRoot is normally <GameRoot>\obj, so $rel is just the binder name for
    # root-level game object binders. Add the package "obj" folder explicitly
    # for final outputs and diff-backed overlays.
    $finalPayloadRoot = Join-Path $FinalRoot 'obj'

    $overlayFull = ''
    if (-not [string]::IsNullOrWhiteSpace($OverlayRoot) -and (Test-Path -LiteralPath $OverlayRoot -PathType Container)) {
        $overlayFull = [IO.Path]::GetFullPath((Join-Path $OverlayRoot 'obj')).TrimEnd([char[]]@('\','/'))
    }

    $overlayAllowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($OverlayAllowedIds)) {
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            [void]$overlayAllowed.Add((ConvertTo-ObjectId $id))
        }
    }

    $jobs = [System.Collections.Generic.List[object]]::new()
    foreach ($sf in $sourceFiles) {
        $rel = Get-RelativePathSafe -Base $SourceRoot -Full $sf.FullName
        $workDcx = Join-Path $script:WorkDcxRoot $rel
        $finalDcx = Join-Path $finalPayloadRoot $rel

        $effectiveSource = $sf.FullName
        $sourceKind = 'GameRoot'
        if (-not [string]::IsNullOrWhiteSpace($overlayFull)) {
            $overlayDcx = Join-Path $overlayFull $rel
            $objectId = ConvertTo-ObjectId $sf.Name

            # Only preserve an existing BBReborne_obj binder as an overlay when that
            # object also has an explicit OBJ diff. Files from previous OBJ texture
            # runs are intentionally ignored here so they can be refreshed from
            # GameRoot\obj instead of being treated as patched source material.
            if (($overlayAllowed.Count -gt 0) -and
                $overlayAllowed.Contains($objectId) -and
                (Test-Path -LiteralPath $overlayDcx -PathType Leaf) -and
                (-not ([IO.Path]::GetFullPath($overlayDcx).Equals([IO.Path]::GetFullPath($sf.FullName), [StringComparison]::OrdinalIgnoreCase)))) {
                $effectiveSource = (Resolve-Path -LiteralPath $overlayDcx).Path
                $sourceKind = 'PatchedOutputOverlay'
            }
        }

        [void]$jobs.Add([pscustomobject]@{
            SourceDcx    = $effectiveSource
            OriginalDcx  = $sf.FullName
            SourceKind   = $sourceKind
            RelativePath = $rel
            WorkDcx      = $workDcx
            WorkFolder   = Get-ExpectedObjFolderPath $workDcx
            FinalDcx     = $finalDcx
            ObjectId     = ConvertTo-ObjectId $sf.Name
        })
    }

    return @($jobs)
}

function Remove-SafeWorkDir {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\','/'))
    $safeParent = [IO.Path]::GetFullPath((Join-Path $script:OutputRootResolved '_work')).TrimEnd([char[]]@('\','/'))

    if (-not $full.StartsWith($safeParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove work directory outside OutputRoot\\_work: $full"
    }

    if (Test-Path -LiteralPath $full -PathType Container) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

# -------------------- Resolve paths --------------------
$configPath = Resolve-OptionalToolPathsPs1
if ($configPath) {
    Write-Info "Using tool config: $configPath"
    . $configPath
}

$projectRoot = Get-BBReborneProjectRoot -ToolPathsFile $configPath
$mainTexturesScriptRoot = Join-Path (Join-Path $projectRoot 'Scripts') 'Textures'
$noirTexturesScriptRoot = Join-Path (Join-Path (Join-Path $projectRoot 'Scripts') 'Noir') 'Textures'
$texturesScriptRoot = $mainTexturesScriptRoot
$toolRoot = Join-Path $projectRoot 'Tools'

if (-not $GameRoot) { $GameRoot = Get-FirstConfigValue -Names @('BBR_GameRoot') }
if (-not $OutputRoot) { $OutputRoot = Get-FirstConfigValue -Names @('BBR_OutputRoot','BBR_OutputFolder','BBR_ModdedOutputRoot') }
if (-not $PatchDir) { $PatchDir = Join-Path (Join-Path $projectRoot 'Diffs') 'obj\_patches' }

if (-not $WitchyBndExe) {
    $WitchyBndExe = Find-ToolFile -Label 'WitchyBND v2.14.4.5' -VariableNames @('BBR_WitchyBND_v2_14_4_5','BBR_WitchyBnd_v2_14_4_5','BBR_WitchyBND_v21445','BBR_WitchyBND_21445') -SearchRoot $toolRoot -FileName 'WitchyBND.exe' -PathMustContain '2.14.4.5'
}
if (-not $TexconvExe) {
    $TexconvExe = Find-ToolFile -Label 'texconv.exe' -VariableNames @('BBR_TexconvExe','BBR_DirectXTexTexconvExe') -SearchRoot $toolRoot -FileName 'texconv.exe'
}
if (-not $RealEsrganExe) {
    $RealEsrganExe = Find-ToolFile -Label 'Real-ESRGAN executable' -VariableNames @('BBR_RealEsrganExe','BBR_RealESRGANExe') -SearchRoot $toolRoot -FileName 'realesrgan-ncnn-vulkan.exe'
}
if (-not $MagickExe) {
    $MagickExe = Find-ToolFile -Label 'ImageMagick magick.exe' -VariableNames @('BBR_ImageMagickExe','BBR_MagickExe') -SearchRoot $toolRoot -FileName 'magick.exe' -AllowPathCommand
}
if (-not $DiffuseScript) { $DiffuseScript = Join-Path $noirTexturesScriptRoot '01_Mapfiles_BBReborne_Textures_Upscale_Diffuse_2x_AI.ps1' }
if (-not $LinearScript) { $LinearScript = Join-Path $noirTexturesScriptRoot '02_Mapfiles_BBReborne_Textures_Upscale_Data_Linear_RGBA_BC1.ps1' }
if (-not $ReflectanceScript) { $ReflectanceScript = Join-Path $mainTexturesScriptRoot '04_Mapfiles_BBReborne_Textures_Reflectance_Fix.ps1' }
if (-not $SpecularScript) { $SpecularScript = Join-Path $mainTexturesScriptRoot '05_Mapfiles_BBReborne_Textures_Specular_Fix.ps1' }
if (-not $RealEsrganModelName) {
    $RealEsrganModelName = Get-FirstConfigValue -Names @('BBR_RealEsrganModelName','BBR_RealESRGANModelName')
}
if (-not $RealEsrganModelFile) {
    $RealEsrganModelFile = Get-FirstConfigValue -Names @('BBR_RealEsrganModelFile','BBR_RealESRGANModelFile')
}

$script:PwshExeResolved = Resolve-PwshPath
$GameRoot = Resolve-RequiredDirectory -Path $GameRoot -Label 'Game root'
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$script:OutputRootResolved = $OutputRoot
$WitchyBndExe = Resolve-RequiredFile -Path $WitchyBndExe -Label 'WitchyBND v2.14.4.5 executable'
$TexconvExe = Resolve-RequiredFile -Path $TexconvExe -Label 'texconv.exe'
$RealEsrganExe = Resolve-RequiredFile -Path $RealEsrganExe -Label 'Real-ESRGAN executable'
$MagickExe = Resolve-RequiredFile -Path $MagickExe -Label 'magick.exe'
$DiffuseScript = Resolve-RequiredFile -Path $DiffuseScript -Label 'Diffuse texture script'
$LinearScript = Resolve-RequiredFile -Path $LinearScript -Label 'Linear texture script'
$ReflectanceScript = Resolve-RequiredFile -Path $ReflectanceScript -Label 'Reflectance texture script'
$SpecularScript = Resolve-RequiredFile -Path $SpecularScript -Label 'Specular texture script'


# Same profile shape used by 08_Mapfiles_BBReborne_Textures.ps1, but with a single
# global object profile instead of per-map profiles.
$Profiles = @{
    obj = @{
        ReflectanceArgs = @(
            '-Mode', 'Knee',
            '-AutoKnee',
            '-KneeMin', '0.01',
            '-KneeMax', '1.00',
            '-SigmaLo', '0.0025',
            '-SigmaHi', '0.0125',
            '-PostScale', '0.75',
            '-HighlightStart', '0.35',
            '-MaxSpec', '0',
            '-FlatBrightMeanMin', '0.42',
            '-FlatBrightSigmaMax', '0.01',
            '-FlatBrightScale', '0.90'
        )
        SpecularArgs = @(
            '-Mode', 'Knee',
            '-AutoKnee',
            '-KneeMin', '0.80',
            '-KneeMax', '0.95',
            '-SigmaLo', '0.015',
            '-SigmaHi', '0.04',
            '-HighlightStart', '0.45',
            '-PostScale', '0.90',
            '-GlobalScale', '0.75',
            '-MaxSpec', '0.65'
        )
    }
}

$Profile = $Profiles.obj

if ($CpuThrottle -le 0) { $CpuThrottle = [Math]::Max(1, [Environment]::ProcessorCount - 2) }
if ($GpuThrottle -le 0) { $GpuThrottle = 1 }
if ($WitchyBatchSize -lt 1) { $WitchyBatchSize = 1 }
$script:ResolvedWitchyBatchSize = $WitchyBatchSize

$objOutputRoot = Join-Path $OutputRoot 'BBReborne_noir_obj'
$noirObjOverlayRoot = $objOutputRoot
Ensure-Dir $objOutputRoot

$defaultGameSource = Join-Path $GameRoot 'obj'

# Default to the full game object tree. The previous behavior preferred BBReborne_obj
# when it already contained the few OBJ diff outputs, which made this pass inspect only
# those patched objects. That missed embedded textures in the rest of GameRoot\obj.
if ([string]::IsNullOrWhiteSpace($SourceObjRoot)) {
    $SourceObjRoot = $defaultGameSource
}

$SourceObjRoot = Resolve-RequiredDirectory -Path $SourceObjRoot -Label 'Source OBJ root'

$allowedIds = @()
if ($ObjectList -and $ObjectList.Count -gt 0) {
    $allowedIds = @($ObjectList | ForEach-Object { ConvertTo-ObjectId $_ } | Sort-Object -Unique)
}

$diffBackedOverlayIds = @()
if (-not [string]::IsNullOrWhiteSpace($PatchDir) -and (Test-Path -LiteralPath $PatchDir -PathType Container)) {
    $diffBackedOverlayIds = @(Get-ObjectIdsFromPatchDir -Root $PatchDir | ForEach-Object { ConvertTo-ObjectId $_ } | Sort-Object -Unique)
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:RunWorkDir = Join-Path (Join-Path $OutputRoot '_work') "noir_obj_textures_$stamp"
$script:WorkDcxRoot = Join-Path $script:RunWorkDir 'dcx'
$stageRoot = Join-Path $script:RunWorkDir 'texture_stage'
$manifestPath = Join-Path $script:RunWorkDir 'embedded_texture_manifest.csv'
$script:WitchyLogsDir = Join-Path $script:RunWorkDir 'logs'

Write-Info "GameRoot       = $GameRoot"
Write-Info "OutputRoot     = $OutputRoot"
Write-Info "SourceObjRoot  = $SourceObjRoot"
Write-Info "OutputObjRoot  = $objOutputRoot"
Write-Info ("NoUpscale      = {0}" -f ([bool]$NoUpscale))
Write-Info "NoirObjOverlay = $noirObjOverlayRoot"
Write-Info "Noir          = $Noir"
Write-Info "Overlay source = existing files in NoirObjOverlay are used only for object IDs with OBJ diffs"
Write-Info "PatchDir       = $PatchDir"
Write-Info ("Diff-backed overlay IDs = {0}" -f $diffBackedOverlayIds.Count)
Write-Info "WitchyBND v2.14 = $WitchyBndExe"
Write-Info "Texconv        = $TexconvExe"
Write-Info "RealESRGAN     = $RealEsrganExe"
Write-Info "Magick         = $MagickExe"
Write-Info "DiffuseScript  = $DiffuseScript"
Write-Info "LinearScript   = $LinearScript"
Write-Info "ReflectanceScript = $ReflectanceScript"
Write-Info "SpecularScript    = $SpecularScript"
Write-Info "CpuThrottle    = $CpuThrottle"
Write-Info "GpuThrottle    = $GpuThrottle"
Write-Info "WitchyBatch    = $WitchyBatchSize"
Write-Info 'WitchyBatchNote= non-recursive object unpack + TPF-only recursive-free extraction; ANIBND/TAE are not parsed'
Write-Info ("ReflectanceArgs = {0}" -f ($Profile.ReflectanceArgs -join ' '))
Write-Info ("SpecularArgs    = {0}" -f ($Profile.SpecularArgs -join ' '))
Write-Info "WitchyMode     = $WitchyLaunchMode"
if ($WitchyLaunchMode -eq 'ShellDragDrop') { Write-Info 'WitchyModeNote = ShellExecute + full absolute paths' }
Write-Info "WorkDir        = $script:RunWorkDir"
if ($allowedIds.Count -gt 0) { Write-Info ("Object filter   = {0}" -f ($allowedIds -join ', ')) } else { Write-Info "Object filter   = none; scanning all object binders from SourceObjRoot" }

$scriptSw = [System.Diagnostics.Stopwatch]::StartNew()
$hadFailure = $false
$success = $false

try {
    Write-Stage ''
    Write-Stage 'Stage #0: Build object texture job list...'
    $jobs = @(Build-ObjectJobs -SourceRoot $SourceObjRoot -FinalRoot $objOutputRoot -AllowedIds $allowedIds -OverlayRoot $noirObjOverlayRoot -OverlayAllowedIds $diffBackedOverlayIds)
    $overlayJobCount = @($jobs | Where-Object { $_.SourceKind -eq 'PatchedOutputOverlay' }).Count
    $gameRootJobCount = @($jobs | Where-Object { $_.SourceKind -eq 'GameRoot' }).Count
    Write-Info ("  Source object binders matched: {0}" -f $jobs.Count)
    Write-Info ("  Using diff-backed patched object binders from OutputObjRoot: {0}" -f $overlayJobCount)
    Write-Info ("  Refreshing/replacing from GameRoot object binders: {0}" -f $gameRootJobCount)

    if ($jobs.Count -eq 0) {
        if ($allowedIds.Count -gt 0) {
            Write-Warning 'No object binders matched the patch/object filter list. Nothing to do.'
        } else {
            Write-Info 'No object binders found. Nothing to do.'
        }
        $success = $true
        return
    }

    if ($DryRun) {
        foreach ($j in $jobs) { Write-Info ("  DRY: {0} -> {1}" -f $j.SourceDcx, $j.FinalDcx) }
        $success = $true
        return
    }

    foreach ($dir in @($script:RunWorkDir, $script:WorkDcxRoot, $stageRoot, $objOutputRoot, $script:WitchyLogsDir)) { Ensure-Dir $dir }

    Write-Stage ''
    Write-Stage 'Stage #1: Copy object binders into isolated work folder...'
    foreach ($j in $jobs) {
        Ensure-Dir (Split-Path -Parent $j.WorkDcx)
        Copy-Item -LiteralPath $j.SourceDcx -Destination $j.WorkDcx -Force
        Write-Info ("  Copied: {0} [{1}]" -f $j.RelativePath, $j.SourceKind)
    }

    Write-Stage ''
    Write-Stage ("Stage #2A: Unpack object binders with WitchyBND v2.14.4.5 non-recursively (batchSize={0})..." -f $WitchyBatchSize)
    Write-Info '  This must use Witchy Recursive=false so ANIBND/TAE remain payload files and Paramdex is never requested.'
    Invoke-WitchyObjectUnpackBatches -Jobs $jobs

    Write-Stage ''
    Write-Stage 'Stage #2B: Find and unpack only embedded TPF files...'
    $script:TpfJobs = [System.Collections.Generic.List[object]]::new()
    foreach ($j in $jobs) {
        $objectFolder = Get-ExpectedObjFolderPath $j.WorkDcx
        if (-not (Test-Path -LiteralPath $objectFolder -PathType Container)) {
            throw "Expected object folder not produced by WitchyBND: $objectFolder"
        }

        $tpfFiles = @(Find-EmbeddedTpfFiles -ObjectFolder $objectFolder)
        foreach ($tf in $tpfFiles) {
            [void]$script:TpfJobs.Add([pscustomobject]@{
                ObjectId   = $j.ObjectId
                ObjectJob  = $j
                TpfFile    = $tf.FullName
                TpfFolder  = Get-ExpectedPayloadFolderPath $tf.FullName
            })
        }
    }
    Write-Info ("  Embedded TPF files found: {0}" -f $script:TpfJobs.Count)
    if ($script:TpfJobs.Count -gt 0) {
        Invoke-WitchyTpfUnpackBatches -TpfJobs @($script:TpfJobs)
    }

    Write-Stage ''
    Write-Stage 'Stage #3: Stage embedded DDS files from extracted TPF folders for the existing texture passes...'
    $manifest = [System.Collections.Generic.List[object]]::new()
    $objectTextureSummary = [System.Collections.Generic.List[object]]::new()

    foreach ($j in $jobs) {
        $objectFolder = Get-ExpectedObjFolderPath $j.WorkDcx
        if (-not (Test-Path -LiteralPath $objectFolder -PathType Container)) {
            throw "Expected object folder not produced by WitchyBND: $objectFolder"
        }

        $tpfFolders = @(Find-EmbeddedTpfFolders -ObjectFolder $objectFolder)
        $diffuseCount = 0
        $dataCount = 0
        $skippedCount = 0

        foreach ($tpf in $tpfFolders) {
            $ddsFiles = @(Get-ChildItem -LiteralPath $tpf.FullName -File -Filter '*.dds' -ErrorAction SilentlyContinue | Sort-Object Name)
            foreach ($dds in $ddsFiles) {
                $kind = Get-EmbeddedTextureKind -DdsName $dds.Name
                if ([string]::IsNullOrWhiteSpace($kind)) {
                    $skippedCount++
                    continue
                }

                $stageRelFolder = ConvertTo-TextureStageFolderName -TpfFolder $tpf.FullName -DdsPath $dds.FullName
                $stageDir = Join-Path $stageRoot $stageRelFolder
                Ensure-Dir $stageDir
                $stageDds = Join-Path $stageDir $dds.Name
                Copy-Item -LiteralPath $dds.FullName -Destination $stageDds -Force

                if ($kind -eq 'Diffuse') { $diffuseCount++ } else { $dataCount++ }
                [void]$manifest.Add([pscustomobject]@{
                    ObjectId     = $j.ObjectId
                    RelativePath = $j.RelativePath
                    Kind         = $kind
                    OriginalDds  = $dds.FullName
                    StageDds     = $stageDds
                    TpfFolder    = $tpf.FullName
                })
            }
        }

        [void]$objectTextureSummary.Add([pscustomobject]@{
            ObjectId = $j.ObjectId
            Source = $j.SourceKind
            TpfFolders = $tpfFolders.Count
            Diffuse = $diffuseCount
            Data = $dataCount
            Skipped = $skippedCount
        })
    }

    $manifest | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8
    $objectTextureSummary | Format-Table -AutoSize
    Write-Info ("  Manifest: {0}" -f $manifestPath)
    Write-Info ("  Staged diffuse DDS: {0}" -f (@($manifest | Where-Object { $_.Kind -eq 'Diffuse' }).Count))
    Write-Info ("  Staged data DDS:    {0}" -f (@($manifest | Where-Object { $_.Kind -eq 'Data' }).Count))

    if ($manifest.Count -eq 0) {
        Write-Info 'No embedded _a/_n/_r/_s/_m DDS files found. Repacking is not needed; copied objects are unchanged.'
        $success = $true
        return
    }

    $relPathsWithTextures = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $manifest) { [void]$relPathsWithTextures.Add([string]$entry.RelativePath) }
    $jobsToRepack = @($jobs | Where-Object { $relPathsWithTextures.Contains([string]$_.RelativePath) })
    Write-Info ("  Object binders needing texture repack/write: {0}" -f $jobsToRepack.Count)

    # Do not ask the existing texture scripts to apply back to RootDir here.
    # For embedded OBJ textures the object step owns copy-back into the unpacked binder.
    # Running the texture passes in output-only mode also avoids their cleanup/apply logic
    # hiding generated DDS files before this script can map them back to the object TPFs.
    $textureScriptExtraArgs = @('-Keep', '-ForceRebuild')
    $noUpscaleArgs = @()
    if ($NoUpscale) {
        $noUpscaleArgs += '-NoUpscale'
        Write-Info '  NoUpscale active: diffuse and data texture passes will keep treatments but target 1x outputs.'
    }
    $noirArgs = @()
    if ($Noir) { $noirArgs += '-Noir' }

    $commonArgs = @(
        '-RootDir', $stageRoot,
        '-TexconvExe', $TexconvExe,
        '-MagickExe', $MagickExe
    )

    $diffuseOutRoot     = Get-TexturePassOutRoot -RootDir $stageRoot -Kind Diffuse
    $dataOutRoot         = Get-TexturePassOutRoot -RootDir $stageRoot -Kind Data
    $reflectanceOutRoot  = Get-TexturePassOutRoot -RootDir $stageRoot -Kind Reflectance
    $specularOutRoot     = Get-TexturePassOutRoot -RootDir $stageRoot -Kind Specular
    Write-Info "  Diffuse texture pass OutRoot:     $diffuseOutRoot"
    Write-Info "  Data texture pass OutRoot:        $dataOutRoot"
    Write-Info "  Reflectance texture pass OutRoot: $reflectanceOutRoot"
    Write-Info "  Specular texture pass OutRoot:    $specularOutRoot"

    $diffuseManifest = @($manifest | Where-Object { $_.Kind -eq 'Diffuse' })
    if ($diffuseManifest.Count -gt 0) {
        $realEsrganArgs = @('-RealEsrganExe', $RealEsrganExe, '-ThrottleLimit', ([string]$GpuThrottle))
        if (-not [string]::IsNullOrWhiteSpace($RealEsrganModelName)) { $realEsrganArgs += @('-RealEsrganModelName', $RealEsrganModelName) }
        if (-not [string]::IsNullOrWhiteSpace($RealEsrganModelFile)) { $realEsrganArgs += @('-RealEsrganModelFile', $RealEsrganModelFile) }

        Invoke-PwshTextureScript `
            -Label 'Stage #4: AI upscale embedded diffuse DDS files' `
            -ScriptPath $DiffuseScript `
            -Args ($commonArgs + $realEsrganArgs + $textureScriptExtraArgs + $noUpscaleArgs + $noirArgs)
    } else {
        Write-Info 'Stage #4: no embedded diffuse DDS files; skipping AI pass.'
    }

    $dataManifest = @($manifest | Where-Object { $_.Kind -eq 'Data' })
    $reflectanceManifest = @($manifest | Where-Object { ([IO.Path]::GetFileNameWithoutExtension([string]$_.StageDds)) -match '(?i)_r(?:_|$)' })
    $specularManifest    = @($manifest | Where-Object { ([IO.Path]::GetFileNameWithoutExtension([string]$_.StageDds)) -match '(?i)_s(?:_|$)' })

    if ($dataManifest.Count -gt 0) {
        Invoke-PwshTextureScript `
            -Label 'Stage #5: Linear upscale embedded data DDS files' `
            -ScriptPath $LinearScript `
            -Args ($commonArgs + @('-ThrottleLimit', ([string]$CpuThrottle)) + $textureScriptExtraArgs + $noUpscaleArgs)

        $linearApplyReport = Join-Path $script:RunWorkDir 'linear_apply_to_stage_missing.csv'
        $linearApplyResult = Apply-LinearOutputsToStagedDataByManifest `
            -DataManifest $dataManifest `
            -StageRoot $stageRoot `
            -DataOutRoot $dataOutRoot `
            -ReportPath $linearApplyReport

        Write-Info ("  Linear outputs applied back onto staged texture root for downstream shine fixes: {0}" -f $linearApplyResult.Applied)
        Write-Info ("  Linear outputs missing during staged copy-back: {0}" -f $linearApplyResult.Missing)

        if ($linearApplyResult.Applied -eq 0) {
            throw "Linear pass produced no manifest-mapped DDS outputs to apply back onto texture_stage. The _r/_s shine fixes would run on original staged DDS files. Report: $linearApplyReport"
        }
        if ($linearApplyResult.Missing -gt 0) {
            Write-Warning ("  Some linear outputs were missing before shine fixes. See: {0}" -f $linearApplyReport)
        }
    } else {
        Write-Info 'Stage #5: no embedded data DDS files; skipping linear pass.'
    }

    if ($reflectanceManifest.Count -gt 0) {
        Invoke-PwshTextureScript `
            -Label 'Stage #6: Fix embedded reflectance DDS files (_r)' `
            -ScriptPath $ReflectanceScript `
            -Args ($commonArgs + @('-ThrottleLimit', ([string]$CpuThrottle)) + $Profile.ReflectanceArgs + $textureScriptExtraArgs)
    } else {
        Write-Info 'Stage #6: no embedded reflectance DDS files; skipping reflectance fix pass.'
    }

    if ($specularManifest.Count -gt 0) {
        Invoke-PwshTextureScript `
            -Label 'Stage #7: Fix embedded specular DDS files (_s)' `
            -ScriptPath $SpecularScript `
            -Args ($commonArgs + @('-ThrottleLimit', ([string]$CpuThrottle)) + $Profile.SpecularArgs + $textureScriptExtraArgs)
    } else {
        Write-Info 'Stage #7: no embedded specular DDS files; skipping specular fix pass.'
    }

    Write-Stage ''
    Write-Stage 'Stage #8: Copy processed DDS files back into unpacked object folders...'
    $diffuseOutCount = if (Test-Path -LiteralPath $diffuseOutRoot -PathType Container) { @(Get-ChildItem -LiteralPath $diffuseOutRoot -Recurse -File -Filter '*.dds' -ErrorAction SilentlyContinue).Count } else { 0 }
    $dataOutCount = if (Test-Path -LiteralPath $dataOutRoot -PathType Container) { @(Get-ChildItem -LiteralPath $dataOutRoot -Recurse -File -Filter '*.dds' -ErrorAction SilentlyContinue).Count } else { 0 }
    $reflectanceOutCount = if (Test-Path -LiteralPath $reflectanceOutRoot -PathType Container) { @(Get-ChildItem -LiteralPath $reflectanceOutRoot -Recurse -File -Filter '*.dds' -ErrorAction SilentlyContinue).Count } else { 0 }
    $specularOutCount = if (Test-Path -LiteralPath $specularOutRoot -PathType Container) { @(Get-ChildItem -LiteralPath $specularOutRoot -Recurse -File -Filter '*.dds' -ErrorAction SilentlyContinue).Count } else { 0 }
    Write-Info ("  Diffuse OutRoot DDS count:     {0}" -f $diffuseOutCount)
    Write-Info ("  Data OutRoot DDS count:        {0}" -f $dataOutCount)
    Write-Info ("  Reflectance OutRoot DDS count: {0}" -f $reflectanceOutCount)
    Write-Info ("  Specular OutRoot DDS count:    {0}" -f $specularOutCount)

    if ($diffuseManifest.Count -gt 0 -and $diffuseOutCount -eq 0) {
        throw "Diffuse texture pass produced no DDS files in expected OutRoot: $diffuseOutRoot"
    }
    if ($dataManifest.Count -gt 0 -and $dataOutCount -eq 0) {
        throw "Linear texture pass produced no DDS files in expected OutRoot: $dataOutRoot"
    }
    if ($reflectanceManifest.Count -gt 0 -and $reflectanceOutCount -eq 0) {
        throw "Reflectance fix pass produced no DDS files in expected OutRoot: $reflectanceOutRoot"
    }
    if ($specularManifest.Count -gt 0 -and $specularOutCount -eq 0) {
        throw "Specular fix pass produced no DDS files in expected OutRoot: $specularOutRoot"
    }

    $copyBackCount = 0
    $unchangedFallbackCount = 0
    $copyBackFailures = [System.Collections.Generic.List[object]]::new()
    $copyBackFallbacks = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $manifest) {
        try {
            $processed = Get-TextureOutputForManifestEntry -Entry $entry -StageRoot $stageRoot -DiffuseOutRoot $diffuseOutRoot -DataOutRoot $dataOutRoot -ReflectanceOutRoot $reflectanceOutRoot -SpecularOutRoot $specularOutRoot
            if ([string]::IsNullOrWhiteSpace($processed) -or -not (Test-Path -LiteralPath $processed -PathType Leaf)) {
                if (-not (Test-Path -LiteralPath $entry.StageDds -PathType Leaf)) {
                    throw "Missing processed DDS output and missing staged fallback DDS: $($entry.StageDds)"
                }
                Copy-Item -LiteralPath $entry.StageDds -Destination $entry.OriginalDds -Force
                $unchangedFallbackCount++
                [void]$copyBackFallbacks.Add([pscustomobject]@{
                    OriginalDds = $entry.OriginalDds
                    StageDds    = $entry.StageDds
                    Kind        = $entry.Kind
                    Reason      = 'No processed DDS output was produced; original staged DDS was copied back unchanged.'
                })
                continue
            }
            Copy-Item -LiteralPath $processed -Destination $entry.OriginalDds -Force
            $copyBackCount++
        } catch {
            [void]$copyBackFailures.Add([pscustomobject]@{ OriginalDds=$entry.OriginalDds; StageDds=$entry.StageDds; Kind=$entry.Kind; Error=$_.Exception.Message })
            if (-not $ContinueOnError) { throw }
        }
    }
    Write-Info ("  DDS copied back from processed output: {0}" -f $copyBackCount)
    Write-Info ("  DDS copied back unchanged fallback:   {0}" -f $unchangedFallbackCount)
    if ($copyBackFallbacks.Count -gt 0) {
        $fallbackCsv = Join-Path $script:RunWorkDir 'copy_back_unchanged_fallbacks.csv'
        $copyBackFallbacks | Export-Csv -LiteralPath $fallbackCsv -NoTypeInformation -Encoding UTF8
        Write-Warning ("  Some texture pass outputs were missing; originals were preserved unchanged. See: {0}" -f $fallbackCsv)
    }
    if ($copyBackFailures.Count -gt 0) {
        $copyBackFailures | Export-Csv -LiteralPath (Join-Path $script:RunWorkDir 'copy_back_failures.csv') -NoTypeInformation -Encoding UTF8
        throw "DDS copy-back failures occurred: $($copyBackFailures.Count)"
    }

    Write-Stage ''
    Write-Stage ("Stage #9: Repack modified TPF folders first with WitchyBND v2.14.4.5 (batchSize={0})..." -f $WitchyBatchSize)
    $tpfFoldersWithTextures = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $manifest) { [void]$tpfFoldersWithTextures.Add([IO.Path]::GetFullPath([string]$entry.TpfFolder)) }
    $tpfJobsToRepack = @($script:TpfJobs | Where-Object { $tpfFoldersWithTextures.Contains([IO.Path]::GetFullPath([string]$_.TpfFolder)) })
    Write-Info ("  TPF files needing repack: {0}" -f $tpfJobsToRepack.Count)
    Invoke-WitchyTpfRepackBatches -TpfJobs $tpfJobsToRepack

    Write-Stage ''
    Write-Stage ("Stage #10: Repack object folders with WitchyBND v2.14.4.5 non-recursively (batchSize={0})..." -f $WitchyBatchSize)
    foreach ($j in $jobsToRepack) {
        if (-not (Test-Path -LiteralPath $j.WorkFolder -PathType Container)) { throw "Missing object folder before repack: $($j.WorkFolder)" }
        if (Test-Path -LiteralPath $j.WorkDcx -PathType Leaf) { Remove-Item -LiteralPath $j.WorkDcx -Force }
    }
    Invoke-WitchyObjectRepackBatches -Jobs $jobsToRepack

    Write-Stage ''
    Write-Stage 'Stage #11: Copy repacked object binders to BBReborne_obj\obj...'
    $written = 0
    $legacyRemoved = 0
    foreach ($j in $jobsToRepack) {
        if (-not (Test-Path -LiteralPath $j.WorkDcx -PathType Leaf)) { throw "Missing repacked object binder: $($j.WorkDcx)" }
        Ensure-Dir (Split-Path -Parent $j.FinalDcx)
        Copy-Item -LiteralPath $j.WorkDcx -Destination $j.FinalDcx -Force
        $written++
        Write-Info ("  Wrote: {0}" -f $j.FinalDcx)

        # Clean up files written by the older Step 07 bug directly under
        # BBReborne_obj\*.objbnd.dcx. Step 05 correctly writes under
        # BBReborne_obj\obj, and Step 07 must do the same.
        $legacyRootDcx = Join-Path $objOutputRoot (Split-Path -Leaf $j.FinalDcx)
        if ((Test-Path -LiteralPath $legacyRootDcx -PathType Leaf) -and
            (-not ([IO.Path]::GetFullPath($legacyRootDcx).Equals([IO.Path]::GetFullPath($j.FinalDcx), [StringComparison]::OrdinalIgnoreCase)))) {
            Remove-Item -LiteralPath $legacyRootDcx -Force
            $legacyRemoved++
        }
    }

    if ($legacyRemoved -gt 0) {
        Write-Warning ("  Removed legacy misplaced root-level object binders from BBReborne_obj: {0}" -f $legacyRemoved)
    }

    Write-Info "Embedded object texture pass complete. Output files written/replaced: $written"
    $success = $true
} catch {
    $hadFailure = $true
    $failureLog = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($script:RunWorkDir)) {
            Ensure-Dir $script:RunWorkDir
            $failureLog = Join-Path $script:RunWorkDir 'failure.txt'
            @(
                "Error: $($_.Exception.Message)",
                "Script: $PSCommandPath",
                "Time: $(Get-Date -Format o)",
                "WorkDir: $script:RunWorkDir"
            ) | Set-Content -LiteralPath $failureLog -Encoding UTF8
        }
    } catch {}

    Write-Error $_.Exception.Message
    if ($failureLog) { Write-Warning "Failure details written to: $failureLog" }
    if ($PauseOnError) {
        try { [void](Read-Host 'OBJ texture step failed. Press Enter to close this window') } catch {}
    }
    throw
} finally {
    Write-Stage ''
    Write-Stage 'Stage #12: Cleanup...'
    if ([string]::IsNullOrWhiteSpace($script:RunWorkDir)) {
        Write-Info '  Work folder was not initialized.'
    } elseif ($DryRun) {
        Write-Info "  DRY: would remove work folder: $script:RunWorkDir"
    } elseif ($KeepWork -or $hadFailure -or (-not $success)) {
        Write-Info "  Keeping work folder: $script:RunWorkDir"
        if ($hadFailure -or (-not $success)) { Write-Warning '  Kept because the run did not complete cleanly.' }
    } else {
        try {
            Remove-SafeWorkDir -Path $script:RunWorkDir
            Write-Info "  Removed: $script:RunWorkDir"
        } catch {
            Write-Warning $_.Exception.Message
        }
    }

    $scriptSw.Stop()
    Write-Info ("Elapsed: {0}" -f $scriptSw.Elapsed.ToString())
}
