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
    06b_Mapfiles_BBReborne_Sparam_Development.ps1

    Patch generator for single-file S gparam DCX files such as:
        s22_00_0030.gparam.dcx

    WitchyBND extracts each file as:
        s22_00_0030.gparam.dcx.xml

    Pipeline:
    1) Compare *.gparam.dcx files from NewDir against OldDir by hash.
    2) Copy only changed matching pairs into a safe work folder.
    3) Batch extract copied DCX files with WitchyBND.
    4) Compare the extracted *.gparam.dcx.xml files.
    5) Export portable Git patches.

    Output layout:
        <NewDir>\files
            all_changed_sgparam_xml.patch
            compare_sgparams.csv
            xml_patch_manifest.csv

            _patches
                s22_00_0030.gparam.dcx.xml.patch

        If the source files live under a subfolder, that relative structure is
        preserved before _patches.

    Notes:
    - OldDir and NewDir are never cleaned.
    - Only the safe scratch folder leaf named by -WorkDirName may be deleted/recreated.
    - Patch body lines are never path-rewritten; only git patch header lines are normalized.
#>

[CmdletBinding()]
param(
    # Optional tool/GUI-level inputs. If provided, these resolve the original script inputs below.
    [string]$ToolPathsPs1 = "",
    [string]$GameRoot = "",
    [string]$MapCode = "",
    [string]$MapFolder = "",
    [string]$ParamPrefix = "",

    # Original script inputs. Kept compatible with the known-good standalone call.
    [string]$OldDir = "",
    [string]$NewDir = "",
    [string]$WitchyBND = "",

    [string]$GitExe = "git",

    [int]$WitchyBatchSize = 50,
    [bool]$Recurse = $true,

    # Optional regex matched against relative path or full path.
    [string]$IncludeRegex = "",

    [string]$WorkDirName = "_sgparam_patch_work",
    [string]$OutputSubdir = "files",

    [string]$HashAlgorithm = "SHA256",

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

function ConvertTo-WindowsRelPath([string]$Path) {
    return (($Path -replace '/', '\').TrimStart('\'))
}


function Convert-MapCodeToMapFolder([string]$Code) {
    $clean = ($Code.Trim()).ToLowerInvariant()
    if ($clean -match '^m\d{2}_\d{2}_\d{2}_\d{2}$') { return $clean }
    if ($clean -match '^m\d{2}$') { return ("{0}_00_00_00" -f $clean) }
    if ($clean -match '^s\d{2}_\d{2}_\d{2}_\d{2}$') { return ('m' + $clean.Substring(1)) }
    if ($clean -match '^s\d{2}$') { return ("m{0}_00_00_00" -f $clean.Substring(1)) }
    throw "Unsupported MapCode '$Code'. Expected values like M21 or m21_00_00_00."
}

function Convert-MapCodeToSgparamPrefix([string]$Code) {
    $clean = ($Code.Trim()).ToLowerInvariant()
    if ($clean -match '^[ms](\d{2})(?:_|$)') { return ("s{0}_" -f $Matches[1]) }
    throw "Unsupported MapCode '$Code'. Expected values like M21, S21, or m21_00_00_00."
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

function Get-FileHashText([string]$Path, [string]$Algorithm) {
    return (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLowerInvariant()
}

function Get-SgparamIndex {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [bool]$DoRecurse = $true,
        [string]$RegexText = "",
        [string[]]$ExcludeTopFolders = @()
    )

    $rootFull = [IO.Path]::GetFullPath($Root)
    $items = if ($DoRecurse) {
        Get-ChildItem -LiteralPath $rootFull -File -Filter "*.gparam.dcx" -Recurse -ErrorAction SilentlyContinue
    } else {
        Get-ChildItem -LiteralPath $rootFull -File -Filter "*.gparam.dcx" -ErrorAction SilentlyContinue
    }

    $rx = $null
    if (-not [string]::IsNullOrWhiteSpace($RegexText)) {
        $rx = [regex]::new($RegexText, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    $index = @{}

    foreach ($f in $items) {
        # Exclude generated extracted XMLs just in case a stale extension pattern is weird.
        if ($f.Name -match '(?i)\.xml$') { continue }

        $rel = [IO.Path]::GetRelativePath($rootFull, $f.FullName)
        $relPosix = ConvertTo-PosixPath $rel
        $top = ($relPosix -split '/')[0]

        if ($ExcludeTopFolders -contains $top) { continue }
        if ($null -ne $rx -and -not ($rx.IsMatch($relPosix) -or $rx.IsMatch($f.FullName))) { continue }

        $key = $relPosix.ToLowerInvariant()
        if (-not $index.ContainsKey($key)) {
            $index[$key] = [pscustomobject]@{
                Rel      = $rel
                RelPosix = $relPosix
                FullName = $f.FullName
                Length   = [int64]$f.Length
                Leaf     = $f.Name
                Base     = ($f.Name -replace '(?i)\.gparam\.dcx$', '')
                XmlRel   = $rel + ".xml"
                XmlRelPosix = $relPosix + ".xml"
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
    # XML values may contain Windows/game paths and those must remain untouched.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $reader = [System.IO.StreamReader]::new($InputPatch, [System.Text.Encoding]::UTF8, $true)
    $writer = [System.IO.StreamWriter]::new($OutputPatch, $false, $utf8NoBom)

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

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
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
        $errText = (Get-Content -LiteralPath $tmpErr -Raw -ErrorAction SilentlyContinue)
    }

    return [pscustomobject]@{
        ExitCode = $code
        Status   = "Failed"
        Error    = ("git diff failed with exit code {0}. {1}" -f $code, (($errText -split "`r?`n") | Select-Object -First 1))
    }
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

function Get-OutputPatchDirForXmlRel([string]$XmlRel) {
    $rel = ($XmlRel -replace '\\','/')
    $dir = Split-Path -Parent ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
    if ([string]::IsNullOrWhiteSpace($dir)) {
        return Join-Path $outRoot "_patches"
    }
    return Join-Path (Join-Path $outRoot $dir) "_patches"
}

function Get-PatchLeafForXmlRel([string]$XmlRel) {
    return ((Split-Path -Leaf ($XmlRel -replace '/', [IO.Path]::DirectorySeparatorChar)) + ".patch")
}

function Append-FileToFile {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination
    )

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        Add-Content -LiteralPath $Destination -Value "" -Encoding UTF8
    }

    $appendOut = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $inFile = [System.IO.File]::OpenRead($Source)
        try { $inFile.CopyTo($appendOut) }
        finally { $inFile.Dispose() }
    }
    finally { $appendOut.Dispose() }
}

$timer = [Diagnostics.Stopwatch]::StartNew()
$success = $false


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
if ([string]::IsNullOrWhiteSpace($ParamPrefix) -and -not [string]::IsNullOrWhiteSpace($MapCode)) {
    $ParamPrefix = Convert-MapCodeToSgparamPrefix $MapCode
}
if ([string]::IsNullOrWhiteSpace($ParamPrefix) -and -not [string]::IsNullOrWhiteSpace($MapFolder)) {
    $ParamPrefix = Convert-MapCodeToSgparamPrefix $MapFolder
}

if ([string]::IsNullOrWhiteSpace($GameRoot) -and (Test-Path variable:BBR_GameRoot)) { $GameRoot = $BBR_GameRoot }
if ([string]::IsNullOrWhiteSpace($WitchyBND) -and (Test-Path variable:BBR_WitchyBND_v2_14_4_5)) { $WitchyBND = $BBR_WitchyBND_v2_14_4_5 }
if (($GitExe -eq "git" -or [string]::IsNullOrWhiteSpace($GitExe)) -and (Test-Path variable:BBR_GitExe) -and -not [string]::IsNullOrWhiteSpace($BBR_GitExe)) { $GitExe = $BBR_GitExe }

if ([string]::IsNullOrWhiteSpace($OldDir)) {
    if ([string]::IsNullOrWhiteSpace($GameRoot)) { throw 'GameRoot is required when OldDir is not provided.' }
    $OldDir = Join-Path (Join-Path $GameRoot 'param') 'drawparam'
}

foreach ($required in @(
    [pscustomobject]@{ Name='OldDir'; Value=$OldDir },
    [pscustomobject]@{ Name='NewDir'; Value=$NewDir },
    [pscustomobject]@{ Name='WitchyBND'; Value=$WitchyBND }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
        throw "$($required.Name) is required. Pass it directly or pass ToolPathsPs1/GameRoot/MapCode so it can be resolved."
    }
}

if (-not [string]::IsNullOrWhiteSpace($ParamPrefix) -and [string]::IsNullOrWhiteSpace($IncludeRegex)) {
    $IncludeRegex = ('^' + [regex]::Escape($ParamPrefix))
}

if (-not [string]::IsNullOrWhiteSpace($MapCode)) { Write-Host ("MapCode:     {0}" -f $MapCode) }
if (-not [string]::IsNullOrWhiteSpace($MapFolder)) { Write-Host ("MapFolder:   {0}" -f $MapFolder) }
if (-not [string]::IsNullOrWhiteSpace($ParamPrefix)) { Write-Host ("ParamPrefix: {0}" -f $ParamPrefix) }
Write-Host ("ProjectRoot: {0}" -f $projectRoot)

$oldRoot = [IO.Path]::GetFullPath($OldDir)
$newRoot = [IO.Path]::GetFullPath($NewDir)
$outRoot = Join-Path $newRoot $OutputSubdir

Assert-Dir  $oldRoot "OldDir"
Assert-Dir  $newRoot "NewDir"
Assert-File $WitchyBND "WitchyBND"

$workRoot = Join-Path $newRoot $WorkDirName
$workA = Join-Path $workRoot "a"
$workB = Join-Path $workRoot "b"

try {
    if (-not $DryRun) {
        Ensure-Dir $outRoot
        Reset-ScratchFolder -Path $workRoot -ExpectedLeaf $WorkDirName
        Ensure-Dir $workA
        Ensure-Dir $workB
    }

    Write-Host ""
    Write-Host "Stage #0: discovering and hashing S gparam DCX files..."

    $excludeTop = @($OutputSubdir, $WorkDirName, "_patches")
    $oldIndex = Get-SgparamIndex -Root $oldRoot -DoRecurse $Recurse -RegexText $IncludeRegex -ExcludeTopFolders $excludeTop
    $newIndex = Get-SgparamIndex -Root $newRoot -DoRecurse $Recurse -RegexText $IncludeRegex -ExcludeTopFolders $excludeTop
    $allKeys = @($oldIndex.Keys + $newIndex.Keys | Sort-Object -Unique)

    if ($allKeys.Count -eq 0) {
        Write-Host "No *.gparam.dcx files found after filters."
        $success = $true
        return
    }

    $compareRows = [System.Collections.Generic.List[object]]::new()
    $n = 0

    foreach ($key in $allKeys) {
        $n++
        Write-Progress -Activity "Hash S gparam DCX files" -Status ("{0}/{1}" -f $n, $allKeys.Count) -PercentComplete ([int](100.0 * $n / $allKeys.Count))

        $oldFile = if ($oldIndex.ContainsKey($key)) { $oldIndex[$key] } else { $null }
        $newFile = if ($newIndex.ContainsKey($key)) { $newIndex[$key] } else { $null }

        $rel = if ($null -ne $newFile) { $newFile.Rel } else { $oldFile.Rel }
        $relPosix = ConvertTo-PosixPath $rel
        $oldPath = if ($null -ne $oldFile) { $oldFile.FullName } else { "" }
        $newPath = if ($null -ne $newFile) { $newFile.FullName } else { "" }
        $oldHash = if ($oldPath) { Get-FileHashText -Path $oldPath -Algorithm $HashAlgorithm } else { "" }
        $newHash = if ($newPath) { Get-FileHashText -Path $newPath -Algorithm $HashAlgorithm } else { "" }

        $status = "Same"
        if (-not $oldPath -and $newPath) { $status = "Added" }
        elseif ($oldPath -and -not $newPath) { $status = "Removed" }
        elseif ($oldHash -ne $newHash) { $status = "Changed" }

        [void]$compareRows.Add([pscustomobject]@{
            Base       = ($rel -replace '(?i)\.gparam\.dcx$', '')
            Rel        = $rel
            RelPosix   = $relPosix
            XmlRel     = $rel + ".xml"
            XmlRelPosix = $relPosix + ".xml"
            Status     = $status
            OldPath    = $oldPath
            NewPath    = $newPath
            OldHash    = $oldHash
            NewHash    = $newHash
        })
    }
    Write-Progress -Activity "Hash S gparam DCX files" -Completed

    if (-not $DryRun) {
        $compareRows | Export-Csv -LiteralPath (Join-Path $outRoot "compare_sgparams.csv") -NoTypeInformation -Encoding UTF8
    }

    $changedRows = @($compareRows | Where-Object { $_.Status -eq "Changed" } | Sort-Object Rel)
    $nonPatchable = @($compareRows | Where-Object { $_.Status -in @("Added","Removed") })

    Write-Host ("S gparam compare done. Same={0} Changed={1} Added={2} Removed={3}" -f `
        @($compareRows | Where-Object Status -eq "Same").Count,
        $changedRows.Count,
        @($compareRows | Where-Object Status -eq "Added").Count,
        @($compareRows | Where-Object Status -eq "Removed").Count)

    if ($nonPatchable.Count -gt 0) {
        Write-Host ("  Note: Added/Removed files are listed in compare_sgparams.csv but skipped for patch export: {0}" -f $nonPatchable.Count) -ForegroundColor Yellow
    }

    if ($changedRows.Count -eq 0) {
        Write-Host "No changed matching S gparam DCX files. Nothing to decompress or patch."
        $success = $true
        return
    }

    if ($DryRun) {
        Write-Host "DRYRUN: stopping after hash compare."
        $success = $true
        return
    }

    Write-Host ""
    Write-Host ("Stage #1: copying {0} changed S gparam DCX pairs into work..." -f $changedRows.Count)

    foreach ($r in $changedRows) {
        $oldCopy = Join-Path $workA $r.Rel
        $newCopy = Join-Path $workB $r.Rel
        Ensure-Dir (Split-Path -Parent $oldCopy)
        Ensure-Dir (Split-Path -Parent $newCopy)
        Copy-Item -LiteralPath $r.OldPath -Destination $oldCopy -Force
        Copy-Item -LiteralPath $r.NewPath -Destination $newCopy -Force

        $r | Add-Member -NotePropertyName OldDcx -NotePropertyValue $oldCopy -Force
        $r | Add-Member -NotePropertyName NewDcx -NotePropertyValue $newCopy -Force
        $r | Add-Member -NotePropertyName OldXml -NotePropertyValue ($oldCopy + ".xml") -Force
        $r | Add-Member -NotePropertyName NewXml -NotePropertyValue ($newCopy + ".xml") -Force
        $r | Add-Member -NotePropertyName OldXmlHash -NotePropertyValue "" -Force
        $r | Add-Member -NotePropertyName NewXmlHash -NotePropertyValue "" -Force
        $r | Add-Member -NotePropertyName XmlStatus -NotePropertyValue "" -Force
        $r | Add-Member -NotePropertyName PatchPath -NotePropertyValue "" -Force
    }

    Write-Host ""
    Write-Host ("Stage #2: extracting S gparam DCX with WitchyBND, batchSize={0}..." -f $WitchyBatchSize)

    $dcxToExtract = @(
        @($changedRows | ForEach-Object { $_.OldDcx }) +
        @($changedRows | ForEach-Object { $_.NewDcx })
    )
    Invoke-WitchyBatchSimple -Exe $WitchyBND -Paths $dcxToExtract -BatchSize $WitchyBatchSize -Label "WitchyBND extract"

    $missingXml = @()
    foreach ($r in $changedRows) {
        if (-not (Test-Path -LiteralPath $r.OldXml -PathType Leaf)) { $missingXml += [pscustomobject]@{ Side="Old"; Rel=$r.Rel; MissingXml=$r.OldXml } }
        if (-not (Test-Path -LiteralPath $r.NewXml -PathType Leaf)) { $missingXml += [pscustomobject]@{ Side="New"; Rel=$r.Rel; MissingXml=$r.NewXml } }
    }

    if ($missingXml.Count -gt 0) {
        $missingCsv = Join-Path $workRoot "missing_sgparam_xml_after_witchy.csv"
        $missingXml | Export-Csv -LiteralPath $missingCsv -NoTypeInformation -Encoding UTF8
        throw "Could not locate extracted S gparam XML for $($missingXml.Count) side(s). See: $missingCsv"
    }

    Write-Host ""
    Write-Host "Stage #3: comparing extracted XML files..."

    foreach ($r in $changedRows) {
        $oldXmlHash = Get-FileHashText -Path $r.OldXml -Algorithm $HashAlgorithm
        $newXmlHash = Get-FileHashText -Path $r.NewXml -Algorithm $HashAlgorithm
        $r.OldXmlHash = $oldXmlHash
        $r.NewXmlHash = $newXmlHash
        $r.XmlStatus = if ($oldXmlHash -eq $newXmlHash) { "Same" } else { "Changed" }
    }

    $xmlChangedRows = @($changedRows | Where-Object { $_.XmlStatus -eq "Changed" } | Sort-Object XmlRel)
    $sameXmlRows = @($changedRows | Where-Object { $_.XmlStatus -eq "Same" })

    Write-Host ("XML compare done. Same={0} Changed={1}" -f $sameXmlRows.Count, $xmlChangedRows.Count)

    if ($xmlChangedRows.Count -eq 0) {
        $changedRows | Export-Csv -LiteralPath (Join-Path $outRoot "xml_patch_manifest.csv") -NoTypeInformation -Encoding UTF8
        Write-Host "All changed DCX files produced identical XML content. No XML patches generated."
        $success = $true
        return
    }

    Write-Host ""
    Write-Host ("Stage #4: exporting Git patches for {0} XML file(s)..." -f $xmlChangedRows.Count)

    $allPatch = Join-Path $outRoot "all_changed_sgparam_xml.patch"
    Remove-Item -LiteralPath $allPatch -Force -ErrorAction SilentlyContinue

    $patchExportFailures = [System.Collections.Generic.List[object]]::new()
    $patchN = 0

    foreach ($r in $xmlChangedRows) {
        $patchN++
        Write-Progress -Activity "Generate S gparam XML patches" -Status ("{0}/{1}: {2}" -f $patchN, $xmlChangedRows.Count, $r.XmlRelPosix) -PercentComplete ([int](100.0 * $patchN / $xmlChangedRows.Count))

        $patchDir = Get-OutputPatchDirForXmlRel $r.XmlRel
        $patchPath = Join-Path $patchDir (Get-PatchLeafForXmlRel $r.XmlRel)
        Ensure-Dir $patchDir
        Remove-Item -LiteralPath $patchPath -Force -ErrorAction SilentlyContinue

        $oldRelToWork = [IO.Path]::GetRelativePath($workRoot, $r.OldXml)
        $newRelToWork = [IO.Path]::GetRelativePath($workRoot, $r.NewXml)

        $diffResult = Invoke-GitDiffRelativeToPatchFile `
            -GitExe $GitExe `
            -WorkDir $workRoot `
            -OldRelToWork $oldRelToWork `
            -NewRelToWork $newRelToWork `
            -XmlRelPosix $r.XmlRelPosix `
            -PatchPath $patchPath

        if ([int]$diffResult.ExitCode -eq 1) {
            $r.PatchPath = $patchPath
            Append-FileToFile -Source $patchPath -Destination $allPatch
        }
        elseif ([int]$diffResult.ExitCode -eq 0) {
            Write-Host ("  WARN: {0} XML hashes differed, but git diff produced no patch." -f $r.XmlRelPosix) -ForegroundColor Yellow
        }
        else {
            [void]$patchExportFailures.Add([pscustomobject]@{
                Rel = $r.Rel
                XmlRel = $r.XmlRel
                Error = $diffResult.Error
            })
        }
    }
    Write-Progress -Activity "Generate S gparam XML patches" -Completed

    if ($patchExportFailures.Count -gt 0) {
        $failCsv = Join-Path $outRoot "patch_export_failures.csv"
        $patchExportFailures | Export-Csv -LiteralPath $failCsv -NoTypeInformation -Encoding UTF8
        throw "Patch export failed for $($patchExportFailures.Count) XML file(s). See: $failCsv"
    }

    $changedRows | Export-Csv -LiteralPath (Join-Path $outRoot "xml_patch_manifest.csv") -NoTypeInformation -Encoding UTF8

    $patchCount = @($changedRows | Where-Object { $_.PatchPath }).Count

    Write-Host ""
    Write-Host "================ FINAL SUMMARY ================"
    Write-Host ("Changed DCX files:      {0}" -f $changedRows.Count)
    Write-Host ("XML-changing files:     {0}" -f $xmlChangedRows.Count)
    Write-Host ("Patch files written:    {0}" -f $patchCount)
    Write-Host ("Output patch root:      {0}" -f $outRoot)
    Write-Host ("XML manifest:           {0}" -f (Join-Path $outRoot "xml_patch_manifest.csv"))
    Write-Host ("Elapsed:                {0}" -f $timer.Elapsed.ToString())

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
