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
    03_Global_BBReborne_Menu_fe_GeneratePatch.ps1

    Development/reference helper for generating the Git binary patch used by:
        03_Global_BBReborne_Menu_fe.ps1

    Purpose:
    - Generate a binary Git patch for menu\fe.gfx.
    - Default patch output:
        <BBReborneDIYTool>\Diffs\menu\_patch\fe.<#
    03_Global_BBReborne_Menu_fe_GeneratePatch.ps1

    Development/reference helper for generating the Git binary patch used by:
        03_Global_BBReborne_Menu_fe.ps1

    Purpose:
    - Generate a binary Git patch for menu\fe.gfx.
    - Default patch output:
        <BBReborneDIYTool>\Diffs\menu\_patch\fe.patch
    - The generated patch target path is intentionally:
        payload/fe.gfx
      so the runtime apply script can safely stage the original fe.gfx into that path.

    This script is for development/reference only and is not intended to be called by the DIY Tool UI.

    Typical use:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\03_Global_BBReborne_Menu_fe_GeneratePatch.ps1 `
            -ToolPathsPs1 "C:\Users\Sero\BBReborneDIYTool\Tools\BBReborneDIYTool.paths.ps1" `
            -ModifiedFile "C:\Path\To\Edited\fe.gfx"

    Or explicit original/modified:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\03_Global_BBReborne_Menu_fe_GeneratePatch.ps1 `
            -OriginalFile "C:\Path\To\Original\fe.gfx" `
            -ModifiedFile "C:\Path\To\Edited\fe.gfx" `
            -PatchOut "BBReborneDIYTool\Diffs\menu\_patch\fe.patch"

    Notes:
    - This script creates and cleans only its own temporary work folder under the system temp folder.
    - It does not modify the original or modified input files.
    - It writes generated patch content to a temporary file first, validates it,
      then replaces the chosen patch output file only after successful generation.
#>

param(
    [string]$ToolPathsPs1,
    [string]$GameRoot,
    [string]$GitExe,

    [string]$OriginalFile,
    [Parameter(Mandatory=$true)][string]$ModifiedFile,
    [string]$PatchOut,

    [string]$PatchTargetPath = 'payload/fe.gfx',
    [switch]$KeepWork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Resolve-DefaultPatchOut {
    if ($PatchOut) {
        $parent = Split-Path -Parent $PatchOut
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        return ([System.IO.Path]::GetFullPath($PatchOut))
    }

    $relative = 'Diffs\menu\_patch\fe.patch'
    foreach ($root in Get-DIYRootCandidates) {
        $candidate = Join-Path $root $relative
        $parent = Split-Path -Parent $candidate
        if (Test-Path -LiteralPath (Split-Path -Parent $parent) -PathType Container) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            return ([System.IO.Path]::GetFullPath($candidate))
        }
    }

    if ($PSScriptRoot) {
        $fallbackRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        if ($fallbackRoot) {
            $candidate = Join-Path $fallbackRoot $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $candidate) -Force | Out-Null
            return ([System.IO.Path]::GetFullPath($candidate))
        }
    }

    throw 'Could not determine default patch output path. Use -PatchOut explicitly.'
}

function Assert-SafePatchTargetPath {
    param([Parameter(Mandatory)][string]$RelativePath)

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Patch target path must be relative, got rooted path: $RelativePath"
    }

    $parts = $RelativePath -split '[\\/]+'
    if ($parts | Where-Object { $_ -eq '..' }) {
        throw "Patch target path may not contain '..': $RelativePath"
    }

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw 'Patch target path is empty.'
    }

    return ($RelativePath -replace '\\', '/')
}

function Invoke-GitCapture {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Args
    )

    $output = & $Exe @Args 2>&1
    $exit = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exit
        Output   = @($output)
    }
}

function Assert-GitOk {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Label
    )

    foreach ($line in $Result.Output) {
        Write-Info ([string]$line)
    }

    if ($Result.ExitCode -ne 0) {
        throw "$Label failed with exit code $($Result.ExitCode)."
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
if (-not $GitExe) { $GitExe = Get-OptionalVariableValue -Name 'BBR_GitExe' }

if (-not $OriginalFile) {
    $GameRoot = Resolve-GameRoot -Path $GameRoot
    $OriginalFile = Join-Path $GameRoot 'menu\fe.gfx'
}

$OriginalFile = Resolve-RequiredFile -Path $OriginalFile -Label 'Original fe.gfx'
$ModifiedFile = Resolve-RequiredFile -Path $ModifiedFile -Label 'Modified fe.gfx'
$GitExe = Resolve-RequiredFile -Path $GitExe -Label 'Git executable'
$PatchOut = Resolve-DefaultPatchOut
$PatchTargetPath = Assert-SafePatchTargetPath -RelativePath $PatchTargetPath

$patchParent = Split-Path -Parent $PatchOut
New-Item -ItemType Directory -Path $patchParent -Force | Out-Null

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bb_reborne_git_binary_patch_" + [guid]::NewGuid().ToString('N'))
$repoDir = Join-Path $tempRoot 'repo'
$repoFile = Join-Path $repoDir ($PatchTargetPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
$repoFileDir = Split-Path -Parent $repoFile
New-Item -ItemType Directory -Path $repoFileDir -Force | Out-Null

Write-Info "OriginalFile    = $OriginalFile"
Write-Info "ModifiedFile    = $ModifiedFile"
Write-Info "PatchOut        = $PatchOut"
Write-Info "PatchTargetPath = $PatchTargetPath"
Write-Info "GitExe          = $GitExe"
Write-Info "TempRoot        = $tempRoot"

$overall = [System.Diagnostics.Stopwatch]::StartNew()
$completed = $false

try {
    Write-Stage ''
    Write-Stage '1/6 Initialize temporary Git repository...'
    Push-Location $repoDir
    try {
        Assert-GitOk -Result (Invoke-GitCapture -Exe $GitExe -Args @('init', '-q')) -Label 'git init'
        Assert-GitOk -Result (Invoke-GitCapture -Exe $GitExe -Args @('config', 'user.name', 'Patch Generator')) -Label 'git config user.name'
        Assert-GitOk -Result (Invoke-GitCapture -Exe $GitExe -Args @('config', 'user.email', 'patch@example.invalid')) -Label 'git config user.email'

        Write-Stage ''
        Write-Stage '2/6 Add original fe.gfx as baseline...'
        Copy-Item -LiteralPath $OriginalFile -Destination $repoFile -Force
        Assert-GitOk -Result (Invoke-GitCapture -Exe $GitExe -Args @('add', '--', $PatchTargetPath)) -Label 'git add original'
        Assert-GitOk -Result (Invoke-GitCapture -Exe $GitExe -Args @('commit', '-q', '-m', 'original')) -Label 'git commit original'

        Write-Stage ''
        Write-Stage '3/6 Replace baseline with modified fe.gfx...'
        Copy-Item -LiteralPath $ModifiedFile -Destination $repoFile -Force
        Assert-GitOk -Result (Invoke-GitCapture -Exe $GitExe -Args @('add', '--', $PatchTargetPath)) -Label 'git add modified'

        Write-Stage ''
        Write-Stage '4/6 Generate binary patch...'
        $diffArgs = @('diff', '--binary', '--cached', '--', $PatchTargetPath)
        $patchText = & $GitExe @diffArgs 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            foreach ($line in @($patchText)) { Write-Info ([string]$line) }
            throw "git diff export failed with exit code $exitCode."
        }

        $patchString = (@($patchText) -join "`n") + "`n"
        $tempPatchOut = Join-Path $tempRoot 'generated_fe.patch.tmp'
        [System.IO.File]::WriteAllText($tempPatchOut, $patchString, (New-Object System.Text.UTF8Encoding($false)))

        if (-not (Test-Path -LiteralPath $tempPatchOut -PathType Leaf)) {
            throw "Temporary patch file was not created: $tempPatchOut"
        }
        if ((Get-Item -LiteralPath $tempPatchOut).Length -le 0) {
            throw "Temporary patch file is empty: $tempPatchOut"
        }

        # Replace only after the new patch exists and is non-empty. Never delete the
        # existing patch first; Diffs is treated as durable input.
        Move-Item -LiteralPath $tempPatchOut -Destination $PatchOut -Force
    }
    finally {
        Pop-Location -ErrorAction SilentlyContinue
    }

    Write-Stage ''
    Write-Stage '5/6 Validate generated patch file...'
    if (-not (Test-Path -LiteralPath $PatchOut -PathType Leaf)) {
        throw "Patch file was not created: $PatchOut"
    }

    $patchInfo = Get-Item -LiteralPath $PatchOut
    if ($patchInfo.Length -le 0) {
        throw "Patch file is empty: $PatchOut"
    }

    Write-Stage ''
    Write-Stage '6/6 Report hashes...'
    $origHash = (Get-FileHash -LiteralPath $OriginalFile -Algorithm SHA256).Hash
    $modHash = (Get-FileHash -LiteralPath $ModifiedFile -Algorithm SHA256).Hash
    $patchHash = (Get-FileHash -LiteralPath $PatchOut -Algorithm SHA256).Hash

    Write-Info "Patch created: $PatchOut"
    Write-Info "Patch size: $($patchInfo.Length) bytes"
    Write-Info "Original SHA256: $origHash"
    Write-Info "Modified SHA256: $modHash"
    Write-Info "Patch SHA256: $patchHash"

    $completed = $true
}
finally {
    $overall.Stop()
    if ($completed -and -not $KeepWork) {
        try {
            Remove-SafeTempDir -Path $tempRoot
            Write-Info "Removed temp work folder: $tempRoot"
        } catch {
            Write-Warning $_.Exception.Message
        }
    } else {
        Write-Info "Kept temp work folder: $tempRoot"
    }
}

Write-Stage ''
Write-Stage 'Done.'
Write-Info ('Elapsed: {0}' -f $overall.Elapsed)
patch
    - The generated patch target path is intentionally:
        payload/fe.gfx
      so the runtime apply script can safely stage the original fe.gfx into that path.

    This script is for development/reference only and is not intended to be called by the DIY Tool UI.

    Typical use:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\03_Global_BBReborne_Menu_fe_GeneratePatch.ps1 `
            -ToolPathsPs1 "C:\Users\Sero\BBReborneDIYTool\Tools\BBReborneDIYTool.paths.ps1" `
            -ModifiedFile "C:\Path\To\Edited\fe.gfx"

    Or explicit original/modified:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\03_Global_BBReborne_Menu_fe_GeneratePatch.ps1 `
            -OriginalFile "C:\Path\To\Original\fe.gfx" `
            -ModifiedFile "C:\Path\To\Edited\fe.gfx" `
            -PatchOut "BBReborneDIYTool\Diffs\menu\_patch\fe.patch"

    Notes:
    - This script creates and cleans only its own temporary work folder under the system temp folder.
    - It does not modify the original or modified input files.
    - It does overwrite the chosen patch output file when generation succeeds.
#>

param(
    [string]$ToolPathsPs1,
    [string]$GameRoot,
    [string]$GitExe,

    [string]$OriginalFile,
    [Parameter(Mandatory=$true)][string]$ModifiedFile,
    [string]$PatchOut,

    [string]$PatchTargetPath = 'payload/fe.gfx',
    [switch]$KeepWork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Resolve-DefaultPatchOut {
    if ($PatchOut) {
        $parent = Split-Path -Parent $PatchOut
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        return ([System.IO.Path]::GetFullPath($PatchOut))
    }

    $relative = 'Diffs\menu\_patch\fe.patch'
    foreach ($root in Get-DIYRootCandidates) {
        $candidate = Join-Path $root $relative
        $parent = Split-Path -Parent $candidate
        if (Test-Path -LiteralPath (Split-Path -Parent $parent) -PathType Container) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            return ([System.IO.Path]::GetFullPath($candidate))
        }
    }

    if ($PSScriptRoot) {
        $fallbackRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        if ($fallbackRoot) {
            $candidate = Join-Path $fallbackRoot $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $candidate) -Force | Out-Null
            return ([System.IO.Path]::GetFullPath($candidate))
        }
    }

    throw 'Could not determine default patch output path. Use -PatchOut explicitly.'
}

function Assert-SafePatchTargetPath {
    param([Parameter(Mandatory)][string]$RelativePath)

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Patch target path must be relative, got rooted path: $RelativePath"
    }

    $parts = $RelativePath -split '[\\/]+'
    if ($parts | Where-Object { $_ -eq '..' }) {
        throw "Patch target path may not contain '..': $RelativePath"
    }

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw 'Patch target path is empty.'
    }

    return ($RelativePath -replace '\\', '/')
}

function Invoke-GitCapture {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Args
    )

    $output = & $Exe @Args 2>&1
    $exit = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exit
        Output   = @($output)
    }
}

function Assert-GitOk {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Label
    )

    foreach ($line in $Result.Output) {
        Write-Info ([string]$line)
    }

    if ($Result.ExitCode -ne 0) {
        throw "$Label failed with exit code $($Result.ExitCode)."
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
if (-not $GitExe) { $GitExe = Get-OptionalVariableValue -Name 'BBR_GitExe' }

if (-not $OriginalFile) {
    $GameRoot = Resolve-GameRoot -Path $GameRoot
    $OriginalFile = Join-Path $GameRoot 'menu\fe.gfx'
}

$OriginalFile = Resolve-RequiredFile -Path $OriginalFile -Label 'Original fe.gfx'
$ModifiedFile = Resolve-RequiredFile -Path $ModifiedFile -Label 'Modified fe.gfx'
$GitExe = Resolve-RequiredFile -Path $GitExe -Label 'Git executable'
$PatchOut = Resolve-DefaultPatchOut
$PatchTargetPath = Assert-SafePatchTargetPath -RelativePath $PatchTargetPath

$patchParent = Split-Path -Parent $PatchOut
New-Item -ItemType Directory -Path $patchParent -Force | Out-Null

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bb_reborne_git_binary_patch_" + [guid]::NewGuid().ToString('N'))
$repoDir = Join-Path $tempRoot 'repo'
$repoFile = Join-Path $repoDir ($PatchTargetPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
$repoFileDir = Split-Path -Parent $repoFile
New-Item -ItemType Directory -Path $repoFileDir -Force | Out-Null

Write-Info "OriginalFile    = $OriginalFile"
Write-Info "ModifiedFile    = $ModifiedFile"
Write-Info "PatchOut        = $PatchOut"
Write-Info "PatchTargetPath = $PatchTargetPath"
Write-Info "GitExe          = $GitExe"
Write-Info "TempRoot        = $tempRoot"

$overall = [System.Diagnostics.Stopwatch]::StartNew()
$completed = $false

try {
    Write-Stage ''
    Write-Stage '1/6 Initialize temporary Git repository...'
    Push-Location $repoDir
    try {
        Assert-GitOk -Result (Invoke-GitCapture -Exe $GitExe -Args @('init', '-q')) -Label 'git init'
        Assert-GitOk -Result (Invoke-GitCapture -Exe $GitExe -Args @('config', 'user.name', 'Patch Generator')) -Label 'git config user.name'
        Assert-GitOk -Result (Invoke-GitCapture -Exe $GitExe -Args @('config', 'user.email', 'patch@example.invalid')) -Label 'git config user.email'

        Write-Stage ''
        Write-Stage '2/6 Add original fe.gfx as baseline...'
        Copy-Item -LiteralPath $OriginalFile -Destination $repoFile -Force
        Assert-GitOk -Result (Invoke-GitCapture -Exe $GitExe -Args @('add', '--', $PatchTargetPath)) -Label 'git add original'
        Assert-GitOk -Result (Invoke-GitCapture -Exe $GitExe -Args @('commit', '-q', '-m', 'original')) -Label 'git commit original'

        Write-Stage ''
        Write-Stage '3/6 Replace baseline with modified fe.gfx...'
        Copy-Item -LiteralPath $ModifiedFile -Destination $repoFile -Force
        Assert-GitOk -Result (Invoke-GitCapture -Exe $GitExe -Args @('add', '--', $PatchTargetPath)) -Label 'git add modified'

        Write-Stage ''
        Write-Stage '4/6 Generate binary patch...'
        if (Test-Path -LiteralPath $PatchOut -PathType Leaf) {
            Remove-Item -LiteralPath $PatchOut -Force
        }

        $diffArgs = @('diff', '--binary', '--cached', '--', $PatchTargetPath)
        $patchText = & $GitExe @diffArgs 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            foreach ($line in @($patchText)) { Write-Info ([string]$line) }
            throw "git diff export failed with exit code $exitCode."
        }

        $patchString = (@($patchText) -join "`n") + "`n"
        [System.IO.File]::WriteAllText($PatchOut, $patchString, (New-Object System.Text.UTF8Encoding($false)))
    }
    finally {
        Pop-Location -ErrorAction SilentlyContinue
    }

    Write-Stage ''
    Write-Stage '5/6 Validate generated patch file...'
    if (-not (Test-Path -LiteralPath $PatchOut -PathType Leaf)) {
        throw "Patch file was not created: $PatchOut"
    }

    $patchInfo = Get-Item -LiteralPath $PatchOut
    if ($patchInfo.Length -le 0) {
        throw "Patch file is empty: $PatchOut"
    }

    Write-Stage ''
    Write-Stage '6/6 Report hashes...'
    $origHash = (Get-FileHash -LiteralPath $OriginalFile -Algorithm SHA256).Hash
    $modHash = (Get-FileHash -LiteralPath $ModifiedFile -Algorithm SHA256).Hash
    $patchHash = (Get-FileHash -LiteralPath $PatchOut -Algorithm SHA256).Hash

    Write-Info "Patch created: $PatchOut"
    Write-Info "Patch size: $($patchInfo.Length) bytes"
    Write-Info "Original SHA256: $origHash"
    Write-Info "Modified SHA256: $modHash"
    Write-Info "Patch SHA256: $patchHash"

    $completed = $true
}
finally {
    $overall.Stop()
    if ($completed -and -not $KeepWork) {
        try {
            Remove-SafeTempDir -Path $tempRoot
            Write-Info "Removed temp work folder: $tempRoot"
        } catch {
            Write-Warning $_.Exception.Message
        }
    } else {
        Write-Info "Kept temp work folder: $tempRoot"
    }
}

Write-Stage ''
Write-Stage 'Done.'
Write-Info ('Elapsed: {0}' -f $overall.Elapsed)
