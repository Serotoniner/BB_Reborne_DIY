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
    01b_Mapfiles_BBReborne_FLVER_GenerateDiffs.ps1

    FLVER JSON patch generator.
    v4c: fixes duplicated dump manifest export line and keeps live ThreadJob progress.

    Pipeline:
    1) Compare *.flver.dcx files from NewDir against OldDir by hash.
    2) Copy only changed matching pairs into a safe work folder.
    3) Batch decompress copied DCX files with WitchyBND:
          m21_00_00_00\m21_00_00_00_0000.flver.dcx -> m21_00_00_00\m21_00_00_00_0000.flver
    4) Dump FLVER -> JSON with FlverJsonTool.
    5) Compare JSON hashes.
    6) Export portable Git patches only when the dumped JSON differs.
    7) Cleanup the safe work folder unless -KeepWork is used.

    Output layout by default, matching the staged patch repository workflow:
        <NewDir>\files
            all_changed_flver_json.patch
            compare_flvers.csv
            dump_manifest.csv
            json_patch_manifest.csv
            m21_00_00_00\_patches
                m21_00_00_00_0000.flver.patch
                m21_00_00_00_0001.flver.patch

        <NewDir>\_patch_work
            a\...   # old/original copied DCX, extracted FLVER, JSON
            b\...   # new/changed copied DCX, extracted FLVER, JSON
            logs\...

    Important:
    - OldDir and NewDir are never cleaned.
    - Patch output is staged under <NewDir>\files so it does not share the real FLVER map folders.
    - Only <NewDir>\_patch_work is deleted/recreated.
    - A changed packed .flver.dcx is not enough to make a patch; the dumped FLVER JSON must differ.
#>

[CmdletBinding()]
param(
    # Optional tool/GUI-level inputs, added for the BBReborne script layout.
    [string]$ToolPathsPs1 = "",
    [string]$GameRoot = "",
    [string]$MapCode = "",
    [string]$MapFolder = "",

    # Original development-script inputs. Kept compatible with the existing workflow.
    [string]$OldDir = "",
    [string]$NewDir = "",
    [string]$WitchyBND = "",

    [Alias("FlverTool")]
    [string]$FlverJsonToolExe = "",

    [string]$GitExe = "git",

    [switch]$Recurse = $true,
    [switch]$DryRun,
    [switch]$KeepWork,
    [switch]$FailOnDumpFailure,

    [string]$IncludeRegex = "",
    [int]$MaxFiles = 0,
    [int]$StartAt = 0,

    [ValidateSet("SHA256","SHA1","MD5")]
    [string]$HashAlgorithm = "SHA256",

    [int]$WitchyBatchSize = 100,
    [int]$DumpThrottle = [Math]::Max(1, [Math]::Min(6, [int]([Environment]::ProcessorCount / 4))),

    [string]$PatchDirName = "_patches",
    [string]$WorkDirName  = "_patch_work",

    [string]$DumpCommand = "dump"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$global:PSNativeCommandUseErrorActionPreference = $false
$global:PSNativeCommandArgumentPassing = "Standard"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "This script requires PowerShell 7+. Run it with pwsh."
}

if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
    Import-Module ThreadJob -ErrorAction Stop
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
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
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

function Get-RelPath([string]$Root, [string]$Full) {
    $rootN = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $fullN = [IO.Path]::GetFullPath($Full)
    if (-not $fullN.StartsWith($rootN, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is not under root. Root='$rootN' Full='$fullN'"
    }
    return $fullN.Substring($rootN.Length)
}

function Get-FileHashText([string]$Path, [string]$Algorithm) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    return (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLowerInvariant()
}

function Get-FlverBaseFromLeaf([string]$Leaf) {
    if ([string]::IsNullOrWhiteSpace($Leaf)) { return "" }
    $x = $Leaf
    $x = $x -replace '(?i)\.patch$', ''
    $x = $x -replace '(?i)\.dcx$', ''
    $x = $x -replace '(?i)\.flver\.json$', ''
    $x = $x -replace '(?i)\.flver$', ''
    return $x
}

function Get-FlverJsonRelFromDcxRel([string]$Rel) {
    return (($Rel -replace '\.dcx$', '') + '.json')
}

function Get-TopFolderFromRel([string]$Rel) {
    $relN = ($Rel -replace '\\','/').TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($relN)) { return "." }
    $parts = $relN -split '/', 2
    if ($parts.Count -lt 2) { return "." }
    return $parts[0]
}


function Convert-MapCodeToMapFolder([string]$Code) {
    $clean = ($Code.Trim()).ToLowerInvariant()
    if ($clean -match '^m\d{2}_\d{2}_\d{2}_\d{2}$') { return $clean }
    if ($clean -match '^m\d{2}$') { return ("{0}_00_00_00" -f $clean) }
    throw "Unsupported MapCode '$Code'. Expected values like M21 or m21_00_00_00."
}

function Get-BBReborneProjectRoot([string]$ToolPathsFile) {
    if (-not [string]::IsNullOrWhiteSpace($ToolPathsFile)) {
        $toolPathsFull = [IO.Path]::GetFullPath($ToolPathsFile)
        $toolRootFromFile = Split-Path -Parent $toolPathsFull
        if ((Split-Path -Leaf $toolRootFromFile) -ieq 'Tools') {
            return (Split-Path -Parent $toolRootFromFile)
        }
    }

    # This script is expected under <ProjectRoot>\Scripts\Mapfiles.
    $scriptsRoot = Split-Path -Parent $PSScriptRoot
    return (Split-Path -Parent $scriptsRoot)
}

function Get-PatchDirForRel([string]$Rel) {
    # Staged repository layout requested by the project:
    #   <NewDir>\files\m21_00_00_00\_patches\m21_00_00_00_0000.flver.patch
    # Aggregate manifests stay at <NewDir>\files, not inside the real source map folders.
    $top = Get-TopFolderFromRel $Rel
    if ($top -eq ".") { return (Join-Path $outRoot $PatchDirName) }
    return (Join-Path (Join-Path $outRoot $top) $PatchDirName)
}

function Get-PatchLeafForJsonRel([string]$JsonRel) {
    # Keep the typed extension in the patch filename so FLVER and future BTPB patches
    # can coexist in the same map _patches folder:
    #   m21_00_00_00_0000.flver.patch
    #   m21_00_00_00_0000.btpb.patch
    $leaf = Split-Path -Leaf (($JsonRel -replace '\\','/'))
    $leaf = ($leaf -replace '\.flver\.json$', '.flver.patch')
    if (-not $leaf.EndsWith('.patch', [StringComparison]::OrdinalIgnoreCase)) { $leaf = $leaf + '.patch' }
    return $leaf
}

function Get-FilePatchDirForRel([string]$Rel) {
    return (Get-PatchDirForRel $Rel)
}

function Export-RowsByPatchDir {
    param(
        [Parameter(Mandatory=$true)][object[]]$Rows,
        [Parameter(Mandatory=$true)][string]$FileName,
        [string]$RelProperty = "Rel"
    )

    # Aggregate manifests are written once at <NewDir>\files. The per-map _patches
    # folders hold only the individual .flver.patch files.
    Ensure-Dir $outRoot
    $outCsv = Join-Path $outRoot $FileName
    @($Rows) | Sort-Object $RelProperty | Export-Csv -LiteralPath $outCsv -NoTypeInformation -Encoding UTF8
}

function Clear-StaleFlverPatchOutputsForRows {
    param([Parameter(Mandatory=$true)][object[]]$Rows)

    # Do not remove any real source folders. Only remove previous generated FLVER
    # patch artifacts from each map _patches folder and the root aggregate patch.
    $rootAllPatch = Join-Path $outRoot "all_changed_flver_json.patch"
    if (Test-Path -LiteralPath $rootAllPatch -PathType Leaf) { Remove-Item -LiteralPath $rootAllPatch -Force }

    $rootFailCsv = Join-Path $outRoot "patch_export_failures.csv"
    if (Test-Path -LiteralPath $rootFailCsv -PathType Leaf) { Remove-Item -LiteralPath $rootFailCsv -Force }

    if ($Rows.Count -eq 0) { return }
    $patchDirs = @($Rows | ForEach-Object { Get-PatchDirForRel $_.Rel } | Sort-Object -Unique)
    foreach ($pd in $patchDirs) {
        Ensure-Dir $pd
        Get-ChildItem -LiteralPath $pd -File -Filter "*.flver.patch" -ErrorAction SilentlyContinue | Remove-Item -Force
    }
}

function Get-FlverIndex([string]$Root, [bool]$DoRecurse, [string]$RegexText, [string[]]$ExcludeTopFolders) {
    $gciParams = @{
        LiteralPath = $Root
        Filter      = "*.flver.dcx"
        File        = $true
    }
    if ($DoRecurse) { $gciParams.Recurse = $true }

    $files = @(Get-ChildItem @gciParams | Sort-Object FullName)

    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $rel = Get-RelPath -Root $Root -Full $f.FullName
        $top = ($rel -split '[\\/]', 2)[0]
        if ($ExcludeTopFolders -contains $top) { continue }
        if (-not [string]::IsNullOrWhiteSpace($RegexText)) {
            $re = [regex]::new($RegexText, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not ($re.IsMatch($f.Name) -or $re.IsMatch($f.FullName))) { continue }
        }
        [void]$filtered.Add([pscustomobject]@{
            Rel      = $rel
            FullName = $f.FullName
            Name     = $f.Name
            Length   = [int64]$f.Length
        })
    }

    $map = @{}
    foreach ($f in $filtered) {
        $map[$f.Rel.ToLowerInvariant()] = $f
    }
    return $map
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [string]$WorkingDirectory = "",
        [int[]]$AllowedExitCodes = @(0),
        [string]$Label = "native command"
    )

    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        & $Exe @Arguments | Out-Null
        $code = $LASTEXITCODE
        if ($AllowedExitCodes -notcontains $code) {
            throw "$Label failed with exit code $code. Command: $Exe $($Arguments -join ' ')"
        }
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { Pop-Location }
    }
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [string]$WorkingDirectory = ""
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add($arg) }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    return [pscustomobject]@{
        ExitCode = [int]$p.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}


function Normalize-GitNoIndexPatchHeaders {
    param(
        [Parameter(Mandatory=$true)][string]$InputPatch,
        [Parameter(Mandatory=$true)][string]$OutputPatch,
        [Parameter(Mandatory=$true)][string]$JsonRelPosix
    )

    # Important:
    # Only rewrite git patch header lines. Do NOT do broad path replacement,
    # because FLVER JSON body lines can legitimately contain paths like:
    #   "N:\\SPRJ\\data\\Other\\SysTex\\SYSTEX_DummyNormal.tga"
    # Those body lines must remain byte-for-byte as Git produced them.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $reader = [System.IO.StreamReader]::new($InputPatch, [System.Text.Encoding]::UTF8, $true)
    $writer = [System.IO.StreamWriter]::new($OutputPatch, $false, $utf8NoBom)

    $insideFileHeader = $false
    $sawMinusHeader = $false
    $sawPlusHeader = $false

    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.StartsWith("diff --git ")) {
                $writer.WriteLine(("diff --git a/{0} b/{0}" -f $JsonRelPosix))
                $insideFileHeader = $true
                $sawMinusHeader = $false
                $sawPlusHeader = $false
                continue
            }

            if ($insideFileHeader -and -not $sawMinusHeader -and $line.StartsWith("--- ")) {
                $writer.WriteLine(("--- a/{0}" -f $JsonRelPosix))
                $sawMinusHeader = $true
                continue
            }

            if ($insideFileHeader -and $sawMinusHeader -and -not $sawPlusHeader -and $line.StartsWith("+++ ")) {
                $writer.WriteLine(("+++ b/{0}" -f $JsonRelPosix))
                $sawPlusHeader = $true
                continue
            }

            # Once the first hunk begins, all following -/+ lines are patch body.
            # Never rewrite body content, even if it contains Windows paths.
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


function Invoke-GitDiffSimpleToPatchFile {
    param(
        [Parameter(Mandatory=$true)][string]$GitExe,
        [Parameter(Mandatory=$true)][string]$WorkDir,
        [Parameter(Mandatory=$true)][string]$OldRelToWork,
        [Parameter(Mandatory=$true)][string]$NewRelToWork,
        [Parameter(Mandatory=$true)][string]$JsonRelPosix,
        [Parameter(Mandatory=$true)][string]$PatchPath
    )

    $patchDir = Split-Path -Parent $PatchPath
    if (-not (Test-Path -LiteralPath $patchDir -PathType Container)) {
        New-Item -ItemType Directory -Path $patchDir -Force | Out-Null
    }

    $tmpRaw = "$PatchPath.raw.tmp"
    $tmpErr = "$PatchPath.err.tmp"
    $tmpNorm = "$PatchPath.norm.tmp"

    Remove-Item -LiteralPath $tmpRaw  -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpErr  -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpNorm -Force -ErrorAction SilentlyContinue

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $GitExe
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow = $true

    # Match the older Diff_flvers.ps1 backend: run git from inside workRoot
    # and diff relative a\... vs b\... paths. This avoids the m26_009100
    # crash seen with the absolute-path/ProcessStartInfo variant while keeping
    # output streaming and repository-safe header normalization.
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

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    [void]$proc.Start()

    $outStream = [System.IO.File]::Open($tmpRaw, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $errStream = [System.IO.File]::Open($tmpErr, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)

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
        Normalize-GitNoIndexPatchHeaders -InputPatch $tmpRaw -OutputPatch $tmpNorm -JsonRelPosix $JsonRelPosix
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
        $errText = (Get-Content -LiteralPath $tmpErr -Raw -ErrorAction SilentlyContinue)
    }

    return [pscustomobject]@{
        ExitCode = $code
        Status   = "Failed"
        Error    = ("git diff failed with exit code {0}. {1}" -f $code, (($errText -split "`r?`n") | Select-Object -First 1))
    }
}


function Invoke-WitchyBatchSimple {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string[]]$Paths,
        [int]$BatchSize = 50,
        [string]$Label = "WitchyBND"
    )

    $total = $Paths.Count
    if ($total -eq 0) { return }

    for ($start = 0; $start -lt $total; $start += $BatchSize) {
        $endExclusive = [Math]::Min($start + $BatchSize, $total)
        $batch = @($Paths[$start..($endExclusive - 1)])
        $batchNum = [int]([Math]::Floor($start / $BatchSize) + 1)
        Write-Host ("  {0} batch {1}: files {2}-{3} ({4} files)" -f $Label, $batchNum, ($start + 1), $endExclusive, $batch.Count)
        Invoke-NativeChecked -Exe $Exe -Arguments $batch -Label "$Label batch $batchNum"
    }
}


# ------------------------------------------------------------
# Resolve optional BBReborne tool-level inputs.
# ------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($ToolPathsPs1)) {
    Assert-File $ToolPathsPs1 "ToolPathsPs1"
    . $ToolPathsPs1
}

$projectRoot = Get-BBReborneProjectRoot -ToolPathsFile $ToolPathsPs1

if ([string]::IsNullOrWhiteSpace($MapFolder) -and -not [string]::IsNullOrWhiteSpace($MapCode)) {
    $MapFolder = Convert-MapCodeToMapFolder $MapCode
}
if ([string]::IsNullOrWhiteSpace($MapCode) -and -not [string]::IsNullOrWhiteSpace($MapFolder)) {
    $MapCode = (($MapFolder -split '_')[0]).ToUpperInvariant()
}

if ([string]::IsNullOrWhiteSpace($GameRoot) -and (Test-Path variable:BBR_GameRoot)) { $GameRoot = $BBR_GameRoot }

# FLVER development patch generation uses WitchyBND v2.14.4.5.
if ([string]::IsNullOrWhiteSpace($WitchyBND) -and (Test-Path variable:BBR_WitchyBND_v2_14_4_5)) { $WitchyBND = $BBR_WitchyBND_v2_14_4_5 }
if ([string]::IsNullOrWhiteSpace($FlverJsonToolExe) -and (Test-Path variable:BBR_FlverJsonToolExe)) { $FlverJsonToolExe = $BBR_FlverJsonToolExe }
if (($GitExe -eq "git" -or [string]::IsNullOrWhiteSpace($GitExe)) -and (Test-Path variable:BBR_GitExe) -and -not [string]::IsNullOrWhiteSpace($BBR_GitExe)) { $GitExe = $BBR_GitExe }

if (-not [string]::IsNullOrWhiteSpace($MapFolder) -and [string]::IsNullOrWhiteSpace($OldDir)) {
    if ([string]::IsNullOrWhiteSpace($GameRoot)) { throw 'GameRoot is required when OldDir is not provided.' }
    $OldDir = Join-Path (Join-Path $GameRoot 'map') $MapFolder
}

foreach ($required in @(
    [pscustomobject]@{ Name='OldDir'; Value=$OldDir },
    [pscustomobject]@{ Name='NewDir'; Value=$NewDir },
    [pscustomobject]@{ Name='WitchyBND'; Value=$WitchyBND },
    [pscustomobject]@{ Name='FlverJsonToolExe'; Value=$FlverJsonToolExe }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
        throw "$($required.Name) is required. Pass it directly or pass ToolPathsPs1/GameRoot/MapCode where applicable."
    }
}

if (-not [string]::IsNullOrWhiteSpace($MapCode)) { Write-Host ("MapCode:     {0}" -f $MapCode) }
if (-not [string]::IsNullOrWhiteSpace($MapFolder)) { Write-Host ("MapFolder:   {0}" -f $MapFolder) }
Write-Host ("ProjectRoot: {0}" -f $projectRoot)

$timer = [Diagnostics.Stopwatch]::StartNew()
$success = $false

$oldRoot = [IO.Path]::GetFullPath($OldDir)
$newRoot = [IO.Path]::GetFullPath($NewDir)
$outRoot = Join-Path $newRoot "files"
Assert-Dir  $oldRoot "OldDir"
Assert-Dir  $newRoot "NewDir"
Assert-File $WitchyBND "WitchyBND"
Assert-File $FlverJsonToolExe "FlverJsonToolExe"

$workRoot = Join-Path $newRoot $WorkDirName
$workA = Join-Path $workRoot "a"
$workB = Join-Path $workRoot "b"
$logsDir = Join-Path $workRoot "logs"

try {
    if (-not $DryRun) {
        Ensure-Dir $outRoot
        Reset-ScratchFolder -Path $workRoot -ExpectedLeaf $WorkDirName
        foreach ($d in @($workA,$workB,$logsDir)) { Ensure-Dir $d }
    }

    # ------------------------------------------------------------
    # Stage #0: discover, match, hash
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #0: discovering and hashing FLVER DCX files..."

    $excludeTop = @($PatchDirName, $WorkDirName, "files")
    $oldIndex = Get-FlverIndex -Root $oldRoot -DoRecurse ([bool]$Recurse) -RegexText $IncludeRegex -ExcludeTopFolders $excludeTop
    $newIndex = Get-FlverIndex -Root $newRoot -DoRecurse ([bool]$Recurse) -RegexText $IncludeRegex -ExcludeTopFolders $excludeTop
    $allKeys = @($oldIndex.Keys + $newIndex.Keys | Sort-Object -Unique)

    if ($StartAt -gt 0) {
        if ($StartAt -ge $allKeys.Count) { throw "-StartAt $StartAt >= FLVER count $($allKeys.Count)" }
        $allKeys = @($allKeys[$StartAt..($allKeys.Count - 1)])
    }
    if ($MaxFiles -gt 0 -and $allKeys.Count -gt $MaxFiles) {
        $allKeys = @($allKeys | Select-Object -First $MaxFiles)
    }

    if ($allKeys.Count -eq 0) {
        Write-Host "No *.flver.dcx files found after filters."
        $success = $true
        return
    }

    $compareRows = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($key in $allKeys) {
        $n++
        if (($n % 25) -eq 0 -or $n -eq $allKeys.Count) {
            Write-Progress -Activity "Hash FLVER DCX files" -Status ("{0}/{1}" -f $n, $allKeys.Count) -PercentComplete ([int](100.0 * $n / $allKeys.Count))
        }

        $oldFile = if ($oldIndex.ContainsKey($key)) { $oldIndex[$key] } else { $null }
        $newFile = if ($newIndex.ContainsKey($key)) { $newIndex[$key] } else { $null }

        $rel = if ($null -ne $newFile) { $newFile.Rel } else { $oldFile.Rel }
        $oldPath = if ($null -ne $oldFile) { $oldFile.FullName } else { "" }
        $newPath = if ($null -ne $newFile) { $newFile.FullName } else { "" }
        $oldHash = if ($oldPath) { Get-FileHashText -Path $oldPath -Algorithm $HashAlgorithm } else { "" }
        $newHash = if ($newPath) { Get-FileHashText -Path $newPath -Algorithm $HashAlgorithm } else { "" }
        $oldSize = if ($null -ne $oldFile) { [int64]$oldFile.Length } else { 0 }
        $newSize = if ($null -ne $newFile) { [int64]$newFile.Length } else { 0 }

        $status = "Same"
        if (-not $oldPath -and $newPath) { $status = "Added" }
        elseif ($oldPath -and -not $newPath) { $status = "Removed" }
        elseif ($oldHash -ne $newHash) { $status = "Changed" }

        [void]$compareRows.Add([pscustomobject]@{
            FlverBase = Get-FlverBaseFromLeaf (Split-Path -Leaf $rel)
            Rel     = $rel
            JsonRel = Get-FlverJsonRelFromDcxRel $rel
            Status  = $status
            OldPath = $oldPath
            NewPath = $newPath
            OldSize = $oldSize
            NewSize = $newSize
            OldHash = $oldHash
            NewHash = $newHash
        })
    }
    Write-Progress -Activity "Hash FLVER DCX files" -Completed

    if (-not $DryRun) {
        Export-RowsByPatchDir -Rows @($compareRows) -FileName "compare_flvers.csv" -RelProperty "Rel"
    }

    $sameCount    = @($compareRows | Where-Object Status -eq "Same").Count
    $changedCount = @($compareRows | Where-Object Status -eq "Changed").Count
    $addedCount   = @($compareRows | Where-Object Status -eq "Added").Count
    $removedCount = @($compareRows | Where-Object Status -eq "Removed").Count
    Write-Host ("FLVER DCX compare done. Same={0} Changed={1} Added={2} Removed={3}" -f $sameCount, $changedCount, $addedCount, $removedCount)
    if (-not $DryRun) { Write-Host ("Compare CSV: {0}" -f (Join-Path $outRoot "compare_flvers.csv")) }

    $changedRows = @($compareRows | Where-Object { $_.Status -eq "Changed" } | Sort-Object Rel)
    $nonPatchable = @($compareRows | Where-Object { $_.Status -in @("Added","Removed") })
    if ($nonPatchable.Count -gt 0) {
        Write-Host ("  Note: Added/Removed FLVERs are listed in compare_flvers.csv but skipped for JSON patch export: {0}" -f $nonPatchable.Count) -ForegroundColor Yellow
    }


    if (-not $DryRun) {
        Clear-StaleFlverPatchOutputsForRows -Rows @($compareRows)
    }

    if ($changedRows.Count -eq 0) {
        Write-Host "No changed matching FLVER DCX files. Nothing to decompress or patch."
        $success = $true
        return
    }

    if ($DryRun) {
        Write-Host "DRYRUN: stopping after hash compare."
        $success = $true
        return
    }

    # ------------------------------------------------------------
    # Stage #1: copy changed FLVER DCX files into work/a and work/b
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #1: copying {0} changed FLVER DCX pairs into work..." -f $changedRows.Count)

    $workRows = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $changedRows) {
        $oldCopy = Join-Path $workA $r.Rel
        $newCopy = Join-Path $workB $r.Rel
        Ensure-Dir (Split-Path -Parent $oldCopy)
        Ensure-Dir (Split-Path -Parent $newCopy)
        Copy-Item -LiteralPath $r.OldPath -Destination $oldCopy -Force
        Copy-Item -LiteralPath $r.NewPath -Destination $newCopy -Force

        [void]$workRows.Add([pscustomobject]@{
            FlverBase = $r.FlverBase
            Rel     = $r.Rel
            JsonRel = $r.JsonRel
            Status  = $r.Status
            OldDcx  = $oldCopy
            NewDcx  = $newCopy
            OldFlver  = ($oldCopy -replace '\.dcx$', '')
            NewFlver  = ($newCopy -replace '\.dcx$', '')
            OldJson = Join-Path $workA $r.JsonRel
            NewJson = Join-Path $workB $r.JsonRel
        })
    }

    # ------------------------------------------------------------
    # Stage #2: decompress with WitchyBND
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #2: decompressing FLVER DCX with WitchyBND, batchSize={0}..." -f $WitchyBatchSize)

    $dcxToDecompress = @(
        @($workRows | ForEach-Object { $_.OldDcx }) +
        @($workRows | ForEach-Object { $_.NewDcx })
    )
    Invoke-WitchyBatchSimple -Exe $WitchyBND -Paths $dcxToDecompress -BatchSize $WitchyBatchSize -Label "WitchyBND decompress"

    $missingFlver = @($workRows | Where-Object { -not (Test-Path -LiteralPath $_.OldFlver -PathType Leaf) -or -not (Test-Path -LiteralPath $_.NewFlver -PathType Leaf) })
    if ($missingFlver.Count -gt 0) {
        $missingCsv = Join-Path $workRoot "missing_flver_after_witchy.csv"
        $missingFlver | Export-Csv -LiteralPath $missingCsv -NoTypeInformation -Encoding UTF8
        throw "Could not locate decompressed FLVER for $($missingFlver.Count) file(s). See: $missingCsv"
    }

    # ------------------------------------------------------------
    # Stage #3: dump FLVER JSON
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #3: dumping FLVER JSON, throttle={0}..." -f $DumpThrottle)
    Write-Host "  Using captured native process output so parser exceptions are logged per file instead of aborting the whole run."

    $dumpItems = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $workRows) {
        [void]$dumpItems.Add([pscustomobject]@{ FlverBase=$r.FlverBase; Rel=$r.Rel; JsonRel=$r.JsonRel; Side="old"; Flver=$r.OldFlver; Json=$r.OldJson })
        [void]$dumpItems.Add([pscustomobject]@{ FlverBase=$r.FlverBase; Rel=$r.Rel; JsonRel=$r.JsonRel; Side="new"; Flver=$r.NewFlver; Json=$r.NewJson })
    }

    # Keep this stage deliberately simple and robust. FLVER files are few, and using a captured
    # ProcessStartInfo avoids PowerShell turning native stderr into a terminating error.
    # Parallel dump stage, adapted from the faster ThreadJob/fused approach used by Patch-Flvers_Batch_v12.
    # This generator does not rebuild, but old/new FLVER dumps are independent and safe to run concurrently.
    $dumpResultsList = [System.Collections.Generic.List[object]]::new()
    $dumpQueue = [System.Collections.Queue]::new()
    foreach ($it in $dumpItems) { [void]$dumpQueue.Enqueue($it) }

    $dumpRunning = @()
    $dumpTotal = $dumpItems.Count
    $dumpDone = 0

    Write-Progress -Activity "Dump FLVER JSON" -Status ("0/{0}: starting..." -f $dumpTotal) -PercentComplete 0

    while ($dumpQueue.Count -gt 0 -or $dumpRunning.Count -gt 0) {
        while ($dumpRunning.Count -lt $DumpThrottle -and $dumpQueue.Count -gt 0) {
            $jobItem = $dumpQueue.Dequeue()
            $dumpRunning += Start-ThreadJob -ArgumentList $jobItem, $FlverJsonToolExe, $DumpCommand -ScriptBlock {
                param($it, $toolExe, $dumpCmd)

                $ok = $false
                $hash = ""
                $err = ""
                $stdout = ""
                $stderr = ""

                try {
                    if (-not (Test-Path -LiteralPath $it.Flver -PathType Leaf)) { throw "Missing FLVER: $($it.Flver)" }
                    $jsonDir = Split-Path -Parent $it.Json
                    if (-not [string]::IsNullOrWhiteSpace($jsonDir)) {
                        [System.IO.Directory]::CreateDirectory($jsonDir) | Out-Null
                    }

                    $psi = [System.Diagnostics.ProcessStartInfo]::new()
                    $psi.FileName = $toolExe
                    foreach ($arg in @($dumpCmd, $it.Flver, $it.Json)) { [void]$psi.ArgumentList.Add([string]$arg) }
                    $psi.UseShellExecute = $false
                    $psi.RedirectStandardOutput = $true
                    $psi.RedirectStandardError  = $true
                    $psi.CreateNoWindow = $true

                    $p = [System.Diagnostics.Process]::new()
                    $p.StartInfo = $psi
                    [void]$p.Start()
                    $stdout = $p.StandardOutput.ReadToEnd()
                    $stderr = $p.StandardError.ReadToEnd()
                    $p.WaitForExit()

                    if ($p.ExitCode -ne 0) {
                        $detail = ($stderr + "`n" + $stdout).Trim()
                        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "FlverJsonTool produced no stderr/stdout." }
                        throw "FlverJsonTool $dumpCmd failed with exit code $($p.ExitCode): $detail"
                    }
                    if (-not (Test-Path -LiteralPath $it.Json -PathType Leaf)) { throw "JSON not produced: $($it.Json)" }

                    $hash = (Get-FileHash -LiteralPath $it.Json -Algorithm SHA256).Hash.ToLowerInvariant()
                    $ok = $true
                }
                catch {
                    $err = $_.Exception.Message
                }

                [pscustomobject]@{
                    FlverBase = $it.FlverBase
                    Rel       = $it.Rel
                    JsonRel   = $it.JsonRel
                    Side      = $it.Side
                    Flver     = $it.Flver
                    Json      = $it.Json
                    Ok        = [bool]$ok
                    JsonHash  = $hash
                    Error     = $err
                    StdErr    = $stderr
                    StdOut    = $stdout
                }
            }
        }

        $finished = @($dumpRunning | Where-Object { $_.State -in @("Completed","Failed","Stopped") })
        if ($finished.Count -eq 0) {
            $pct = if ($dumpTotal -gt 0) { [int](100.0 * $dumpDone / $dumpTotal) } else { 100 }
            Write-Progress -Activity "Dump FLVER JSON" -Status ("{0}/{1} done, {2} running..." -f $dumpDone, $dumpTotal, $dumpRunning.Count) -PercentComplete $pct
            Start-Sleep -Milliseconds 200
            continue
        }

        foreach ($job in $finished) {
            try {
                $received = @(Receive-Job -Job $job -ErrorAction Stop)
                if ($received.Count -eq 0) {
                    [void]$dumpResultsList.Add([pscustomobject]@{
                        FlverBase = ""
                        Rel       = ""
                        JsonRel   = ""
                        Side      = ""
                        Flver     = ""
                        Json      = ""
                        Ok        = $false
                        JsonHash  = ""
                        Error     = "Thread job produced no result. State=$($job.State)"
                        StdErr    = ""
                        StdOut    = ""
                    })
                } else {
                    foreach ($row in $received) { [void]$dumpResultsList.Add($row) }
                }
            }
            catch {
                [void]$dumpResultsList.Add([pscustomobject]@{
                    FlverBase = ""
                    Rel       = ""
                    JsonRel   = ""
                    Side      = ""
                    Flver     = ""
                    Json      = ""
                    Ok        = $false
                    JsonHash  = ""
                    Error     = "Thread job failed: $($_.Exception.Message)"
                    StdErr    = ""
                    StdOut    = ""
                })
            }
            finally {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                $dumpRunning = @($dumpRunning | Where-Object { $_.Id -ne $job.Id })
            }

            $dumpDone++
            $pct = if ($dumpTotal -gt 0) { [int](100.0 * $dumpDone / $dumpTotal) } else { 100 }
            Write-Progress -Activity "Dump FLVER JSON" -Status ("{0}/{1} done..." -f $dumpDone, $dumpTotal) -PercentComplete $pct
        }
    }

    Write-Progress -Activity "Dump FLVER JSON" -Completed
    $dumpResults = @($dumpResultsList)

    Export-RowsByPatchDir -Rows @($dumpResults) -FileName "dump_manifest.csv" -RelProperty "Rel"
    $dumpManifest = Join-Path $outRoot "dump_manifest.csv"
    $dumpFailures = @($dumpResults | Where-Object { -not $_.Ok })

    if ($dumpFailures.Count -gt 0) {
        Write-Host ("Stage #3 completed with dump failures: {0}. See: {1}" -f $dumpFailures.Count, $dumpManifest) -ForegroundColor Yellow
        $dumpFailures | Select-Object -First 20 | ForEach-Object {
            Write-Host ("  FAIL: {0} [{1}]" -f $_.Rel, $_.Side) -ForegroundColor Red
            Write-Host ("        {0}" -f $_.Flver) -ForegroundColor DarkGray
            Write-Host ("        {0}" -f (($_.Error -split "`r?`n") | Select-Object -First 1)) -ForegroundColor Red
        }
        if ($FailOnDumpFailure) { throw "FLVER JSON dump failed for $($dumpFailures.Count) file(s). See: $dumpManifest" }
        $KeepWork = $true
        Write-Host "  Continuing with FLVERs whose old and new JSON both dumped successfully. Work folder will be kept." -ForegroundColor Yellow
    }
    else {
        Write-Host "Dump manifest: $dumpManifest"
    }

    # ------------------------------------------------------------
    # Stage #4: compare JSON hashes
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #4: comparing dumped JSON hashes..."

    $dumpBySide = @{}
    foreach ($d in $dumpResults) { $dumpBySide[("{0}|{1}" -f $d.Rel.ToLowerInvariant(), $d.Side)] = $d }

    $jsonRows = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $workRows) {
        $oldKey = ("{0}|old" -f $r.Rel.ToLowerInvariant())
        $newKey = ("{0}|new" -f $r.Rel.ToLowerInvariant())
        $oldDump = if ($dumpBySide.ContainsKey($oldKey)) { $dumpBySide[$oldKey] } else { $null }
        $newDump = if ($dumpBySide.ContainsKey($newKey)) { $dumpBySide[$newKey] } else { $null }

        $oldOk = ($null -ne $oldDump -and $oldDump.Ok)
        $newOk = ($null -ne $newDump -and $newDump.Ok)
        $oldHash = if ($oldOk) { $oldDump.JsonHash } else { "" }
        $newHash = if ($newOk) { $newDump.JsonHash } else { "" }
        $jsonStatus = if (-not $oldOk -or -not $newOk) { "DumpFailed" } elseif ($oldHash -eq $newHash) { "Same" } else { "Changed" }

        [void]$jsonRows.Add([pscustomobject]@{
            FlverBase     = $r.FlverBase
            Rel         = $r.Rel
            JsonRel     = $r.JsonRel
            DcxStatus   = $r.Status
            JsonStatus  = $jsonStatus
            OldJson     = if ($null -ne $oldDump) { $oldDump.Json } else { $r.OldJson }
            NewJson     = if ($null -ne $newDump) { $newDump.Json } else { $r.NewJson }
            OldJsonHash = $oldHash
            NewJsonHash = $newHash
            PatchPath   = ""
        })
    }

    $jsonChangedRows = @($jsonRows | Where-Object { $_.JsonStatus -eq "Changed" } | Sort-Object JsonRel)
    $jsonManifestPre = Join-Path $outRoot "json_patch_manifest.csv"
    if ($jsonChangedRows.Count -eq 0) {
        Export-RowsByPatchDir -Rows @($jsonRows) -FileName "json_patch_manifest.csv" -RelProperty "Rel"
        if ($dumpFailures.Count -gt 0) {
            Write-Host "No patches were generated from successful dumps; one or more FLVERs failed to dump and are marked DumpFailed." -ForegroundColor Yellow
        } else {
            Write-Host "All changed FLVER DCX files produced identical FLVER JSON. No patch files were generated."
        }
        Write-Host "JSON manifest: $jsonManifestPre"
        $success = $true
        return
    }
    Write-Host ("  JSON-changing FLVERs: {0}" -f $jsonChangedRows.Count)

    # ------------------------------------------------------------
    # Stage #5: export portable Git patches
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #5: exporting Git patches for {0} JSON-changing FLVER(s)..." -f $jsonChangedRows.Count)

    $patchExportFailures = [System.Collections.Generic.List[object]]::new()
    $patchGenTotal = @($jsonChangedRows).Count
    $patchGenN = 0

    foreach ($r in $jsonChangedRows) {
        $patchGenN++
        $patchGenPercent = if ($patchGenTotal -gt 0) { [int](100.0 * $patchGenN / $patchGenTotal) } else { 100 }
        Write-Progress `
            -Activity "Generate FLVER JSON patches" `
            -Status ("{0}/{1}: {2}" -f $patchGenN, $patchGenTotal, $r.JsonRel) `
            -PercentComplete $patchGenPercent

        $patchPath = Join-Path (Get-FilePatchDirForRel $r.JsonRel) (Get-PatchLeafForJsonRel $r.JsonRel)
        Ensure-Dir (Split-Path -Parent $patchPath)
        if (Test-Path -LiteralPath $patchPath -PathType Leaf) { Remove-Item -LiteralPath $patchPath -Force }

        if (-not (Test-Path -LiteralPath $r.OldJson -PathType Leaf) -or -not (Test-Path -LiteralPath $r.NewJson -PathType Leaf)) {
            [void]$patchExportFailures.Add([pscustomobject]@{ FlverBase=$r.FlverBase; JsonRel=$r.JsonRel; Error="Missing old/new JSON file for direct diff" })
            continue
        }

        $oldRelToWork = [IO.Path]::GetRelativePath($workRoot, $r.OldJson) -replace '\\','/'
        $newRelToWork = [IO.Path]::GetRelativePath($workRoot, $r.NewJson) -replace '\\','/'

        $jsonRelPosix = ($r.JsonRel -replace '\\','/')

        $diffResult = Invoke-GitDiffSimpleToPatchFile `
            -GitExe $GitExe `
            -WorkDir $workRoot `
            -OldRelToWork $oldRelToWork `
            -NewRelToWork $newRelToWork `
            -JsonRelPosix $jsonRelPosix `
            -PatchPath $patchPath

        if ([int]$diffResult.ExitCode -eq 1) {
            $r.PatchPath = $patchPath
            $allPatch = Join-Path $outRoot "all_changed_flver_json.patch"

            if (Test-Path -LiteralPath $allPatch -PathType Leaf) {
                Add-Content -LiteralPath $allPatch -Value "" -Encoding UTF8
            }

            # Append by stream to avoid loading large patches in memory.
            $appendOut = [System.IO.File]::Open($allPatch, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            try {
                $inPatch = [System.IO.File]::OpenRead($patchPath)
                try { $inPatch.CopyTo($appendOut) }
                finally { $inPatch.Dispose() }
            }
            finally { $appendOut.Dispose() }
        }
        elseif ([int]$diffResult.ExitCode -eq 0) {
            Write-Host ("  WARN: {0} JSON hashes differed, but git diff produced no patch." -f $r.FlverBase) -ForegroundColor Yellow
        }
        else {
            [void]$patchExportFailures.Add([pscustomobject]@{ FlverBase=$r.FlverBase; JsonRel=$r.JsonRel; Error=$diffResult.Error })
        }
    }

    Write-Progress -Activity "Generate FLVER JSON patches" -Completed

    if ($patchExportFailures.Count -gt 0) {
        $failCsv = Join-Path $outRoot "patch_export_failures.csv"
        $patchExportFailures | Export-Csv -LiteralPath $failCsv -NoTypeInformation -Encoding UTF8
        throw "Patch export failed for $($patchExportFailures.Count) FLVER(s). See: $failCsv"
    }

    Export-RowsByPatchDir -Rows @($jsonRows) -FileName "json_patch_manifest.csv" -RelProperty "Rel"
    $jsonManifest = Join-Path $outRoot "json_patch_manifest.csv"

    $patchCount = @($jsonRows | Where-Object { $_.PatchPath }).Count
    Write-Host ""
    Write-Host "================ FINAL SUMMARY ================"
    Write-Host ("FLVER DCX changed pairs: {0}" -f $changedRows.Count)
    Write-Host ("JSON-changing FLVERs:   {0}" -f $jsonChangedRows.Count)
    Write-Host ("Patch files written:   {0}" -f $patchCount)
    $writtenPatchDirs = @($jsonRows | Where-Object { $_.PatchPath } | ForEach-Object { Split-Path -Parent $_.PatchPath } | Sort-Object -Unique)
    Write-Host ("Patch folders written: {0}" -f $writtenPatchDirs.Count)
    $writtenPatchDirs | ForEach-Object { Write-Host ("  {0}" -f $_) }
    Write-Host ("JSON manifest:         {0}" -f $jsonManifest)
    Write-Host ("Elapsed:               {0}" -f $timer.Elapsed.ToString())

    $success = $true
}
finally {
    Write-Host ""
    Write-Host "Stage #6: cleanup..."
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
