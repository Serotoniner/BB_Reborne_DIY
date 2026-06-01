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
    04_Global_BBReborne_Gparam_GameParam_GenerateDiffs.ps1

    Development/reference helper for generating gameparam XML patch files used by:
        04_Global_BBReborne_Gparam_GameParam.ps1

    Purpose:
    - Extract the original gameparam archive from the configured game folder using the original Extract_gameparam key flow.
    - Extract a changed gameparam archive, or use an already-extracted changed folder.
    - Compare original XML files against changed XML files.
    - Generate portable Git patch files under:
        <BBReborneDIYTool>\Diffs\param\gameparam\gameparam-parambnd-dcx\_patches

    This script is for development/reference only and is not intended to be called by the DIY Tool UI.

    Typical use with the generated/modded archive from the output folder:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\04_Global_BBReborne_Gparam_GameParam_GenerateDiffs.ps1 `
            -ToolPathsPs1 "<BBReborneDIYTool>\Tools\BBReborneDIYTool.paths.ps1"

    Typical use with an explicit changed archive:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\04_Global_BBReborne_Gparam_GameParam_GenerateDiffs.ps1 `
            -ToolPathsPs1 "<BBReborneDIYTool>\Tools\BBReborneDIYTool.paths.ps1" `
            -ChangedArchive "<PathToChanged>\gameparam.parambnd.dcx"

    Typical use with an already extracted changed folder:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\04_Global_BBReborne_Gparam_GameParam_GenerateDiffs.ps1 `
            -ToolPathsPs1 "<BBReborneDIYTool>\Tools\BBReborneDIYTool.paths.ps1" `
            -ChangedExtractDir "<PathToChangedExtractedFolder>"

    Notes:
    - This script never modifies original game files.
    - This script creates and cleans only its own temporary work folder under the system temp folder.
    - It does not wipe the patch output directory. It updates/removes patch files only for XML pairs it compares.
#>

param(
    [string]$ToolPathsPs1,
    [string]$GameRoot,
    [string]$OutputRoot,
    [string]$WitchyBndExe,
    [string]$GitExe,

    [string]$OriginalArchiveRelativePath = 'param\gameparam\gameparam.parambnd.dcx',
    [string]$ChangedArchive,
    [string]$ChangedExtractDir,
    [string]$PatchOutDir,

    [switch]$Recurse = $true,
    [switch]$DryRun,
    [switch]$KeepWork,

    [int]$StartupDelayMs = 1800,
    [int]$KeyDelayMs = 250,
    [int]$StepDelayMs = 700
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
        . $configPath
    } else {
        Write-Info 'No tool config file found. Parameters must provide all required paths.'
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
        [Parameter(Mandatory)][string]$RelativeOrAbsolutePath,
        [Parameter(Mandatory)][string]$Label
    )

    if ([System.IO.Path]::IsPathRooted($RelativeOrAbsolutePath)) {
        return (Resolve-RequiredFile -Path $RelativeOrAbsolutePath -Label $Label)
    }

    $candidate = Join-Path $GameRootPath $RelativeOrAbsolutePath
    return (Resolve-RequiredFile -Path $candidate -Label $Label)
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
        return ([System.IO.Path]::GetFullPath($PatchOutDir))
    }

    $relative = 'Diffs\param\gameparam\gameparam-parambnd-dcx\_patches'
    foreach ($root in Get-DIYRootCandidates) {
        $candidate = Join-Path $root $relative
        $diffParent = Split-Path -Parent (Split-Path -Parent $candidate)
        if (Test-Path -LiteralPath $diffParent -PathType Container) {
            Ensure-Dir $candidate
            return ([System.IO.Path]::GetFullPath($candidate))
        }
    }

    if ($PSScriptRoot) {
        $fallbackRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        if ($fallbackRoot) {
            $candidate = Join-Path $fallbackRoot $relative
            Ensure-Dir $candidate
            return ([System.IO.Path]::GetFullPath($candidate))
        }
    }

    throw 'Could not determine default patch output directory. Use -PatchOutDir explicitly.'
}

function Resolve-DefaultChangedArchive {
    if ($ChangedArchive) {
        return (Resolve-RequiredFile -Path $ChangedArchive -Label 'Changed gameparam archive')
    }

    if (-not $OutputRoot) {
        return $null
    }

    $candidate = Join-Path $OutputRoot 'BBReborne_gparam\param\gameparam\gameparam.parambnd.dcx'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    return $null
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
    Start-Sleep -Milliseconds 300

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
        if (Test-Path -LiteralPath $ExtractDir -PathType Container) { return }
        Start-Sleep -Milliseconds 250
    }

    throw "Timed out waiting for extracted folder: $ExtractDir"
}

function Copy-ArchiveToTempAndExtract {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$TempArchiveDir,
        [Parameter(Mandatory)][string]$Label
    )

    Ensure-Dir $TempArchiveDir
    $workArchive = Join-Path $TempArchiveDir (Split-Path -Leaf $ArchivePath)
    Copy-Item -LiteralPath $ArchivePath -Destination $workArchive -Force

    Invoke-WitchyExtractGameParam `
        -Label $Label `
        -TargetPath $workArchive `
        -StartupDelayMs $StartupDelayMs `
        -KeyDelayMs $KeyDelayMs `
        -StepDelayMs $StepDelayMs

    $extractDir = Get-WitchyExtractDir -ArchivePath $workArchive
    Wait-ForExtractDir -ExtractDir $extractDir -TimeoutSeconds 30
    return $extractDir
}

function Find-XmlComparisonRoot {
    param([Parameter(Mandatory)][string]$ExtractDir)

    $xmlFiles = @(Get-ChildItem -LiteralPath $ExtractDir -File -Filter '*.xml' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '_witchy-*' })

    if ($xmlFiles.Count -eq 0) {
        throw "No XML files found under extracted folder: $ExtractDir"
    }

    $parents = $xmlFiles | ForEach-Object { $_.DirectoryName } | Select-Object -Unique
    if ($parents.Count -eq 1) {
        return $parents[0]
    }

    return $ExtractDir
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

function Get-SafePatchName {
    param(
        [Parameter(Mandatory)][string]$Rel,
        [Parameter(Mandatory)][hashtable]$BaseCounts
    )

    $base = [IO.Path]::GetFileNameWithoutExtension($Rel)

    if ($BaseCounts[$base] -eq 1) {
        return "$base.patch"
    }

    $noExt = $Rel -replace '\.xml$',''
    $safe = ($noExt -replace '[\/]+','__' -replace '[^A-Za-z0-9_\-\.]','_')
    return "$safe.patch"
}

function Invoke-GitDiffUtf8 {
    param(
        [Parameter(Mandatory)][string]$GitExe,
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$RelA,
        [Parameter(Mandatory)][string]$RelB
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $GitExe
    $psi.WorkingDirectory = $WorkRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)

    foreach ($arg in @(
        '-c', 'core.quotepath=false',
        '-c', 'i18n.logOutputEncoding=utf-8',
        'diff',
        '--no-index',
        '--no-prefix',
        '--',
        $RelA,
        $RelB
    )) {
        [void]$psi.ArgumentList.Add($arg)
    }

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()

    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function New-GameParamPatches {
    param(
        [Parameter(Mandatory)][string]$OriginalDir,
        [Parameter(Mandatory)][string]$ChangedDir,
        [Parameter(Mandatory)][string]$PatchDir,
        [Parameter(Mandatory)][string]$GitExe
    )

    $changedRoot = [IO.Path]::GetFullPath($ChangedDir)
    $origRoot    = [IO.Path]::GetFullPath($OriginalDir)

    if (-not (Test-Path -LiteralPath $changedRoot -PathType Container)) { throw "ChangedDir not found: $changedRoot" }
    if (-not (Test-Path -LiteralPath $origRoot -PathType Container)) { throw "OriginalDir not found: $origRoot" }

    Ensure-Dir $PatchDir

    $workRoot = Join-Path $script:TempRoot 'diff_patch_work'
    $workA    = Join-Path $workRoot 'a'
    $workB    = Join-Path $workRoot 'b'

    Write-Stage ''
    Write-Stage 'Stage #0: Discover changed XML files and match originals...'

    $gciArgs = @{
        LiteralPath = $changedRoot
        File        = $true
        Filter      = '*.xml'
    }
    if ($Recurse) { $gciArgs.Recurse = $true }

    $changedFiles = @(Get-ChildItem @gciArgs | Where-Object {
        $_.FullName -notmatch [regex]::Escape('\_patches\') -and $_.Name -notlike '_witchy-*'
    })

    Write-Info ("  Found {0} changed XML files." -f $changedFiles.Count)
    if ($changedFiles.Count -eq 0) {
        return [pscustomobject]@{ Changed = 0; Unchanged = 0; Failed = 0; Matched = 0; Missing = 0; PatchDir = $PatchDir }
    }

    $pairs = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($cf in $changedFiles) {
        $rel = Get-RelPath -Root $changedRoot -Full $cf.FullName
        $of = Join-Path $origRoot $rel

        if (Test-Path -LiteralPath $of -PathType Leaf) {
            $pairs.Add([pscustomobject]@{
                Rel         = $rel
                ChangedXml  = $cf.FullName
                OriginalXml = $of
                BaseName    = [IO.Path]::GetFileNameWithoutExtension($cf.Name)
            })
        } else {
            $missing.Add($rel) | Out-Null
        }
    }

    Write-Info ("  Matched {0} files. Missing in OriginalDir: {1}" -f $pairs.Count, $missing.Count)
    if ($missing.Count -gt 0) {
        $missing | Select-Object -First 20 | ForEach-Object {
            Write-Warning ("    MISSING: {0}" -f $_)
        }
    }

    if ($pairs.Count -eq 0) {
        throw 'No matched XML files; stopping.'
    }

    $baseCounts = @{}
    foreach ($pair in $pairs) {
        if (-not $baseCounts.ContainsKey($pair.BaseName)) { $baseCounts[$pair.BaseName] = 0 }
        $baseCounts[$pair.BaseName]++
    }

    if (-not $DryRun) {
        Ensure-Dir $workA
        Ensure-Dir $workB
    }

    Write-Stage ''
    Write-Stage 'Stage #1: Copy matched XMLs into temp diff work folder...'

    foreach ($pair in $pairs) {
        $destA = Join-Path $workA $pair.Rel
        $destB = Join-Path $workB $pair.Rel

        if ($DryRun) {
            Write-Info ("  DRY: copy A {0} -> {1}" -f $pair.OriginalXml, $destA)
            Write-Info ("  DRY: copy B {0} -> {1}" -f $pair.ChangedXml,  $destB)
            continue
        }

        Ensure-Dir (Split-Path -Parent $destA)
        Ensure-Dir (Split-Path -Parent $destB)

        Copy-Item -LiteralPath $pair.OriginalXml -Destination $destA -Force
        Copy-Item -LiteralPath $pair.ChangedXml  -Destination $destB -Force
    }

    Write-Stage ''
    Write-Stage 'Stage #2: Create portable git patches...'

    $ok = 0
    $skip = 0
    $fail = 0

    foreach ($pair in $pairs) {
        $patchName = Get-SafePatchName -Rel $pair.Rel -BaseCounts $baseCounts
        $patchPath = Join-Path $PatchDir $patchName

        if ($DryRun) {
            Write-Info ("  DRY: would diff {0} -> {1}" -f $pair.Rel, $patchPath)
            continue
        }

        $relPosix = $pair.Rel -replace '\\','/'
        $relA = "a/$relPosix"
        $relB = "b/$relPosix"

        $result = Invoke-GitDiffUtf8 -GitExe $GitExe -WorkRoot $workRoot -RelA $relA -RelB $relB

        if ($result.ExitCode -eq 0) {
            if (Test-Path -LiteralPath $patchPath) {
                Remove-Item -LiteralPath $patchPath -Force
            }
            $skip++
        } elseif ($result.ExitCode -eq 1) {
            [System.IO.File]::WriteAllText($patchPath, $result.StdOut, (New-Object System.Text.UTF8Encoding($false)))
            $ok++
        } else {
            Write-Warning ("  FAIL: git diff error for {0}" -f $pair.Rel)
            if ($result.StdErr) {
                Write-Warning ("        {0}" -f (($result.StdErr -split "`r?`n" | Select-Object -First 1)))
            }
            $fail++
        }
    }

    Write-Info ("Stage #2 done. Changed={0}  Unchanged={1}  Failed={2}" -f $ok, $skip, $fail)
    Write-Info ("Patches folder: {0}" -f $PatchDir)

    return [pscustomobject]@{
        Changed   = $ok
        Unchanged = $skip
        Failed    = $fail
        Matched   = $pairs.Count
        Missing   = $missing.Count
        PatchDir  = $PatchDir
    }
}

function Remove-SafeTempDir {
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

    $full = [System.IO.Path]::GetFullPath($Path)
    $tempFull = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())

    if (-not $full.StartsWith($tempFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove temp directory outside system temp: $full"
    }<#
    04_Global_BBReborne_Gparam_GameParam_GenerateDiffs.ps1

    Development/reference helper for generating gameparam XML patch files used by:
        04_Global_BBReborne_Gparam_GameParam.ps1

    Purpose:
    - Extract the original gameparam archive from the configured game folder using the original Extract_gameparam key flow.
    - Extract a changed gameparam archive, or use an already-extracted changed folder.
    - Compare original XML files against changed XML files.
    - Generate portable Git patch files under:
        <BBReborneDIYTool>\Diffs\param\gameparam\gameparam-parambnd-dcx\_patches

    This script is for development/reference only and is not intended to be called by the DIY Tool UI.

    Typical use with the generated/modded archive from the output folder:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\04_Global_BBReborne_Gparam_GameParam_GenerateDiffs.ps1 `
            -ToolPathsPs1 "<BBReborneDIYTool>\Tools\BBReborneDIYTool.paths.ps1"

    Typical use with an explicit changed archive:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\04_Global_BBReborne_Gparam_GameParam_GenerateDiffs.ps1 `
            -ToolPathsPs1 "<BBReborneDIYTool>\Tools\BBReborneDIYTool.paths.ps1" `
            -ChangedArchive "<PathToChanged>\gameparam.parambnd.dcx"

    Typical use with an already extracted changed folder:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\04_Global_BBReborne_Gparam_GameParam_GenerateDiffs.ps1 `
            -ToolPathsPs1 "<BBReborneDIYTool>\Tools\BBReborneDIYTool.paths.ps1" `
            -ChangedExtractDir "<PathToChangedExtractedFolder>"

    Notes:
    - This script never modifies original game files.
    - This script creates and cleans only its own temporary work folder under the system temp folder.
    - It does not wipe or delete from the patch output directory. Existing patches are
      replaced only after a new non-empty patch has been generated successfully.
#>

param(
    [string]$ToolPathsPs1,
    [string]$GameRoot,
    [string]$OutputRoot,
    [string]$WitchyBndExe,
    [string]$GitExe,

    [string]$OriginalArchiveRelativePath = 'param\gameparam\gameparam.parambnd.dcx',
    [string]$ChangedArchive,
    [string]$ChangedExtractDir,
    [string]$PatchOutDir,

    [switch]$Recurse = $true,
    [switch]$DryRun,
    [switch]$KeepWork,

    [int]$StartupDelayMs = 1800,
    [int]$KeyDelayMs = 250,
    [int]$StepDelayMs = 700
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
        [Parameter(Mandatory)][string]$RelativeOrAbsolutePath,
        [Parameter(Mandatory)][string]$Label
    )

    if ([System.IO.Path]::IsPathRooted($RelativeOrAbsolutePath)) {
        return (Resolve-RequiredFile -Path $RelativeOrAbsolutePath -Label $Label)
    }

    $candidate = Join-Path $GameRootPath $RelativeOrAbsolutePath
    return (Resolve-RequiredFile -Path $candidate -Label $Label)
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
        return ([System.IO.Path]::GetFullPath($PatchOutDir))
    }

    $relative = 'Diffs\param\gameparam\gameparam-parambnd-dcx\_patches'
    foreach ($root in Get-DIYRootCandidates) {
        $candidate = Join-Path $root $relative
        $diffParent = Split-Path -Parent (Split-Path -Parent $candidate)
        if (Test-Path -LiteralPath $diffParent -PathType Container) {
            Ensure-Dir $candidate
            return ([System.IO.Path]::GetFullPath($candidate))
        }
    }

    if ($PSScriptRoot) {
        $fallbackRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        if ($fallbackRoot) {
            $candidate = Join-Path $fallbackRoot $relative
            Ensure-Dir $candidate
            return ([System.IO.Path]::GetFullPath($candidate))
        }
    }

    throw 'Could not determine default patch output directory. Use -PatchOutDir explicitly.'
}

function Resolve-DefaultChangedArchive {
    if ($ChangedArchive) {
        return (Resolve-RequiredFile -Path $ChangedArchive -Label 'Changed gameparam archive')
    }

    if (-not $OutputRoot) {
        return $null
    }

    $candidate = Join-Path $OutputRoot 'BBReborne_gparam\param\gameparam\gameparam.parambnd.dcx'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    return $null
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
    Start-Sleep -Milliseconds 300

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
        if (Test-Path -LiteralPath $ExtractDir -PathType Container) { return }
        Start-Sleep -Milliseconds 250
    }

    throw "Timed out waiting for extracted folder: $ExtractDir"
}

function Copy-ArchiveToTempAndExtract {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$TempArchiveDir,
        [Parameter(Mandatory)][string]$Label
    )

    Ensure-Dir $TempArchiveDir
    $workArchive = Join-Path $TempArchiveDir (Split-Path -Leaf $ArchivePath)
    Copy-Item -LiteralPath $ArchivePath -Destination $workArchive -Force

    Invoke-WitchyExtractGameParam `
        -Label $Label `
        -TargetPath $workArchive `
        -StartupDelayMs $StartupDelayMs `
        -KeyDelayMs $KeyDelayMs `
        -StepDelayMs $StepDelayMs

    $extractDir = Get-WitchyExtractDir -ArchivePath $workArchive
    Wait-ForExtractDir -ExtractDir $extractDir -TimeoutSeconds 30
    return $extractDir
}

function Find-XmlComparisonRoot {
    param([Parameter(Mandatory)][string]$ExtractDir)

    $xmlFiles = @(Get-ChildItem -LiteralPath $ExtractDir -File -Filter '*.xml' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '_witchy-*' })

    if ($xmlFiles.Count -eq 0) {
        throw "No XML files found under extracted folder: $ExtractDir"
    }

    $parents = $xmlFiles | ForEach-Object { $_.DirectoryName } | Select-Object -Unique
    if ($parents.Count -eq 1) {
        return $parents[0]
    }

    return $ExtractDir
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

function Get-SafePatchName {
    param(
        [Parameter(Mandatory)][string]$Rel,
        [Parameter(Mandatory)][hashtable]$BaseCounts
    )

    $base = [IO.Path]::GetFileNameWithoutExtension($Rel)

    if ($BaseCounts[$base] -eq 1) {
        return "$base.patch"
    }

    $noExt = $Rel -replace '\.xml$',''
    $safe = ($noExt -replace '[\/]+','__' -replace '[^A-Za-z0-9_\-\.]','_')
    return "$safe.patch"
}

function Invoke-GitDiffUtf8 {
    param(
        [Parameter(Mandatory)][string]$GitExe,
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$RelA,
        [Parameter(Mandatory)][string]$RelB
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $GitExe
    $psi.WorkingDirectory = $WorkRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)

    foreach ($arg in @(
        '-c', 'core.quotepath=false',
        '-c', 'i18n.logOutputEncoding=utf-8',
        'diff',
        '--no-index',
        '--no-prefix',
        '--',
        $RelA,
        $RelB
    )) {
        [void]$psi.ArgumentList.Add($arg)
    }

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()

    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function New-GameParamPatches {
    param(
        [Parameter(Mandatory)][string]$OriginalDir,
        [Parameter(Mandatory)][string]$ChangedDir,
        [Parameter(Mandatory)][string]$PatchDir,
        [Parameter(Mandatory)][string]$GitExe
    )

    $changedRoot = [IO.Path]::GetFullPath($ChangedDir)
    $origRoot    = [IO.Path]::GetFullPath($OriginalDir)

    if (-not (Test-Path -LiteralPath $changedRoot -PathType Container)) { throw "ChangedDir not found: $changedRoot" }
    if (-not (Test-Path -LiteralPath $origRoot -PathType Container)) { throw "OriginalDir not found: $origRoot" }

    Ensure-Dir $PatchDir

    $workRoot = Join-Path $script:TempRoot 'diff_patch_work'
    $workA    = Join-Path $workRoot 'a'
    $workB    = Join-Path $workRoot 'b'

    Write-Stage ''
    Write-Stage 'Stage #0: Discover changed XML files and match originals...'

    $gciArgs = @{
        LiteralPath = $changedRoot
        File        = $true
        Filter      = '*.xml'
    }
    if ($Recurse) { $gciArgs.Recurse = $true }

    $changedFiles = @(Get-ChildItem @gciArgs | Where-Object {
        $_.FullName -notmatch [regex]::Escape('\_patches\') -and $_.Name -notlike '_witchy-*'
    })

    Write-Info ("  Found {0} changed XML files." -f $changedFiles.Count)
    if ($changedFiles.Count -eq 0) {
        return [pscustomobject]@{ Changed = 0; Unchanged = 0; Failed = 0; Matched = 0; Missing = 0; PatchDir = $PatchDir }
    }

    $pairs = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($cf in $changedFiles) {
        $rel = Get-RelPath -Root $changedRoot -Full $cf.FullName
        $of = Join-Path $origRoot $rel

        if (Test-Path -LiteralPath $of -PathType Leaf) {
            $pairs.Add([pscustomobject]@{
                Rel         = $rel
                ChangedXml  = $cf.FullName
                OriginalXml = $of
                BaseName    = [IO.Path]::GetFileNameWithoutExtension($cf.Name)
            })
        } else {
            $missing.Add($rel) | Out-Null
        }
    }

    Write-Info ("  Matched {0} files. Missing in OriginalDir: {1}" -f $pairs.Count, $missing.Count)
    if ($missing.Count -gt 0) {
        $missing | Select-Object -First 20 | ForEach-Object {
            Write-Warning ("    MISSING: {0}" -f $_)
        }
    }

    if ($pairs.Count -eq 0) {
        throw 'No matched XML files; stopping.'
    }

    $baseCounts = @{}
    foreach ($pair in $pairs) {
        if (-not $baseCounts.ContainsKey($pair.BaseName)) { $baseCounts[$pair.BaseName] = 0 }
        $baseCounts[$pair.BaseName]++
    }

    if (-not $DryRun) {
        Ensure-Dir $workA
        Ensure-Dir $workB
    }

    Write-Stage ''
    Write-Stage 'Stage #1: Copy matched XMLs into temp diff work folder...'

    foreach ($pair in $pairs) {
        $destA = Join-Path $workA $pair.Rel
        $destB = Join-Path $workB $pair.Rel

        if ($DryRun) {
            Write-Info ("  DRY: copy A {0} -> {1}" -f $pair.OriginalXml, $destA)
            Write-Info ("  DRY: copy B {0} -> {1}" -f $pair.ChangedXml,  $destB)
            continue
        }

        Ensure-Dir (Split-Path -Parent $destA)
        Ensure-Dir (Split-Path -Parent $destB)

        Copy-Item -LiteralPath $pair.OriginalXml -Destination $destA -Force
        Copy-Item -LiteralPath $pair.ChangedXml  -Destination $destB -Force
    }

    Write-Stage ''
    Write-Stage 'Stage #2: Create portable git patches...'

    $ok = 0
    $skip = 0
    $fail = 0

    foreach ($pair in $pairs) {
        $patchName = Get-SafePatchName -Rel $pair.Rel -BaseCounts $baseCounts
        $patchPath = Join-Path $PatchDir $patchName

        if ($DryRun) {
            Write-Info ("  DRY: would diff {0} -> {1}" -f $pair.Rel, $patchPath)
            continue
        }

        $relPosix = $pair.Rel -replace '\\','/'
        $relA = "a/$relPosix"
        $relB = "b/$relPosix"

        $result = Invoke-GitDiffUtf8 -GitExe $GitExe -WorkRoot $workRoot -RelA $relA -RelB $relB

        if ($result.ExitCode -eq 0) {
            # Do not remove an existing patch here. Diffs is durable input; stale
            # patch review/removal must be explicit and manual.
            if (Test-Path -LiteralPath $patchPath) {
                Write-Warning ("  UNCHANGED: leaving existing patch untouched: {0}" -f $patchPath)
            }
            $skip++
        } elseif ($result.ExitCode -eq 1) {
            $tempPatchPath = Join-Path $workRoot ("generated_" + $patchName + ".tmp")
            [System.IO.File]::WriteAllText($tempPatchPath, $result.StdOut, (New-Object System.Text.UTF8Encoding($false)))
            if ((Get-Item -LiteralPath $tempPatchPath).Length -le 0) {
                throw "Generated temp patch is empty: $tempPatchPath"
            }
            Move-Item -LiteralPath $tempPatchPath -Destination $patchPath -Force
            $ok++
        } else {
            Write-Warning ("  FAIL: git diff error for {0}" -f $pair.Rel)
            if ($result.StdErr) {
                Write-Warning ("        {0}" -f (($result.StdErr -split "`r?`n" | Select-Object -First 1)))
            }
            $fail++
        }
    }

    Write-Info ("Stage #2 done. Changed={0}  Unchanged={1}  Failed={2}" -f $ok, $skip, $fail)
    Write-Info ("Patches folder: {0}" -f $PatchDir)

    return [pscustomobject]@{
        Changed   = $ok
        Unchanged = $skip
        Failed    = $fail
        Matched   = $pairs.Count
        Missing   = $missing.Count
        PatchDir  = $PatchDir
    }
}

function Remove-SafeTempDir {
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

    $full = [System.IO.Path]::GetFullPath($Path)
    $tempFull = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())

    if (-not $full.StartsWith($tempFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove temp directory outside system temp: $full"
    }

    Remove-Item -LiteralPath $full -Recurse -Force
}

# -------------------- Main --------------------

Import-ToolConfig

if (-not $GameRoot) { $GameRoot = Get-OptionalVariableValue -Name 'BBR_GameRoot' }
if (-not $OutputRoot) { $OutputRoot = Get-OptionalVariableValue -Name 'BBR_OutputRoot' }
if (-not $WitchyBndExe) { $WitchyBndExe = Get-OptionalVariableValue -Name 'BBR_WitchyBND_v2_4_0_1' }
if (-not $GitExe) { $GitExe = Get-OptionalVariableValue -Name 'BBR_GitExe' }

$GameRoot = Resolve-GameRoot -Path $GameRoot
if ($OutputRoot) { $OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot) }
$WitchyBndExe = Resolve-RequiredFile -Path $WitchyBndExe -Label 'WitchyBND v2.4.0.1 executable'
$GitExe = Resolve-RequiredFile -Path $GitExe -Label 'Git executable'
$PatchOutDir = Resolve-DefaultPatchOutDir

$script:WitchyBndExe = $WitchyBndExe
$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bb_reborne_gameparam_diffs_" + [guid]::NewGuid().ToString('N'))
Ensure-Dir $script:TempRoot

$originalArchive = Resolve-GameArchive -GameRootPath $GameRoot -RelativeOrAbsolutePath $OriginalArchiveRelativePath -Label 'Original gameparam archive'
$changedArchiveResolved = $null
if (-not $ChangedExtractDir) {
    $changedArchiveResolved = Resolve-DefaultChangedArchive
    if (-not $changedArchiveResolved) {
        throw 'Changed archive was not provided and default changed archive was not found. Use -ChangedArchive or -ChangedExtractDir.'
    }
}

Write-Info "GameRoot        = $GameRoot"
Write-Info "OutputRoot      = $OutputRoot"
Write-Info "WitchyBND       = $WitchyBndExe"
Write-Info "GitExe          = $GitExe"
Write-Info "OriginalArchive = $originalArchive"
Write-Info "ChangedArchive  = $changedArchiveResolved"
Write-Info "ChangedExtract  = $ChangedExtractDir"
Write-Info "PatchOutDir     = $PatchOutDir"
Write-Info "TempRoot        = $script:TempRoot"

$overall = [System.Diagnostics.Stopwatch]::StartNew()
$completed = $false
$report = $null

try {
    Write-Stage ''
    Write-Stage '1/4 Extract original gameparam archive...'
    $originalArchiveWorkDir = Join-Path $script:TempRoot 'original_archive'
    $originalExtractDir = Copy-ArchiveToTempAndExtract -ArchivePath $originalArchive -TempArchiveDir $originalArchiveWorkDir -Label 'Extract original gameparam with WitchyBND'
    $originalXmlRoot = Find-XmlComparisonRoot -ExtractDir $originalExtractDir
    Write-Info "OriginalExtractDir = $originalExtractDir"
    Write-Info "OriginalXmlRoot    = $originalXmlRoot"

    Write-Stage ''
    Write-Stage '2/4 Prepare changed XML root...'
    if ($ChangedExtractDir) {
        $changedXmlRoot = Resolve-RequiredDirectory -Path $ChangedExtractDir -Label 'Changed extracted XML folder'
        Write-Info "Using changed extracted folder: $changedXmlRoot"
    } else {
        $changedArchiveWorkDir = Join-Path $script:TempRoot 'changed_archive'
        $changedExtractDir = Copy-ArchiveToTempAndExtract -ArchivePath $changedArchiveResolved -TempArchiveDir $changedArchiveWorkDir -Label 'Extract changed gameparam with WitchyBND'
        $changedXmlRoot = Find-XmlComparisonRoot -ExtractDir $changedExtractDir
        Write-Info "ChangedExtractDir = $changedExtractDir"
    }
    Write-Info "ChangedXmlRoot = $changedXmlRoot"

    Write-Stage ''
    Write-Stage '3/4 Generate patch files...'
    $report = New-GameParamPatches -OriginalDir $originalXmlRoot -ChangedDir $changedXmlRoot -PatchDir $PatchOutDir -GitExe $GitExe

    Write-Stage ''
    Write-Stage '4/4 Report...'
    Write-Info "Patch directory: $($report.PatchDir)"
    Write-Info "Matched XMLs   : $($report.Matched)"
    Write-Info "Missing XMLs   : $($report.Missing)"
    Write-Info "Changed patches: $($report.Changed)"
    Write-Info "Unchanged XMLs : $($report.Unchanged)"
    Write-Info "Failed diffs   : $($report.Failed)"

    if ($report.Failed -gt 0) {
        throw "One or more diffs failed. Failed count: $($report.Failed)"
    }

    $completed = $true
}
finally {
    $overall.Stop()
    if ($completed -and -not $KeepWork) {
        try {
            Remove-SafeTempDir -Path $script:TempRoot
            Write-Info "Removed temp work folder: $script:TempRoot"
        } catch {
            Write-Warning $_.Exception.Message
        }
    } else {
        Write-Info "Kept temp work folder: $script:TempRoot"
    }
}

Write-Stage ''
Write-Stage 'Done.'
Write-Info ('Elapsed: {0}' -f $overall.Elapsed)


    Remove-Item -LiteralPath $full -Recurse -Force
}

# -------------------- Main --------------------

Import-ToolConfig

if (-not $GameRoot) { $GameRoot = Get-OptionalVariableValue -Name 'BBR_GameRoot' }
if (-not $OutputRoot) { $OutputRoot = Get-OptionalVariableValue -Name 'BBR_OutputRoot' }
if (-not $WitchyBndExe) { $WitchyBndExe = Get-OptionalVariableValue -Name 'BBR_WitchyBND_v2_4_0_1' }
if (-not $GitExe) { $GitExe = Get-OptionalVariableValue -Name 'BBR_GitExe' }

$GameRoot = Resolve-GameRoot -Path $GameRoot
if ($OutputRoot) { $OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot) }
$WitchyBndExe = Resolve-RequiredFile -Path $WitchyBndExe -Label 'WitchyBND v2.4.0.1 executable'
$GitExe = Resolve-RequiredFile -Path $GitExe -Label 'Git executable'
$PatchOutDir = Resolve-DefaultPatchOutDir

$script:WitchyBndExe = $WitchyBndExe
$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bb_reborne_gameparam_diffs_" + [guid]::NewGuid().ToString('N'))
Ensure-Dir $script:TempRoot

$originalArchive = Resolve-GameArchive -GameRootPath $GameRoot -RelativeOrAbsolutePath $OriginalArchiveRelativePath -Label 'Original gameparam archive'
$changedArchiveResolved = $null
if (-not $ChangedExtractDir) {
    $changedArchiveResolved = Resolve-DefaultChangedArchive
    if (-not $changedArchiveResolved) {
        throw 'Changed archive was not provided and default changed archive was not found. Use -ChangedArchive or -ChangedExtractDir.'
    }
}

Write-Info "GameRoot        = $GameRoot"
Write-Info "OutputRoot      = $OutputRoot"
Write-Info "WitchyBND       = $WitchyBndExe"
Write-Info "GitExe          = $GitExe"
Write-Info "OriginalArchive = $originalArchive"
Write-Info "ChangedArchive  = $changedArchiveResolved"
Write-Info "ChangedExtract  = $ChangedExtractDir"
Write-Info "PatchOutDir     = $PatchOutDir"
Write-Info "TempRoot        = $script:TempRoot"

$overall = [System.Diagnostics.Stopwatch]::StartNew()
$completed = $false
$report = $null

try {
    Write-Stage ''
    Write-Stage '1/4 Extract original gameparam archive...'
    $originalArchiveWorkDir = Join-Path $script:TempRoot 'original_archive'
    $originalExtractDir = Copy-ArchiveToTempAndExtract -ArchivePath $originalArchive -TempArchiveDir $originalArchiveWorkDir -Label 'Extract original gameparam with WitchyBND'
    $originalXmlRoot = Find-XmlComparisonRoot -ExtractDir $originalExtractDir
    Write-Info "OriginalExtractDir = $originalExtractDir"
    Write-Info "OriginalXmlRoot    = $originalXmlRoot"

    Write-Stage ''
    Write-Stage '2/4 Prepare changed XML root...'
    if ($ChangedExtractDir) {
        $changedXmlRoot = Resolve-RequiredDirectory -Path $ChangedExtractDir -Label 'Changed extracted XML folder'
        Write-Info "Using changed extracted folder: $changedXmlRoot"
    } else {
        $changedArchiveWorkDir = Join-Path $script:TempRoot 'changed_archive'
        $changedExtractDir = Copy-ArchiveToTempAndExtract -ArchivePath $changedArchiveResolved -TempArchiveDir $changedArchiveWorkDir -Label 'Extract changed gameparam with WitchyBND'
        $changedXmlRoot = Find-XmlComparisonRoot -ExtractDir $changedExtractDir
        Write-Info "ChangedExtractDir = $changedExtractDir"
    }
    Write-Info "ChangedXmlRoot = $changedXmlRoot"

    Write-Stage ''
    Write-Stage '3/4 Generate patch files...'
    $report = New-GameParamPatches -OriginalDir $originalXmlRoot -ChangedDir $changedXmlRoot -PatchDir $PatchOutDir -GitExe $GitExe

    Write-Stage ''
    Write-Stage '4/4 Report...'
    Write-Info "Patch directory: $($report.PatchDir)"
    Write-Info "Matched XMLs   : $($report.Matched)"
    Write-Info "Missing XMLs   : $($report.Missing)"
    Write-Info "Changed patches: $($report.Changed)"
    Write-Info "Unchanged XMLs : $($report.Unchanged)"
    Write-Info "Failed diffs   : $($report.Failed)"

    if ($report.Failed -gt 0) {
        throw "One or more diffs failed. Failed count: $($report.Failed)"
    }

    $completed = $true
}
finally {
    $overall.Stop()
    if ($completed -and -not $KeepWork) {
        try {
            Remove-SafeTempDir -Path $script:TempRoot
            Write-Info "Removed temp work folder: $script:TempRoot"
        } catch {
            Write-Warning $_.Exception.Message
        }
    } else {
        Write-Info "Kept temp work folder: $script:TempRoot"
    }
}

Write-Stage ''
Write-Stage 'Done.'
Write-Info ('Elapsed: {0}' -f $overall.Elapsed)
