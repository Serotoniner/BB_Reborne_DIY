<#
    03_Global_BBReborne_Menu_fe.ps1

    Harmonized menu binary patch script for the BB Reborne DIY Tool.

    Purpose:
    - Copy menu\fe.gfx from the configured game folder.
    - Apply the binary Git patch from Diffs\menu\_patch\fe.patch.
    - Work only on isolated copies under the configured output folder.
    - Produce the patched file under:
        <OutputRoot>\BBReborne_menu\menu\fe.gfx

    Original game files are never modified. They are the backup.

    Expected config file from BBReborneDIYTool.ps1:
        <ToolRoot>\BBReborneDIYTool.paths.ps1

    Example direct run:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\03_Global_BBReborne_Menu_fe.ps1 `
            -ToolPathsPs1 "<BBReborneDIYTool>\Tools\BBReborneDIYTool.paths.ps1"
#>

param(
    [string]$ToolPathsPs1,
    [string]$GameRoot,
    [string]$OutputRoot,
    [string]$GitExe,
    [int]$CpuThrottle = 0,
    [int]$GpuThrottle = 0,

    [string]$SourceRelativePath = 'menu\fe.gfx',
    [string]$PatchFile,
    [string]$OutputRelativePath = 'menu\fe.gfx',

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
        Get-Variable -Scope Local -Name 'BBR_*' -ErrorAction SilentlyContinue | ForEach-Object {
            Set-Variable -Name $_.Name -Value $_.Value -Scope Script
        }

        return $configPath
    } else {
        Write-Info 'No tool config file found. Parameters must provide all required paths.'
        return $null
    }
}

function Resolve-RequiredDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label is empty. Pass -$($Label.Replace(' ', '')) or save paths again in the tool."
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

function Resolve-DefaultPatchFile {
    if ($PatchFile) {
        return (Resolve-RequiredFile -Path $PatchFile -Label 'Git binary patch')
    }

    $relative = 'Diffs\menu\_patch\fe.patch'
    foreach ($root in Get-DIYRootCandidates) {
        $candidate = Join-Path $root $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Git binary patch not found. Expected default path: <BBReborneDIYTool>\$relative"
}

function Resolve-GameFile {
    param(
        [Parameter(Mandatory)][string]$GameRootPath,
        [Parameter(Mandatory)][string]$RelativeOrAbsolutePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativeOrAbsolutePath)) {
        $file = Resolve-RequiredFile -Path $RelativeOrAbsolutePath -Label 'Source menu file'
        return [pscustomobject]@{
            FullPath     = $file
            RelativePath = Split-Path -Leaf $file
        }
    }

    $candidate = Join-Path $GameRootPath $RelativeOrAbsolutePath
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Source menu file not found: $candidate"
    }

    return [pscustomobject]@{
        FullPath     = (Resolve-Path -LiteralPath $candidate).Path
        RelativePath = ($RelativeOrAbsolutePath -replace '/', '\')
    }
}

function Normalize-GitPatchFile {
    param(
        [Parameter(Mandatory)][string]$InputPatch,
        [Parameter(Mandatory)][string]$OutputPatch
    )

    $raw = [System.IO.File]::ReadAllText($InputPatch)
    $normalized = $raw -replace "`r`n", "`n"
    $normalized = $normalized -replace "`r", "`n"
    [System.IO.File]::WriteAllText(
        $OutputPatch,
        $normalized,
        (New-Object System.Text.UTF8Encoding($false))
    )

    return $normalized
}

function Get-PatchTargetPath {
    param([Parameter(Mandatory)][string]$PatchText)

    $diffMatch = [regex]::Match($PatchText, '(?m)^diff --git a/(.+?) b/(.+?)\s*$')
    if ($diffMatch.Success) {
        return (($diffMatch.Groups[2].Value) -replace '/', '\')
    }

    $indexMatch = [regex]::Match($PatchText, '(?m)^\+\+\+ b/(.+?)\s*$')
    if ($indexMatch.Success) {
        return (($indexMatch.Groups[1].Value) -replace '/', '\')
    }

    return 'payload\fe.gfx'
}

function Assert-SafeRepoRelativePath {
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

    return ($RelativePath -replace '/', '\')
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

$configPath = Import-ToolConfig

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
if (-not $GitExe) {
    $GitExe = Get-FirstConfigValue -Names @('BBR_GitExe', 'BBR_GitForWindowsExe')
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
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$GitExe = Resolve-RequiredFile -Path $GitExe -Label 'Git executable'
$PatchFile = Resolve-DefaultPatchFile
$script:OutputRoot = $OutputRoot

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

$sourceFile = Resolve-GameFile -GameRootPath $GameRoot -RelativeOrAbsolutePath $SourceRelativePath
$menuOutputRoot = Join-Path $OutputRoot 'BBReborne_menu'
$finalFilePath = Join-Path $menuOutputRoot $OutputRelativePath
$finalFileDir = Split-Path -Parent $finalFilePath
New-Item -ItemType Directory -Path $finalFileDir -Force | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$workRoot = Join-Path $OutputRoot '_work'
$runWorkDir = Join-Path $workRoot "menu_fe_gitpatch_$stamp"
$repoDir = Join-Path $runWorkDir 'repo'
$tempPatch = Join-Path $runWorkDir 'normalized.patch'
New-Item -ItemType Directory -Path $repoDir -Force | Out-Null

Write-Info "GameRoot      = $GameRoot"
Write-Info "OutputRoot    = $OutputRoot"
Write-Info "GitExe        = $GitExe"
Write-Info "CpuThrottle   = $CpuThrottle"
Write-Info "GpuThrottle   = $GpuThrottle"
Write-Info "SourceFile    = $($sourceFile.FullPath)"
Write-Info "PatchFile     = $PatchFile"
Write-Info "FinalFile     = $finalFilePath"
Write-Info "WorkDir       = $runWorkDir"

$overall = [System.Diagnostics.Stopwatch]::StartNew()
$completed = $false

try {
    Write-Stage ''
    Write-Stage '1/5 Normalize binary patch and detect target path...'
    $patchText = Normalize-GitPatchFile -InputPatch $PatchFile -OutputPatch $tempPatch
    $patchTargetRelativePath = Assert-SafeRepoRelativePath -RelativePath (Get-PatchTargetPath -PatchText $patchText)
    $repoFile = Join-Path $repoDir $patchTargetRelativePath
    $repoFileDir = Split-Path -Parent $repoFile
    New-Item -ItemType Directory -Path $repoFileDir -Force | Out-Null
    Write-Info "Patch target path inside repo: $patchTargetRelativePath"

    Write-Stage ''
    Write-Stage '2/5 Initialize temporary Git repository...'
    Push-Location $repoDir
    try {
        $initResult = Invoke-GitCapture -Exe $GitExe -Args @('init', '-q')
        foreach ($line in $initResult.Output) { Write-Info ([string]$line) }
        if ($initResult.ExitCode -ne 0) {
            throw "git init failed with exit code $($initResult.ExitCode)"
        }

        Write-Stage ''
        Write-Stage '3/5 Copy source fe.gfx into patch target path...'
        Copy-Item -LiteralPath $sourceFile.FullPath -Destination $repoFile -Force
        Write-Info "Copied source into repo: $repoFile"

        Write-Stage ''
        Write-Stage '4/5 Apply Git binary patch...'

        $applyAttempts = @(
            @('apply', '--binary', '--reject', '--whitespace=nowarn', '-p1', $tempPatch),
            @('apply', '--binary', '--reject', '--whitespace=nowarn', '-p0', $tempPatch)
        )

        $applied = $false
        $lastFailure = $null

        foreach ($args in $applyAttempts) {
            Write-Info "Trying: git $($args -join ' ')"
            $result = Invoke-GitCapture -Exe $GitExe -Args $args
            foreach ($line in $result.Output) { Write-Info ([string]$line) }

            if ($result.ExitCode -eq 0) {
                $applied = $true
                break
            }

            $lastFailure = "Command failed with exit code $($result.ExitCode): git $($args -join ' ')"
        }

        if (-not $applied) {
            throw $lastFailure
        }
    }
    finally {
        Pop-Location -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $repoFile -PathType Leaf)) {
        throw "Patched repo file not found after git apply: $repoFile"
    }

    Write-Stage ''
    Write-Stage '5/5 Copy patched fe.gfx to output folder...'
    Copy-Item -LiteralPath $repoFile -Destination $finalFilePath -Force

    $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullPath -Algorithm SHA256).Hash
    $outputHash = (Get-FileHash -LiteralPath $finalFilePath -Algorithm SHA256).Hash

    Write-Info "Patched file written: $finalFilePath"
    Write-Info "Source SHA256: $sourceHash"
    Write-Info "Output SHA256: $outputHash"

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

if (-not $completed) {
    exit 1
}
