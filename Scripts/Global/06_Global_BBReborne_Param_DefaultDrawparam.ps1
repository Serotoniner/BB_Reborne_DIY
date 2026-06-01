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
    06_Global_BBReborne_Param_DefaultDrawparam.ps1

    Applies generated XML patches to an original:
        default_drawparam.parambnd.dcx

    Flow:
    1) Copy OriginalArchive into a safe work folder under OutputDir.
    2) Extract with WitchyBND using the default_drawparam prompt flow:
           DOWN
           DOWN
           ENTER
           0
           ENTER
    3) Apply patches to:
           default_drawparam-parambnd-dcx\*.xml
    4) Repack/recompress the extracted folder with WitchyBND using:
           DOWN
           DOWN
           ENTER
           0
           ENTER
    5) Copy the resulting default_drawparam.parambnd.dcx to OutputDir or OutputArchive.

    Notes:
    - OriginalArchive and PatchDir are read-only inputs.
    - Work is done only under OutputDir\<WorkDirName>.
    - Only the safe scratch folder leaf named by -WorkDirName may be deleted/recreated.
#>

[CmdletBinding()]
param(
    [string]$ToolPathsPs1,
    [string]$GameRoot,
    [string]$OutputRoot,

    [string]$PatchDir,
    [string]$OriginalArchive,
    [string]$OutputDir,

    [Alias('WitchyBndExe')]
    [string]$WitchyBND,

    [string]$OutputArchive = "",
    [string]$GitExe = "git",

    [string]$WorkDirName = "_default_drawparam_patch_apply_work",

    [int]$StartupDelayMs = 1800,
    [int]$KeyDelayMs = 250,
    [int]$StepDelayMs = 700,
    [int]$ExtractTimeoutSeconds = 60,

    [switch]$PreferThreeWay,
    [switch]$DryRun,
    [switch]$KeepWork,
	
	# Accepted for global runner compatibility. This script does not use throttles.
	[int]$CpuThrottle = 0,
	[int]$GpuThrottle = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$global:PSNativeCommandUseErrorActionPreference = $false
$global:PSNativeCommandArgumentPassing = "Standard"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "This script requires PowerShell 7+. Run it with pwsh."
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic


function Get-OptionalVariableValue {
    param([Parameter(Mandatory=$true)][string]$Name)

    $var = Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $var) { return $null }
    return $var.Value
}

function Get-FirstConfigValue {
    param([Parameter(Mandatory=$true)][string[]]$Names)

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
        Write-Host "Using tool config: $configPath"

        . $configPath
        Get-Variable -Scope Local -Name 'BBR_*' -ErrorAction SilentlyContinue | ForEach-Object {
            Set-Variable -Name $_.Name -Value $_.Value -Scope Script
        }

        return $configPath
    }

    Write-Host "No tool config file found. Parameters must provide all required paths."
    return $null
}

function Get-BBReborneToolRoot {
    param([AllowNull()][string]$ConfigPath)

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $toolsDir = Split-Path -Parent $ConfigPath
        if ($toolsDir) {
            $root = Split-Path -Parent $toolsDir
            if ($root) { return $root }
        }
    }

    if ($PSScriptRoot) {
        $parent = Split-Path -Parent $PSScriptRoot
        if ($parent) {
            $grandParent = Split-Path -Parent $parent
            if ($grandParent) { return $grandParent }
        }
    }

    return $PSScriptRoot
}

function Resolve-RequiredDirectory {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label is empty." }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Label not found: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-RequiredFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label is empty." }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label not found: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-GameRootFromTool {
    param([Parameter(Mandatory=$true)][string]$Path)

    $resolved = Resolve-RequiredDirectory -Path $Path -Label 'Game root'
    $leaf = Split-Path -Leaf ($resolved.TrimEnd('\', '/'))
    if ($leaf -ne 'dvdroot_ps4') {
        throw "Game root must end with dvdroot_ps4. Current path: $resolved"
    }

    return $resolved
}

function Resolve-ToolFileFromConfigOrSearch {
    param(
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][string[]]$VariableNames,
        [Parameter(Mandatory=$true)][string]$SearchRoot,
        [Parameter(Mandatory=$true)][string]$FileName,
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


function Assert-File([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Name not found: $Path" }
}

function Assert-Dir([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Name not found: $Path" }
}

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Assert-SafeScratchFolder([string]$Path, [string]$ExpectedLeaf) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $leaf = [IO.Path]::GetFileName($full)
    if ($leaf -ne $ExpectedLeaf) {
        throw "Refusing to clean scratch folder because its leaf is not '$ExpectedLeaf': $full"
    }
}

function Reset-ScratchFolder([string]$Path, [string]$ExpectedLeaf) {
    Assert-SafeScratchFolder -Path $Path -ExpectedLeaf $ExpectedLeaf
    if (Test-Path -LiteralPath $Path -PathType Container) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    Ensure-Dir $Path
}

function Test-IsSameOrUnderPath([string]$Child, [string]$Parent) {
    $childFull = [IO.Path]::GetFullPath($Child).TrimEnd('\', '/')
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')

    if ($childFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }

    return (
        $childFull.StartsWith($parentFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        $childFull.StartsWith($parentFull + [IO.Path]::AltDirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    )
}

function ConvertTo-PosixPath([string]$Path) {
    return (($Path -replace '\\','/').TrimStart('/'))
}

function Get-ArchiveExtractFolderLeaf([string]$ArchiveLeaf) {
    return ($ArchiveLeaf -replace '\.', '-')
}

function Send-KeySequence {
    param(
        [Parameter(Mandatory=$true)][string[]]$Keys,
        [int]$KeyDelayMs = 250
    )

    foreach ($k in $Keys) {
        [System.Windows.Forms.SendKeys]::SendWait($k)
        Start-Sleep -Milliseconds $KeyDelayMs
    }
}

function Invoke-WitchyDefaultDrawparamPrompt {
    param(
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][string]$TargetPath,
        [int]$StartupDelayMs = 1800,
        [int]$KeyDelayMs = 250,
        [int]$StepDelayMs = 700
    )

    Assert-File $script:WitchyBND "WitchyBND"
    if (-not (Test-Path -LiteralPath $TargetPath)) { throw "TargetPath not found: $TargetPath" }

    Write-Host ""
    Write-Host $Label -ForegroundColor Cyan
    Write-Host "  Sending prompt sequence: DOWN, DOWN, ENTER, wait, 0, ENTER" -ForegroundColor DarkGray

    $proc = Start-Process `
        -FilePath $script:WitchyBND `
        -ArgumentList @($TargetPath) `
        -PassThru `
        -WindowStyle Normal

    Start-Sleep -Milliseconds $StartupDelayMs

    [void][Microsoft.VisualBasic.Interaction]::AppActivate($proc.Id)
    Start-Sleep -Milliseconds 300

    # User-supplied flow for this archive:
    #   DOWN
    #   DOWN
    #   ENTER
    #   wait
    #   0
    #   ENTER
    Send-KeySequence -Keys @("{DOWN}", "{DOWN}", "~") -KeyDelayMs $KeyDelayMs
    Start-Sleep -Milliseconds $StepDelayMs
    Send-KeySequence -Keys @("0", "~") -KeyDelayMs $KeyDelayMs

    $proc.WaitForExit()

    if ($proc.ExitCode -ne 0) {
        throw "${Label} failed with exit code $($proc.ExitCode)"
    }
}

function Invoke-WitchyExtractDefaultDrawparam {
    param([Parameter(Mandatory=$true)][string]$TargetArchive)

    Invoke-WitchyDefaultDrawparamPrompt `
        -Label "Extract default_drawparam with WitchyBND" `
        -TargetPath $TargetArchive `
        -StartupDelayMs $StartupDelayMs `
        -KeyDelayMs $KeyDelayMs `
        -StepDelayMs $StepDelayMs
}

function Invoke-WitchyRepackDefaultDrawparam {
    param([Parameter(Mandatory=$true)][string]$ExtractFolder)

    Invoke-WitchyDefaultDrawparamPrompt `
        -Label "Repack default_drawparam with WitchyBND" `
        -TargetPath $ExtractFolder `
        -StartupDelayMs $StartupDelayMs `
        -KeyDelayMs $KeyDelayMs `
        -StepDelayMs $StepDelayMs
}

function Wait-ForExtractDir {
    param(
        [Parameter(Mandatory=$true)][string]$ExtractDir,
        [int]$TimeoutSeconds = 60
    )

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path -LiteralPath $ExtractDir -PathType Container) { return }
        Start-Sleep -Milliseconds 250
    }

    throw "Timed out waiting for extracted folder: $ExtractDir"
}

function Get-APathFromPatchHeader([string]$PatchPath) {
    $lines = Get-Content -LiteralPath $PatchPath -TotalCount 80
    foreach ($line in $lines) {
        if ($line -notmatch '^diff --git\s+') { continue }

        $m = [regex]::Match($line, '^diff --git\s+("([^"]+)"|(\S+))\s+("([^"]+)"|(\S+))\s*$')
        if (-not $m.Success) { return $null }
        if ($m.Groups[2].Success) { return $m.Groups[2].Value }
        return $m.Groups[3].Value
    }

    return $null
}

function Get-JsonOrXmlRelFromPatch([string]$PatchPath) {
    $aToken = Get-APathFromPatchHeader $PatchPath
    if (-not $aToken) { return $null }

    $p = $aToken -replace '\\','/'
    $p = $p -replace '^(a|b)/',''
    return $p
}

function Find-DefaultDrawparamPatches([string]$Root) {
    $rootFull = [IO.Path]::GetFullPath($Root)
    $found = [System.Collections.Generic.List[object]]::new()

    function Add-PatchesFromDir([string]$Dir, [bool]$Recursive) {
        if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }

        $gci = @{ LiteralPath=$Dir; File=$true; Filter="*.patch"; ErrorAction="SilentlyContinue" }
        if ($Recursive) { $gci.Recurse = $true }

        Get-ChildItem @gci |
            Where-Object { $_.Length -gt 0 } |
            Where-Object { $_.FullName -notmatch '\\(_default_drawparam_patch_apply_work|_patch_apply_work|_patch_work)\\' } |
            ForEach-Object { [void]$found.Add($_) }
    }

    if ((Split-Path -Leaf $rootFull) -eq "_patches") {
        Add-PatchesFromDir -Dir $rootFull -Recursive $false
    }

    $directChild = Join-Path $rootFull "_patches"
    if (Test-Path -LiteralPath $directChild -PathType Container) {
        Add-PatchesFromDir -Dir $directChild -Recursive $false
    }

    $defaultPatchDir = Join-Path (Join-Path $rootFull "default_drawparam-parambnd-dcx") "_patches"
    if (Test-Path -LiteralPath $defaultPatchDir -PathType Container) {
        Add-PatchesFromDir -Dir $defaultPatchDir -Recursive $false
    }

    $filesPatchDir = Join-Path (Join-Path (Join-Path $rootFull "files") "default_drawparam-parambnd-dcx") "_patches"
    if (Test-Path -LiteralPath $filesPatchDir -PathType Container) {
        Add-PatchesFromDir -Dir $filesPatchDir -Recursive $false
    }

    if ($found.Count -eq 0) {
        Add-PatchesFromDir -Dir $rootFull -Recursive $true
    }

    return @($found | Sort-Object FullName -Unique)
}

function Invoke-GitApplyPatch {
    param(
        [Parameter(Mandatory=$true)][string]$PatchPath,
        [Parameter(Mandatory=$true)][string]$WorkRoot,
        [switch]$PreferThreeWay
    )

    $xmlRel = Get-JsonOrXmlRelFromPatch $PatchPath
    if (-not $xmlRel) {
        throw "Could not read diff --git header from patch: $PatchPath"
    }

    $xmlRelWin = $xmlRel -replace '/', [IO.Path]::DirectorySeparatorChar
    $targetXml = Join-Path $WorkRoot $xmlRelWin

    if (-not (Test-Path -LiteralPath $targetXml -PathType Leaf)) {
        throw "Patch target XML is missing: $targetXml"
    }

    $backupXml = "$targetXml.__prepatch__"
    Copy-Item -LiteralPath $targetXml -Destination $backupXml -Force

    if ($PreferThreeWay) {
        $attempts = @(
            [pscustomobject]@{ Name="3way"; Args=@("apply", "-p1", "--3way", "--recount", "--whitespace=nowarn", "--", $PatchPath) },
            [pscustomobject]@{ Name="strict"; Args=@("apply", "-p1", "--recount", "--whitespace=nowarn", "--", $PatchPath) },
            [pscustomobject]@{ Name="ignore-space"; Args=@("apply", "-p1", "--recount", "--whitespace=nowarn", "--ignore-space-change", "--ignore-whitespace", "--", $PatchPath) },
            [pscustomobject]@{ Name="reject-diagnostic"; Args=@("apply", "-p1", "--reject", "--recount", "--whitespace=nowarn", "--", $PatchPath) }
        )
    }
    else {
        $attempts = @(
            [pscustomobject]@{ Name="strict"; Args=@("apply", "-p1", "--recount", "--whitespace=nowarn", "--", $PatchPath) },
            [pscustomobject]@{ Name="ignore-space"; Args=@("apply", "-p1", "--recount", "--whitespace=nowarn", "--ignore-space-change", "--ignore-whitespace", "--", $PatchPath) },
            [pscustomobject]@{ Name="3way"; Args=@("apply", "-p1", "--3way", "--recount", "--whitespace=nowarn", "--", $PatchPath) },
            [pscustomobject]@{ Name="reject-diagnostic"; Args=@("apply", "-p1", "--reject", "--recount", "--whitespace=nowarn", "--", $PatchPath) }
        )
    }

    $lastExit = $null
    $lastFirstLine = ""
    $lastAttempt = ""

    Push-Location -LiteralPath $WorkRoot
    try {
        foreach ($attempt in $attempts) {
            Copy-Item -LiteralPath $backupXml -Destination $targetXml -Force

            $oldRejects = @(Get-ChildItem -LiteralPath $WorkRoot -Recurse -File -Filter "*.rej" -ErrorAction SilentlyContinue)
            foreach ($rej in $oldRejects) { Remove-Item -LiteralPath $rej.FullName -Force -ErrorAction SilentlyContinue }

            $out = @(& $GitExe @($attempt.Args) 2>&1)
            $code = $LASTEXITCODE

            $lastExit = $code
            $lastFirstLine = (($out | Select-Object -First 1) -join "")
            $lastAttempt = $attempt.Name

            if ($code -eq 0 -and $attempt.Name -ne "reject-diagnostic") {
                Remove-Item -LiteralPath $backupXml -Force -ErrorAction SilentlyContinue
                return [pscustomobject]@{
                    Ok = $true
                    XmlRel = $xmlRel
                    PatchPath = $PatchPath
                    Attempt = $attempt.Name
                    Message = ""
                }
            }
        }
    }
    finally {
        Pop-Location
    }

    Copy-Item -LiteralPath $backupXml -Destination $targetXml -Force
    Remove-Item -LiteralPath $backupXml -Force -ErrorAction SilentlyContinue

    $rejects = @(Get-ChildItem -LiteralPath $WorkRoot -Recurse -File -Filter "*.rej" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

    return [pscustomobject]@{
        Ok = $false
        XmlRel = $xmlRel
        PatchPath = $PatchPath
        Attempt = $lastAttempt
        Message = "git apply failed. LastAttempt=$lastAttempt Exit=$lastExit Message=$lastFirstLine"
        RejectFiles = ($rejects -join ";")
    }
}


# -------------------- Tool harmonization --------------------

$configPath = Import-ToolConfig
$toolRoot = Get-BBReborneToolRoot -ConfigPath $configPath

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

$GameRoot = Resolve-GameRootFromTool -Path $GameRoot
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)

if (-not $PatchDir) {
    $PatchDir = Join-Path $toolRoot 'Diffs\param\drawparam\default_drawparam-parambnd-dcx\_patches'
}

if (-not $OriginalArchive) {
    $OriginalArchive = Join-Path $GameRoot 'param\drawparam\default_drawparam.parambnd.dcx'
}

if (-not $OutputDir) {
    $OutputDir = Join-Path (Join-Path $OutputRoot '_work') ("default_drawparam_apply_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

if ([string]::IsNullOrWhiteSpace($OutputArchive)) {
    $OutputArchive = Join-Path $OutputRoot 'BBReborne_param\param\drawparam\default_drawparam.parambnd.dcx'
}

if (-not $WitchyBND) {
    $WitchyBND = Resolve-ToolFileFromConfigOrSearch `
        -Label 'WitchyBND v2.14.4.5' `
        -VariableNames @('BBR_WitchyBND_v2_14_4_5','BBR_WitchyBnd_v2_14_4_5','BBR_WitchyBND_v21445','BBR_WitchyBND_21445') `
        -SearchRoot (Join-Path $toolRoot 'Tools') `
        -FileName 'WitchyBND.exe' `
        -PathMustContain '2.14.4.5'
}

if (-not $GitExe -or $GitExe -eq 'git') {
    $configuredGit = Get-FirstConfigValue -Names @('BBR_GitExe', 'BBR_GitForWindowsExe')
    if ($configuredGit) {
        $GitExe = $configuredGit
    } else {
        $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $GitExe = $cmd.Source }
    }
}


$timer = [Diagnostics.Stopwatch]::StartNew()
$completed = $false
$hadFailure = $false

$patchRoot = [IO.Path]::GetFullPath($PatchDir)
$origArchive = [IO.Path]::GetFullPath($OriginalArchive)
$outRoot = [IO.Path]::GetFullPath($OutputDir)

Assert-Dir $patchRoot "PatchDir"
Assert-File $origArchive "OriginalArchive"
Assert-File $WitchyBND "WitchyBND"

if ([string]::IsNullOrWhiteSpace($OutputArchive)) {
    $OutputArchive = Join-Path $outRoot (Split-Path -Leaf $origArchive)
}
$outArchive = [IO.Path]::GetFullPath($OutputArchive)

if (Test-IsSameOrUnderPath -Child $outRoot -Parent $patchRoot) {
    throw "OutputDir must not be inside PatchDir. PatchDir is input and must stay clean: $patchRoot"
}
if (Test-IsSameOrUnderPath -Child $outRoot -Parent (Split-Path -Parent $origArchive)) {
    throw "OutputDir must not be inside the OriginalArchive folder. Keep output separate from input: $outRoot"
}

$workRoot = Join-Path $outRoot $WorkDirName
$archiveLeaf = Split-Path -Leaf $origArchive
$extractFolderLeaf = Get-ArchiveExtractFolderLeaf $archiveLeaf
$workArchive = Join-Path $workRoot $archiveLeaf
$extractDir = Join-Path $workRoot $extractFolderLeaf

try {
    Write-Host ("PatchDir:        {0}" -f $patchRoot)
    Write-Host ("OriginalArchive: {0}" -f $origArchive)
    Write-Host ("OutputDir:       {0}" -f $outRoot)
    Write-Host ("OutputArchive:   {0}" -f $outArchive)
    Write-Host ("WorkDir:         {0}" -f $workRoot)

    $patches = @(Find-DefaultDrawparamPatches -Root $patchRoot)

    Write-Host ("Found {0} non-empty default_drawparam patch file(s)." -f $patches.Count)
    if ($patches.Count -eq 0) { Write-Host "Nothing to do."; return }

    foreach ($p in $patches) {
        Write-Host ("  PATCH: {0}" -f $p.FullName)
    }

    if ($DryRun) {
        Write-Host "DRYRUN: stopping before extraction/apply."
        $completed = $true
        return
    }

    Ensure-Dir $outRoot
    Ensure-Dir (Split-Path -Parent $outArchive)
    Reset-ScratchFolder -Path $workRoot -ExpectedLeaf $WorkDirName

    Write-Host ""
    Write-Host "Stage #1: copying original archive into work folder..."
    Copy-Item -LiteralPath $origArchive -Destination $workArchive -Force

    Write-Host ""
    Write-Host "Stage #2: extracting original archive..."
    Invoke-WitchyExtractDefaultDrawparam -TargetArchive $workArchive
    Wait-ForExtractDir -ExtractDir $extractDir -TimeoutSeconds $ExtractTimeoutSeconds

    Write-Host ""
    Write-Host "Stage #3: applying XML patches..."

    $applyRows = [Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($p in $patches) {
        $n++
        Write-Progress -Activity "Apply default_drawparam XML patches" -Status ("{0}/{1}: {2}" -f $n, $patches.Count, $p.Name) -PercentComplete ([int](100.0 * $n / $patches.Count))
        $row = Invoke-GitApplyPatch -PatchPath $p.FullName -WorkRoot $workRoot -PreferThreeWay:$PreferThreeWay
        [void]$applyRows.Add($row)

        if (-not $row.Ok) {
            Write-Host ("  FAIL: {0}" -f $p.Name) -ForegroundColor Red
            Write-Host ("        {0}" -f $row.Message) -ForegroundColor Red
            if ($row.RejectFiles) { Write-Host ("        Rejects: {0}" -f $row.RejectFiles) -ForegroundColor Red }
        }
        else {
            Write-Host ("  OK: {0} [{1}]" -f $p.Name, $row.Attempt)
        }
    }
    Write-Progress -Activity "Apply default_drawparam XML patches" -Completed

    $applyManifest = Join-Path $workRoot "patch_apply_manifest.csv"
    $applyRows | Export-Csv -LiteralPath $applyManifest -NoTypeInformation -Encoding UTF8

    $failRows = @($applyRows | Where-Object { -not $_.Ok })
    if ($failRows.Count -gt 0) {
        throw "Patch apply failed for $($failRows.Count) patch(es). See: $applyManifest"
    }

    Write-Host ""
    Write-Host "Stage #4: recompressing patched folder..."
    Invoke-WitchyRepackDefaultDrawparam -ExtractFolder $extractDir

    if (-not (Test-Path -LiteralPath $workArchive -PathType Leaf)) {
        throw "Expected recompressed archive was not found: $workArchive"
    }

    Write-Host ""
    Write-Host "Stage #5: writing output archive..."
    Copy-Item -LiteralPath $workArchive -Destination $outArchive -Force

    Write-Host ""
    Write-Host "================ FINAL SUMMARY ================"
    Write-Host ("Patches applied: {0}" -f $patches.Count)
    Write-Host ("OutputArchive:   {0}" -f $outArchive)
    Write-Host ("Elapsed:         {0}" -f $timer.Elapsed.ToString())

    $completed = $true
}
catch {
    $hadFailure = $true
    throw
}
finally {
    Write-Host ""
    Write-Host "Stage #6: cleanup..."
    if ($DryRun) {
        Write-Host ("  DRY: would remove work folder: {0}" -f $workRoot)
    }
    elseif ($KeepWork -or $hadFailure -or -not $completed) {
        Write-Host ("  Keeping work folder: {0}" -f $workRoot)
        if ($hadFailure -or -not $completed) { Write-Host "  Kept because the run did not complete successfully." -ForegroundColor Yellow }
    }
    else {
        Assert-SafeScratchFolder -Path $workRoot -ExpectedLeaf $WorkDirName
        if (Test-Path -LiteralPath $workRoot -PathType Container) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force
            Write-Host ("  Removed: {0}" -f $workRoot)
        }
    }
}
