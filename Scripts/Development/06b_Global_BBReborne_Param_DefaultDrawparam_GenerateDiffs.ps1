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
    06b_Global_BBReborne_Param_DefaultDrawparam_GenerateDiffs.ps1

    Specific patch generator for:
        default_drawparam.parambnd.dcx

    This archive extracts to:
        default_drawparam-parambnd-dcx\
            default_LodBank.param.xml
            ...
            _witchy-bnd4.xml   # skipped

    WitchyBND extraction uses the brittle version prompt flow:
        ENTER
        DOWN
        DOWN
        ENTER
        0
        ENTER

    Output layout:
        <OutputDir>\
            all_changed_default_drawparam_xml.patch
            compare_default_drawparam_xml.csv
            default_drawparam-parambnd-dcx\
                _patches\
                    default_LodBank.param.xml.patch

    Notes:
    - OldArchive/NewArchive are never modified.
    - Patch body lines are never path-rewritten.
    - Only git patch header lines are normalized.
    - Only the safe scratch folder named by -WorkDirName may be deleted/recreated.
#>

[CmdletBinding()]
param(
    [string]$ToolPathsPs1,
    [string]$GameRoot,
    [string]$OutputRoot,

    [string]$OldArchive,
    [string]$NewArchive,

    [Alias('WitchyBndExe')]
    [string]$WitchyBND,

    [string]$GitExe = "git",

    # Default: write to <BBReborneDIYTool>\Diffs\param\drawparam.
    [string]$OutputDir,

    # Scratch work stays outside Diffs by default.
    [string]$WorkRootOverride,

    [string]$WorkDirName = "_default_drawparam_patch_work",

    [int]$StartupDelayMs = 1800,
    [int]$KeyDelayMs = 250,
    [int]$StepDelayMs = 700,
    [int]$ExtractTimeoutSeconds = 60,

    [switch]$DryRun,
    [switch]$KeepWork
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

function ConvertTo-PosixPath([string]$Path) {
    return (($Path -replace '\\','/').TrimStart('/'))
}

function Get-ArchiveExtractFolderLeaf([string]$ArchiveLeaf) {
    # WitchyBND extraction naming for this archive:
    # default_drawparam.parambnd.dcx -> default_drawparam-parambnd-dcx
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

function Invoke-WitchyExtractDefaultDrawparam {
    param(
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][string]$TargetPath,
        [int]$StartupDelayMs = 1800,
        [int]$KeyDelayMs = 250,
        [int]$StepDelayMs = 700
    )

    Assert-File $script:WitchyBND "WitchyBND"
    Assert-File $TargetPath "TargetPath"

    Write-Host ""
    Write-Host $Label -ForegroundColor Cyan

    $proc = Start-Process `
        -FilePath $script:WitchyBND `
        -ArgumentList @($TargetPath) `
        -PassThru `
        -WindowStyle Normal

    Start-Sleep -Milliseconds $StartupDelayMs

    [void][Microsoft.VisualBasic.Interaction]::AppActivate($proc.Id)
    Start-Sleep -Milliseconds 300

    # Required flow for default_drawparam.parambnd.dcx extraction:
    # ENTER, wait, DOWN, DOWN, ENTER, wait, 0, ENTER
    #Send-KeySequence -Keys @("~") -KeyDelayMs $KeyDelayMs
    Start-Sleep -Milliseconds $StepDelayMs
    Send-KeySequence -Keys @("{DOWN}", "{DOWN}", "~") -KeyDelayMs $KeyDelayMs
    Start-Sleep -Milliseconds $StepDelayMs
    Send-KeySequence -Keys @("0", "~") -KeyDelayMs $KeyDelayMs

    $proc.WaitForExit()

    if ($proc.ExitCode -ne 0) {
        throw "${Label} failed with exit code $($proc.ExitCode)"
    }
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

function Get-XmlIndex {
    param([Parameter(Mandatory=$true)][string]$ExtractFolder)

    $rootFull = [IO.Path]::GetFullPath($ExtractFolder)
    $index = @{}

    Get-ChildItem -LiteralPath $rootFull -File -Filter "*.xml" -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            # Exclude Witchy metadata and only compare real XML payload files.
            $_.Name -notmatch '^(?i)_witchy.*\.xml$'
        } |
        ForEach-Object {
            $rel = [IO.Path]::GetRelativePath($rootFull, $_.FullName)
            $relPosix = ConvertTo-PosixPath $rel
            $key = $relPosix.ToLowerInvariant()
            if (-not $index.ContainsKey($key)) {
                $index[$key] = [pscustomobject]@{
                    Rel      = $rel
                    RelPosix = $relPosix
                    FullName = $_.FullName
                    Leaf     = $_.Name
                    Length   = [int64]$_.Length
                    Hash     = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        }

    return $index
}

function Normalize-GitNoIndexPatchHeaders {
    param(
        [Parameter(Mandatory=$true)][string]$InputPatch,
        [Parameter(Mandatory=$true)][string]$OutputPatch,
        [Parameter(Mandatory=$true)][string]$XmlRelPosix
    )

    # Only rewrite git patch header lines. Do NOT rewrite patch body lines.
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    $reader = [IO.StreamReader]::new($InputPatch, [Text.Encoding]::UTF8, $true)
    $writer = [IO.StreamWriter]::new($OutputPatch, $false, $utf8NoBom)

    $insideFileHeader = $false
    $sawMinusHeader = $false
    $sawPlusHeader = $false

    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.StartsWith("diff --git ")) {
                $writer.WriteLine(("diff --git a/{0} b/{0}" -f $XmlRelPosix))
                $insideFileHeader = $true
                $sawMinusHeader = $false
                $sawPlusHeader = $false
                continue
            }

            if ($insideFileHeader -and -not $sawMinusHeader -and $line.StartsWith("--- ")) {
                $writer.WriteLine(("--- a/{0}" -f $XmlRelPosix))
                $sawMinusHeader = $true
                continue
            }

            if ($insideFileHeader -and $sawMinusHeader -and -not $sawPlusHeader -and $line.StartsWith("+++ ")) {
                $writer.WriteLine(("+++ b/{0}" -f $XmlRelPosix))
                $sawPlusHeader = $true
                continue
            }

            if ($line.StartsWith("@@ ")) {
                $insideFileHeader = $false
            }

            $writer.WriteLine($line)
        }
    }
    finally {
        $reader.Dispose()
        $writer.Dispose()
    }
}

function Invoke-GitDiffRelativeToPatchFile {
    param(
        [Parameter(Mandatory=$true)][string]$GitExe,
        [Parameter(Mandatory=$true)][string]$WorkDir,
        [Parameter(Mandatory=$true)][string]$OldRelToWork,
        [Parameter(Mandatory=$true)][string]$NewRelToWork,
        [Parameter(Mandatory=$true)][string]$XmlRelPosix,
        [Parameter(Mandatory=$true)][string]$PatchPath
    )

    Ensure-Dir (Split-Path -Parent $PatchPath)

    $tmpRaw = "$PatchPath.raw.tmp"
    $tmpErr = "$PatchPath.err.tmp"
    $tmpNorm = "$PatchPath.norm.tmp"

    Remove-Item -LiteralPath $tmpRaw  -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpErr  -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpNorm -Force -ErrorAction SilentlyContinue

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $GitExe
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow = $true

    foreach ($arg in @(
        "diff",
        "--no-index",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--",
        $OldRelToWork,
        $NewRelToWork
    )) {
        [void]$psi.ArgumentList.Add([string]$arg)
    }

    $proc = [Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    [void]$proc.Start()

    $outStream = [IO.File]::Open($tmpRaw, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $errStream = [IO.File]::Open($tmpErr, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)

    try {
        $stdoutTask = $proc.StandardOutput.BaseStream.CopyToAsync($outStream)
        $stderrTask = $proc.StandardError.BaseStream.CopyToAsync($errStream)

        $proc.WaitForExit()
        [void]$stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
    }
    finally {
        $outStream.Dispose()
        $errStream.Dispose()
    }

    $code = [int]$proc.ExitCode

    if ($code -eq 1) {
        Normalize-GitNoIndexPatchHeaders -InputPatch $tmpRaw -OutputPatch $tmpNorm -XmlRelPosix $XmlRelPosix
        Move-Item -LiteralPath $tmpNorm -Destination $PatchPath -Force
        Remove-Item -LiteralPath $tmpRaw -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpErr -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ ExitCode=$code; Status="Different"; Error="" }
    }

    if ($code -eq 0) {
        Remove-Item -LiteralPath $tmpRaw  -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpErr  -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpNorm -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ ExitCode=$code; Status="Same"; Error="" }
    }

    $errText = ""
    if (Test-Path -LiteralPath $tmpErr -PathType Leaf) {
        $errText = Get-Content -LiteralPath $tmpErr -Raw -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        ExitCode = $code
        Status   = "Failed"
        Error    = ("git diff failed with exit code {0}. {1}" -f $code, (($errText -split "`r?`n") | Select-Object -First 1))
    }
}

function Append-FileToFile {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination
    )

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        Add-Content -LiteralPath $Destination -Value "" -Encoding UTF8
    }

    $appendOut = [IO.File]::Open($Destination, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $inFile = [IO.File]::OpenRead($Source)
        try { $inFile.CopyTo($appendOut) }
        finally { $inFile.Dispose() }
    }
    finally { $appendOut.Dispose() }
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

if (-not $OldArchive) {
    $OldArchive = Join-Path $GameRoot 'param\drawparam\default_drawparam.parambnd.dcx'
}

if (-not $NewArchive) {
    $NewArchive = Join-Path $OutputRoot 'BBReborne_param\param\drawparam\default_drawparam.parambnd.dcx'
}

if (-not $OutputDir) {
    $OutputDir = Join-Path $toolRoot 'Diffs\param\drawparam'
}

if (-not $WorkRootOverride) {
    $WorkRootOverride = Join-Path (Join-Path $OutputRoot '_work') ("default_drawparam_generate_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + "\" + $WorkDirName)
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
$success = $false

$oldArchiveFull = [IO.Path]::GetFullPath($OldArchive)
$newArchiveFull = [IO.Path]::GetFullPath($NewArchive)

Assert-File $oldArchiveFull "OldArchive"
Assert-File $newArchiveFull "NewArchive"
Assert-File $WitchyBND "WitchyBND"

if ((Split-Path -Leaf $oldArchiveFull) -ne "default_drawparam.parambnd.dcx") {
    Write-Host ("WARN: OldArchive leaf is not default_drawparam.parambnd.dcx: {0}" -f (Split-Path -Leaf $oldArchiveFull)) -ForegroundColor Yellow
}
if ((Split-Path -Leaf $newArchiveFull) -ne "default_drawparam.parambnd.dcx") {
    Write-Host ("WARN: NewArchive leaf is not default_drawparam.parambnd.dcx: {0}" -f (Split-Path -Leaf $newArchiveFull)) -ForegroundColor Yellow
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path (Split-Path -Parent $newArchiveFull) "files"
}
$outRoot = [IO.Path]::GetFullPath($OutputDir)

$workRoot = if (-not [string]::IsNullOrWhiteSpace($WorkRootOverride)) { [IO.Path]::GetFullPath($WorkRootOverride) } else { Join-Path $outRoot $WorkDirName }
$workA = Join-Path $workRoot "a"
$workB = Join-Path $workRoot "b"

$archiveLeaf = Split-Path -Leaf $newArchiveFull
$extractFolderLeaf = Get-ArchiveExtractFolderLeaf $archiveLeaf
$xmlRelRootPosix = ConvertTo-PosixPath $extractFolderLeaf

try {
    Write-Host ("OldArchive: {0}" -f $oldArchiveFull)
    Write-Host ("NewArchive: {0}" -f $newArchiveFull)
    Write-Host ("OutputDir:  {0}" -f $outRoot)
    Write-Host ("WorkDir:    {0}" -f $workRoot)

    if (-not $DryRun) {
        Ensure-Dir $outRoot
        Reset-ScratchFolder -Path $workRoot -ExpectedLeaf $WorkDirName
        Ensure-Dir $workA
        Ensure-Dir $workB
    }

    Write-Host ""
    Write-Host "Stage #0: checking archive hashes..."

    $oldHash = (Get-FileHash -LiteralPath $oldArchiveFull -Algorithm SHA256).Hash.ToLowerInvariant()
    $newHash = (Get-FileHash -LiteralPath $newArchiveFull -Algorithm SHA256).Hash.ToLowerInvariant()

    $archiveStatus = if ($oldHash -eq $newHash) { "Same" } else { "Changed" }
    $archiveCompare = [pscustomobject]@{
        Archive = "default_drawparam.parambnd.dcx"
        Status = $archiveStatus
        OldArchive = $oldArchiveFull
        NewArchive = $newArchiveFull
        OldHash = $oldHash
        NewHash = $newHash
    }

    if (-not $DryRun) {
        $archiveCompare | Export-Csv -LiteralPath (Join-Path $outRoot "compare_default_drawparam_archive.csv") -NoTypeInformation -Encoding UTF8
    }

    Write-Host ("Archive status: {0}" -f $archiveStatus)
    if ($archiveStatus -eq "Same") {
        Write-Host "Archive hashes are identical. No patch needed."
        $success = $true
        return
    }

    if ($DryRun) {
        Write-Host "DRYRUN: stopping after hash compare."
        $success = $true
        return
    }

    Write-Host ""
    Write-Host "Stage #1: copying archives into work folder..."

    $oldWorkArchive = Join-Path $workA $archiveLeaf
    $newWorkArchive = Join-Path $workB $archiveLeaf
    Copy-Item -LiteralPath $oldArchiveFull -Destination $oldWorkArchive -Force
    Copy-Item -LiteralPath $newArchiveFull -Destination $newWorkArchive -Force

    Write-Host ""
    Write-Host "Stage #2: extracting old/new archives with WitchyBND prompt flow..."

    Invoke-WitchyExtractDefaultDrawparam `
        -Label "Extract OLD default_drawparam" `
        -TargetPath $oldWorkArchive `
        -StartupDelayMs $StartupDelayMs `
        -KeyDelayMs $KeyDelayMs `
        -StepDelayMs $StepDelayMs

    Invoke-WitchyExtractDefaultDrawparam `
        -Label "Extract NEW default_drawparam" `
        -TargetPath $newWorkArchive `
        -StartupDelayMs $StartupDelayMs `
        -KeyDelayMs $KeyDelayMs `
        -StepDelayMs $StepDelayMs

    $oldExtractDir = Join-Path $workA $extractFolderLeaf
    $newExtractDir = Join-Path $workB $extractFolderLeaf

    Wait-ForExtractDir -ExtractDir $oldExtractDir -TimeoutSeconds $ExtractTimeoutSeconds
    Wait-ForExtractDir -ExtractDir $newExtractDir -TimeoutSeconds $ExtractTimeoutSeconds

    Write-Host ""
    Write-Host "Stage #3: comparing extracted XML files..."

    $oldXmlIndex = Get-XmlIndex -ExtractFolder $oldExtractDir
    $newXmlIndex = Get-XmlIndex -ExtractFolder $newExtractDir
    $xmlKeys = @($oldXmlIndex.Keys + $newXmlIndex.Keys | Sort-Object -Unique)

    if ($xmlKeys.Count -eq 0) {
        throw "No comparable XML files found under extracted folders."
    }

    $xmlRows = [Collections.Generic.List[object]]::new()

    foreach ($xmlKey in $xmlKeys) {
        $oldXml = if ($oldXmlIndex.ContainsKey($xmlKey)) { $oldXmlIndex[$xmlKey] } else { $null }
        $newXml = if ($newXmlIndex.ContainsKey($xmlKey)) { $newXmlIndex[$xmlKey] } else { $null }

        $xmlInsideRel = if ($null -ne $newXml) { $newXml.Rel } else { $oldXml.Rel }
        $xmlRel = Join-Path $extractFolderLeaf $xmlInsideRel
        $xmlRelPosix = ConvertTo-PosixPath $xmlRel

        $oldPath = if ($null -ne $oldXml) { $oldXml.FullName } else { "" }
        $newPath = if ($null -ne $newXml) { $newXml.FullName } else { "" }

        $status = "Same"
        if (-not $oldPath -and $newPath) { $status = "Added" }
        elseif ($oldPath -and -not $newPath) { $status = "Removed" }
        elseif ($oldXml.Hash -ne $newXml.Hash) { $status = "Changed" }

        [void]$xmlRows.Add([pscustomobject]@{
            XmlRel = $xmlRel
            XmlRelPosix = $xmlRelPosix
            XmlLeaf = Split-Path -Leaf $xmlRel
            Status = $status
            OldXml = $oldPath
            NewXml = $newPath
            OldHash = if ($null -ne $oldXml) { $oldXml.Hash } else { "" }
            NewHash = if ($null -ne $newXml) { $newXml.Hash } else { "" }
            PatchPath = ""
        })
    }

    $changedXmlRows = @($xmlRows | Where-Object { $_.Status -eq "Changed" } | Sort-Object XmlRel)
    $addedRemovedRows = @($xmlRows | Where-Object { $_.Status -in @("Added","Removed") })

    Write-Host ("XML compare done. Same={0} Changed={1} Added={2} Removed={3}" -f `
        @($xmlRows | Where-Object Status -eq "Same").Count,
        $changedXmlRows.Count,
        @($xmlRows | Where-Object Status -eq "Added").Count,
        @($xmlRows | Where-Object Status -eq "Removed").Count)

    if ($addedRemovedRows.Count -gt 0) {
        Write-Host ("  Note: Added/Removed XML files are listed in manifest but skipped for portable patch export: {0}" -f $addedRemovedRows.Count) -ForegroundColor Yellow
    }

    if ($changedXmlRows.Count -eq 0) {
        $xmlRows | Export-Csv -LiteralPath (Join-Path $outRoot "compare_default_drawparam_xml.csv") -NoTypeInformation -Encoding UTF8
        Write-Host "No changed XML files after extraction. No patches generated."
        $success = $true
        return
    }

    Write-Host ""
    Write-Host ("Stage #4: exporting Git patches for {0} XML file(s)..." -f $changedXmlRows.Count)

    $allPatch = Join-Path $outRoot "all_changed_default_drawparam_xml.patch"
    $allPatchTemp = Join-Path $workRoot "all_changed_default_drawparam_xml.patch.tmp"
    Remove-Item -LiteralPath $allPatchTemp -Force -ErrorAction SilentlyContinue

    $patchFailures = [Collections.Generic.List[object]]::new()
    $patchN = 0

    foreach ($r in $changedXmlRows) {
        $patchN++
        Write-Progress -Activity "Generate default_drawparam XML patches" -Status ("{0}/{1}: {2}" -f $patchN, $changedXmlRows.Count, $r.XmlRelPosix) -PercentComplete ([int](100.0 * $patchN / $changedXmlRows.Count))

        $patchDir = Join-Path (Join-Path $outRoot $extractFolderLeaf) "_patches"
        $patchPath = Join-Path $patchDir ($r.XmlLeaf + ".patch")
        Ensure-Dir $patchDir

        $patchTempPath = Join-Path $workRoot ("patch_" + ([IO.Path]::GetFileName($patchPath)) + ".tmp")
        Remove-Item -LiteralPath $patchTempPath -Force -ErrorAction SilentlyContinue

        $oldRelToWork = [IO.Path]::GetRelativePath($workRoot, $r.OldXml)
        $newRelToWork = [IO.Path]::GetRelativePath($workRoot, $r.NewXml)

        $diffResult = Invoke-GitDiffRelativeToPatchFile `
            -GitExe $GitExe `
            -WorkDir $workRoot `
            -OldRelToWork $oldRelToWork `
            -NewRelToWork $newRelToWork `
            -XmlRelPosix $r.XmlRelPosix `
            -PatchPath $patchTempPath

        if ([int]$diffResult.ExitCode -eq 1) {
            Move-Item -LiteralPath $patchTempPath -Destination $patchPath -Force
            $r.PatchPath = $patchPath
            Append-FileToFile -Source $patchPath -Destination $allPatchTemp
        }
        elseif ([int]$diffResult.ExitCode -eq 0) {
            Write-Host ("  WARN: {0} XML hashes differed, but git diff produced no patch." -f $r.XmlRelPosix) -ForegroundColor Yellow
        }
        else {
            [void]$patchFailures.Add([pscustomobject]@{
                XmlRel = $r.XmlRel
                Error = $diffResult.Error
            })
        }
    }
    Write-Progress -Activity "Generate default_drawparam XML patches" -Completed

    if ($patchFailures.Count -gt 0) {
        $failCsv = Join-Path $outRoot "patch_export_failures.csv"
        $patchFailures | Export-Csv -LiteralPath $failCsv -NoTypeInformation -Encoding UTF8
        throw "Patch export failed for $($patchFailures.Count) XML file(s). See: $failCsv"
    }

    if (Test-Path -LiteralPath $allPatchTemp -PathType Leaf) {
        Move-Item -LiteralPath $allPatchTemp -Destination $allPatch -Force
    }

    $xmlRows | Export-Csv -LiteralPath (Join-Path $outRoot "compare_default_drawparam_xml.csv") -NoTypeInformation -Encoding UTF8

    $patchCount = @($xmlRows | Where-Object { $_.PatchPath }).Count

    Write-Host ""
    Write-Host "================ FINAL SUMMARY ================"
    Write-Host ("XML-changing files: {0}" -f $changedXmlRows.Count)
    Write-Host ("Patch files written: {0}" -f $patchCount)
    Write-Host ("Output patch root:   {0}" -f $outRoot)
    Write-Host ("XML manifest:        {0}" -f (Join-Path $outRoot "compare_default_drawparam_xml.csv"))
    Write-Host ("Elapsed:             {0}" -f $timer.Elapsed.ToString())

    $success = $true
}
finally {
    Write-Host ""
    Write-Host "Stage #5: cleanup..."
    if ($DryRun) {
        Write-Host ("  DRY: would remove work folder: {0}" -f $workRoot)
    }
    elseif ($KeepWork -or -not $success) {
        Write-Host ("  Keeping work folder: {0}" -f $workRoot)
        if (-not $success) { Write-Host "  Kept because the run did not complete successfully." -ForegroundColor Yellow }
    }
    else {
        Assert-SafeScratchFolder -Path $workRoot -ExpectedLeaf $WorkDirName
        if (Test-Path -LiteralPath $workRoot -PathType Container) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force
            Write-Host ("  Removed: {0}" -f $workRoot)
        }
    }
}
