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
    02b_Mapfiles_BBReborne_Map_Development.ps1

    MSB JSON patch generator for the BBReborne map tab.

    Tool-level additions:
    - Can resolve OldDir from -ToolPathsPs1/-GameRoot/-MapCode.
    - Uses WitchyBND v2.14.4.5 and BBR_MsbbJsonToolExe from the paths file when not passed directly.
    - When MapCode/MapFolder is provided and IncludeRegex is empty, filters to that one map.

    Pipeline:
    1) Compare *.msb.dcx files from NewDir against OldDir by hash.
    2) Copy only changed matching pairs into a safe work folder.
    3) Batch decompress copied DCX files with WitchyBND:
          m21_00_00_00.msb.dcx -> m21_00_00_00.msb
    4) Dump MSB -> JSON with MsbJsonTool.
    5) Compare JSON hashes.
    6) Export portable Git patches only when the dumped JSON differs.
    7) Cleanup the safe work folder unless -KeepWork is used.

    Output layout by default:
        <NewDir>\_msb_patches
            all_changed_msb_json.patch
            compare_msbs.csv
            dump_manifest.csv
            json_patch_manifest.csv
            files\m21_00_00_00.patch

        <NewDir>\_msb_patch_work
            a\...   # old/original copied DCX, extracted MSB, JSON
            b\...   # new/changed copied DCX, extracted MSB, JSON
            logs\...

    Important:
    - OldDir and NewDir are never cleaned.
    - Only <NewDir>\_msb_patch_work is deleted/recreated.
    - A changed packed .msb.dcx is not enough to make a patch; the dumped MSB JSON must differ.
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

    [Alias("MsbTool")]
    [string]$MsbJsonToolExe = "",

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
    [int]$DumpThrottle = [Math]::Max(1, [Math]::Min(4, [int]([Environment]::ProcessorCount / 4))),

    [string]$PatchDirName = "_msb_patches",
    [string]$WorkDirName  = "_msb_patch_work",

    [string]$DumpCommand = "dump"
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

function Get-MsbBaseFromLeaf([string]$Leaf) {
    if ([string]::IsNullOrWhiteSpace($Leaf)) { return "" }
    if ($Leaf.EndsWith('.dcx', [StringComparison]::OrdinalIgnoreCase)) {
        $Leaf = $Leaf.Substring(0, $Leaf.Length - 4)
    }
    if ($Leaf.EndsWith('.msb', [StringComparison]::OrdinalIgnoreCase)) {
        $Leaf = $Leaf.Substring(0, $Leaf.Length - 4)
    }
    if ($Leaf.EndsWith('.msb.json', [StringComparison]::OrdinalIgnoreCase)) {
        $Leaf = $Leaf.Substring(0, $Leaf.Length - 9)
    }
    return $Leaf
}

function Get-MsbJsonRelFromDcxRel([string]$Rel) {
    return (($Rel -replace '\.dcx$', '') + '.json')
}

function Get-PatchLeafForJsonRel([string]$JsonRel) {
    $leaf = ($JsonRel -replace '[\\/]+', '__')
    $leaf = ($leaf -replace '\.msb\.json$', '.patch')
    if (-not $leaf.EndsWith('.patch', [StringComparison]::OrdinalIgnoreCase)) { $leaf = $leaf + '.patch' }
    return $leaf
}

function Get-MsbIndex([string]$Root, [bool]$DoRecurse, [string]$RegexText, [string[]]$ExcludeTopFolders) {
    $gciParams = @{
        LiteralPath = $Root
        Filter      = "*.msb.dcx"
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

# MSB development patch generation uses WitchyBND v2.14.4.5.
if ([string]::IsNullOrWhiteSpace($WitchyBND) -and (Test-Path variable:BBR_WitchyBND_v2_14_4_5)) { $WitchyBND = $BBR_WitchyBND_v2_14_4_5 }
if ([string]::IsNullOrWhiteSpace($MsbJsonToolExe) -and (Test-Path variable:BBR_MsbbJsonToolExe)) { $MsbJsonToolExe = $BBR_MsbbJsonToolExe }
if (($GitExe -eq "git" -or [string]::IsNullOrWhiteSpace($GitExe)) -and (Test-Path variable:BBR_GitExe) -and -not [string]::IsNullOrWhiteSpace($BBR_GitExe)) { $GitExe = $BBR_GitExe }

if (-not [string]::IsNullOrWhiteSpace($MapFolder)) {
    if ([string]::IsNullOrWhiteSpace($OldDir)) {
        if ([string]::IsNullOrWhiteSpace($GameRoot)) { throw 'GameRoot is required when OldDir is not provided.' }
        $OldDir = Join-Path (Join-Path $GameRoot 'map') 'mapstudio'
    }
    if ([string]::IsNullOrWhiteSpace($IncludeRegex)) {
        $IncludeRegex = ('^{0}\.msb\.dcx$' -f [regex]::Escape($MapFolder))
    }
}

foreach ($required in @(
    [pscustomobject]@{ Name='OldDir'; Value=$OldDir },
    [pscustomobject]@{ Name='NewDir'; Value=$NewDir },
    [pscustomobject]@{ Name='WitchyBND'; Value=$WitchyBND },
    [pscustomobject]@{ Name='MsbJsonToolExe'; Value=$MsbJsonToolExe }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
        throw "$($required.Name) is required. Pass it directly or pass ToolPathsPs1/GameRoot/MapCode where applicable."
    }
}

if (-not [string]::IsNullOrWhiteSpace($MapCode)) { Write-Host ("MapCode:     {0}" -f $MapCode) }
if (-not [string]::IsNullOrWhiteSpace($MapFolder)) { Write-Host ("MapFolder:   {0}" -f $MapFolder) }
if (-not [string]::IsNullOrWhiteSpace($IncludeRegex)) { Write-Host ("IncludeRegex:{0}" -f $IncludeRegex) }
Write-Host ("ProjectRoot: {0}" -f $projectRoot)

$timer = [Diagnostics.Stopwatch]::StartNew()
$success = $false

$oldRoot = [IO.Path]::GetFullPath($OldDir)
$newRoot = [IO.Path]::GetFullPath($NewDir)
Assert-Dir  $oldRoot "OldDir"
Assert-Dir  $newRoot "NewDir"
Assert-File $WitchyBND "WitchyBND"
Assert-File $MsbJsonToolExe "MsbJsonToolExe"

$patchDir = Join-Path $newRoot $PatchDirName
$filePatchDir = Join-Path $patchDir "files"
$workRoot = Join-Path $newRoot $WorkDirName
$workA = Join-Path $workRoot "a"
$workB = Join-Path $workRoot "b"
$logsDir = Join-Path $workRoot "logs"

try {
    if (-not $DryRun) {
        Ensure-Dir $patchDir
        Ensure-Dir $filePatchDir
        Reset-ScratchFolder -Path $workRoot -ExpectedLeaf $WorkDirName
        foreach ($d in @($workA,$workB,$logsDir)) { Ensure-Dir $d }
    }

    # ------------------------------------------------------------
    # Stage #0: discover, match, hash
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Stage #0: discovering and hashing MSB DCX files..."

    $excludeTop = @($PatchDirName, $WorkDirName)
    $oldIndex = Get-MsbIndex -Root $oldRoot -DoRecurse ([bool]$Recurse) -RegexText $IncludeRegex -ExcludeTopFolders $excludeTop
    $newIndex = Get-MsbIndex -Root $newRoot -DoRecurse ([bool]$Recurse) -RegexText $IncludeRegex -ExcludeTopFolders $excludeTop
    $allKeys = @($oldIndex.Keys + $newIndex.Keys | Sort-Object -Unique)

    if ($StartAt -gt 0) {
        if ($StartAt -ge $allKeys.Count) { throw "-StartAt $StartAt >= MSB count $($allKeys.Count)" }
        $allKeys = @($allKeys[$StartAt..($allKeys.Count - 1)])
    }
    if ($MaxFiles -gt 0 -and $allKeys.Count -gt $MaxFiles) {
        $allKeys = @($allKeys | Select-Object -First $MaxFiles)
    }

    if ($allKeys.Count -eq 0) {
        Write-Host "No *.msb.dcx files found after filters."
        $success = $true
        return
    }

    $compareRows = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($key in $allKeys) {
        $n++
        if (($n % 25) -eq 0 -or $n -eq $allKeys.Count) {
            Write-Progress -Activity "Hash MSB DCX files" -Status ("{0}/{1}" -f $n, $allKeys.Count) -PercentComplete ([int](100.0 * $n / $allKeys.Count))
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
            MsbBase = Get-MsbBaseFromLeaf (Split-Path -Leaf $rel)
            Rel     = $rel
            JsonRel = Get-MsbJsonRelFromDcxRel $rel
            Status  = $status
            OldPath = $oldPath
            NewPath = $newPath
            OldSize = $oldSize
            NewSize = $newSize
            OldHash = $oldHash
            NewHash = $newHash
        })
    }
    Write-Progress -Activity "Hash MSB DCX files" -Completed

    $compareCsv = Join-Path $patchDir "compare_msbs.csv"
    if (-not $DryRun) { $compareRows | Sort-Object Rel | Export-Csv -LiteralPath $compareCsv -NoTypeInformation -Encoding UTF8 }

    $sameCount    = @($compareRows | Where-Object Status -eq "Same").Count
    $changedCount = @($compareRows | Where-Object Status -eq "Changed").Count
    $addedCount   = @($compareRows | Where-Object Status -eq "Added").Count
    $removedCount = @($compareRows | Where-Object Status -eq "Removed").Count
    Write-Host ("MSB DCX compare done. Same={0} Changed={1} Added={2} Removed={3}" -f $sameCount, $changedCount, $addedCount, $removedCount)
    if (-not $DryRun) { Write-Host "Compare CSV: $compareCsv" }

    $changedRows = @($compareRows | Where-Object { $_.Status -eq "Changed" } | Sort-Object Rel)
    $nonPatchable = @($compareRows | Where-Object { $_.Status -in @("Added","Removed") })
    if ($nonPatchable.Count -gt 0) {
        Write-Host ("  Note: Added/Removed MSBs are listed in compare_msbs.csv but skipped for JSON patch export: {0}" -f $nonPatchable.Count) -ForegroundColor Yellow
    }

    if ($changedRows.Count -eq 0) {
        Write-Host "No changed matching MSB DCX files. Nothing to decompress or patch."
        $success = $true
        return
    }

    if ($DryRun) {
        Write-Host "DRYRUN: stopping after hash compare."
        $success = $true
        return
    }

    # ------------------------------------------------------------
    # Stage #1: copy changed MSB DCX files into work/a and work/b
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #1: copying {0} changed MSB DCX pairs into work..." -f $changedRows.Count)

    $workRows = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $changedRows) {
        $oldCopy = Join-Path $workA $r.Rel
        $newCopy = Join-Path $workB $r.Rel
        Ensure-Dir (Split-Path -Parent $oldCopy)
        Ensure-Dir (Split-Path -Parent $newCopy)
        Copy-Item -LiteralPath $r.OldPath -Destination $oldCopy -Force
        Copy-Item -LiteralPath $r.NewPath -Destination $newCopy -Force

        [void]$workRows.Add([pscustomobject]@{
            MsbBase = $r.MsbBase
            Rel     = $r.Rel
            JsonRel = $r.JsonRel
            Status  = $r.Status
            OldDcx  = $oldCopy
            NewDcx  = $newCopy
            OldMsb  = ($oldCopy -replace '\.dcx$', '')
            NewMsb  = ($newCopy -replace '\.dcx$', '')
            OldJson = Join-Path $workA $r.JsonRel
            NewJson = Join-Path $workB $r.JsonRel
        })
    }

    # ------------------------------------------------------------
    # Stage #2: decompress with WitchyBND
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #2: decompressing MSB DCX with WitchyBND, batchSize={0}..." -f $WitchyBatchSize)

    $dcxToDecompress = @(
        @($workRows | ForEach-Object { $_.OldDcx }) +
        @($workRows | ForEach-Object { $_.NewDcx })
    )
    Invoke-WitchyBatchSimple -Exe $WitchyBND -Paths $dcxToDecompress -BatchSize $WitchyBatchSize -Label "WitchyBND decompress"

    $missingMsb = @($workRows | Where-Object { -not (Test-Path -LiteralPath $_.OldMsb -PathType Leaf) -or -not (Test-Path -LiteralPath $_.NewMsb -PathType Leaf) })
    if ($missingMsb.Count -gt 0) {
        $missingCsv = Join-Path $patchDir "missing_msb_after_witchy.csv"
        $missingMsb | Export-Csv -LiteralPath $missingCsv -NoTypeInformation -Encoding UTF8
        throw "Could not locate decompressed MSB for $($missingMsb.Count) file(s). See: $missingCsv"
    }

    # ------------------------------------------------------------
    # Stage #3: dump MSB JSON
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #3: dumping MSB JSON, throttle={0}..." -f $DumpThrottle)
    Write-Host "  Using captured native process output so parser exceptions are logged per file instead of aborting the whole run."

    $dumpItems = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $workRows) {
        [void]$dumpItems.Add([pscustomobject]@{ MsbBase=$r.MsbBase; Rel=$r.Rel; JsonRel=$r.JsonRel; Side="old"; Msb=$r.OldMsb; Json=$r.OldJson })
        [void]$dumpItems.Add([pscustomobject]@{ MsbBase=$r.MsbBase; Rel=$r.Rel; JsonRel=$r.JsonRel; Side="new"; Msb=$r.NewMsb; Json=$r.NewJson })
    }

    # Keep this stage deliberately simple and robust. MSB files are few, and using a captured
    # ProcessStartInfo avoids PowerShell turning native stderr into a terminating error.
    $dumpResultsList = [System.Collections.Generic.List[object]]::new()
    $dumpN = 0
    foreach ($it in $dumpItems) {
        $dumpN++
        Write-Progress -Activity "Dump MSB JSON" -Status ("{0}/{1}: {2} [{3}]" -f $dumpN, $dumpItems.Count, $it.Rel, $it.Side) -PercentComplete ([int](100.0 * $dumpN / $dumpItems.Count))

        $ok = $false
        $hash = ""
        $err = ""
        $stdout = ""
        $stderr = ""

        try {
            if (-not (Test-Path -LiteralPath $it.Msb -PathType Leaf)) { throw "Missing MSB: $($it.Msb)" }
            $jsonDir = Split-Path -Parent $it.Json
            Ensure-Dir $jsonDir

            $res = Invoke-NativeCapture -Exe $MsbJsonToolExe -Arguments @($DumpCommand, $it.Msb, $it.Json)
            $stdout = $res.StdOut
            $stderr = $res.StdErr

            if ($res.ExitCode -ne 0) {
                $detail = ($stderr + "`n" + $stdout).Trim()
                if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "MsbJsonTool produced no stderr/stdout." }
                throw "MsbJsonTool $DumpCommand failed with exit code $($res.ExitCode): $detail"
            }
            if (-not (Test-Path -LiteralPath $it.Json -PathType Leaf)) { throw "JSON not produced: $($it.Json)" }

            $hash = (Get-FileHash -LiteralPath $it.Json -Algorithm SHA256).Hash.ToLowerInvariant()
            $ok = $true
        }
        catch {
            $err = $_.Exception.Message
        }

        [void]$dumpResultsList.Add([pscustomobject]@{
            MsbBase  = $it.MsbBase
            Rel      = $it.Rel
            JsonRel  = $it.JsonRel
            Side     = $it.Side
            Msb      = $it.Msb
            Json     = $it.Json
            Ok       = [bool]$ok
            JsonHash = $hash
            Error    = $err
            StdErr   = $stderr
            StdOut   = $stdout
        })
    }
    Write-Progress -Activity "Dump MSB JSON" -Completed

    $dumpResults = @($dumpResultsList)
    $dumpManifest = Join-Path $patchDir "dump_manifest.csv"
    $dumpResults | Sort-Object Rel, Side | Export-Csv -LiteralPath $dumpManifest -NoTypeInformation -Encoding UTF8
    $dumpFailures = @($dumpResults | Where-Object { -not $_.Ok })

    if ($dumpFailures.Count -gt 0) {
        Write-Host ("Stage #3 completed with dump failures: {0}. See: {1}" -f $dumpFailures.Count, $dumpManifest) -ForegroundColor Yellow
        $dumpFailures | Select-Object -First 20 | ForEach-Object {
            Write-Host ("  FAIL: {0} [{1}]" -f $_.Rel, $_.Side) -ForegroundColor Red
            Write-Host ("        {0}" -f $_.Msb) -ForegroundColor DarkGray
            Write-Host ("        {0}" -f (($_.Error -split "`r?`n") | Select-Object -First 1)) -ForegroundColor Red
        }
        if ($FailOnDumpFailure) { throw "MSB JSON dump failed for $($dumpFailures.Count) file(s). See: $dumpManifest" }
        $KeepWork = $true
        Write-Host "  Continuing with MSBs whose old and new JSON both dumped successfully. Work folder will be kept." -ForegroundColor Yellow
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
            MsbBase     = $r.MsbBase
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
    $jsonManifestPre = Join-Path $patchDir "json_patch_manifest.csv"
    if ($jsonChangedRows.Count -eq 0) {
        $jsonRows | Sort-Object JsonRel | Export-Csv -LiteralPath $jsonManifestPre -NoTypeInformation -Encoding UTF8
        if ($dumpFailures.Count -gt 0) {
            Write-Host "No patches were generated from successful dumps; one or more MSBs failed to dump and are marked DumpFailed." -ForegroundColor Yellow
        } else {
            Write-Host "All changed MSB DCX files produced identical MSB JSON. No patch files were generated."
        }
        Write-Host "JSON manifest: $jsonManifestPre"
        $success = $true
        return
    }
    Write-Host ("  JSON-changing MSBs: {0}" -f $jsonChangedRows.Count)

    # ------------------------------------------------------------
    # Stage #5: export portable Git patches
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host ("Stage #5: exporting Git patches for {0} JSON-changing MSB(s)..." -f $jsonChangedRows.Count)

    $allPatch = Join-Path $patchDir "all_changed_msb_json.patch"
    if (Test-Path -LiteralPath $allPatch -PathType Leaf) { Remove-Item -LiteralPath $allPatch -Force }

    $patchExportFailures = [System.Collections.Generic.List[object]]::new()

    foreach ($r in $jsonChangedRows) {
        $patchPath = Join-Path $filePatchDir (Get-PatchLeafForJsonRel $r.JsonRel)
        if (Test-Path -LiteralPath $patchPath -PathType Leaf) { Remove-Item -LiteralPath $patchPath -Force }

        if (-not (Test-Path -LiteralPath $r.OldJson -PathType Leaf) -or -not (Test-Path -LiteralPath $r.NewJson -PathType Leaf)) {
            [void]$patchExportFailures.Add([pscustomobject]@{ MsbBase=$r.MsbBase; JsonRel=$r.JsonRel; Error="Missing old/new JSON file for direct diff" })
            continue
        }

        $oldRelToWork = [IO.Path]::GetRelativePath($workRoot, $r.OldJson) -replace '\\','/'
        $newRelToWork = [IO.Path]::GetRelativePath($workRoot, $r.NewJson) -replace '\\','/'

        Push-Location -LiteralPath $workRoot
        try {
            $diffText = @(& $GitExe `
                -c core.autocrlf=false `
                -c core.safecrlf=false `
                diff --no-index --binary --full-index --src-prefix=a/ --dst-prefix=b/ -- `
                $oldRelToWork $newRelToWork 2>&1)
            $code = $LASTEXITCODE
        }
        finally { Pop-Location }

        if ($code -eq 1) {
            $diffText | Set-Content -LiteralPath $patchPath -Encoding UTF8
            $r.PatchPath = $patchPath
            if (Test-Path -LiteralPath $allPatch -PathType Leaf) { Add-Content -LiteralPath $allPatch -Value "" -Encoding UTF8 }
            Add-Content -LiteralPath $allPatch -Value $diffText -Encoding UTF8
        }
        elseif ($code -eq 0) {
            Write-Host ("  WARN: {0} JSON hashes differed, but git diff produced no patch." -f $r.MsbBase) -ForegroundColor Yellow
        }
        else {
            $first = ($diffText | Select-Object -First 1)
            [void]$patchExportFailures.Add([pscustomobject]@{ MsbBase=$r.MsbBase; JsonRel=$r.JsonRel; Error="git diff failed with exit code $code. $first" })
        }
    }

    if ($patchExportFailures.Count -gt 0) {
        $failCsv = Join-Path $patchDir "patch_export_failures.csv"
        $patchExportFailures | Export-Csv -LiteralPath $failCsv -NoTypeInformation -Encoding UTF8
        throw "Patch export failed for $($patchExportFailures.Count) MSB(s). See: $failCsv"
    }

    if (-not (Test-Path -LiteralPath $allPatch -PathType Leaf)) { "" | Set-Content -LiteralPath $allPatch -Encoding UTF8 }

    $jsonManifest = Join-Path $patchDir "json_patch_manifest.csv"
    $jsonRows | Sort-Object JsonRel | Export-Csv -LiteralPath $jsonManifest -NoTypeInformation -Encoding UTF8

    $patchCount = @($jsonRows | Where-Object { $_.PatchPath }).Count
    Write-Host ""
    Write-Host "================ FINAL SUMMARY ================"
    Write-Host ("MSB DCX changed pairs: {0}" -f $changedRows.Count)
    Write-Host ("JSON-changing MSBs:   {0}" -f $jsonChangedRows.Count)
    Write-Host ("Patch files written:   {0}" -f $patchCount)
    Write-Host ("Patch folder:          {0}" -f $patchDir)
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
