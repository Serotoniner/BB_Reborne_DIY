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
   09b_Mapfiles_BBReborne_Param_EqualizeLight.ps1
   
# BB GParam light neutralizer for Noir pass
# Equalizes DiffColor / SpecColor / Hemi RGB to luminance gray.
# Preserves the 4th value exactly as the light intensity/alpha slot.
# Does not modify input folders in place.
   
   .\09b_Mapfiles_BBReborne_Param_EqualizeLight.ps1 `
  -InputPath "C:\Users\Sero\Desktop\BBReborne_params" `
  -OutputPath "C:\Users\Sero\Desktop\BBReborne_params_neutral_white" `
  -ReportPath "C:\Users\Sero\Desktop\BBReborne_params_neutral_white_report.csv"

 
#>


param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"


Add-Type -AssemblyName System.IO.Compression.FileSystem

$TargetParamRegex = [regex]'(?i)(DiffColor|SpecColor|Hemi Color Up|Hemi Color Down)'
$ParamOpenRegex   = [regex]'(?i)<param\b(?<attrs>[^>]*)>'
$ParamCloseRegex  = [regex]'(?i)</param>'
$ValueRegex       = [regex]'(?i)^(?<indent>\s*)<value\s+id="(?<id>[^"]+)">(?<body>[^<]*)</value>(?<trailing>.*)$'
$AttrRegex        = [regex]'(?i)(?<name>name[12])="(?<value>[^"]*)"'

function Format-LightFloat {
    param([double]$Value)

    $text = $Value.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture)

    if ($text -eq "-0") {
        return "0"
    }

    return $text
}

function Get-ParamNamesFromLine {
    param([string]$Line)

    $name1 = ""
    $name2 = ""

    $m = $ParamOpenRegex.Match($Line)
    if (-not $m.Success) {
        return @($name1, $name2)
    }

    $attrs = $m.Groups["attrs"].Value

    foreach ($am in $AttrRegex.Matches($attrs)) {
        $name = $am.Groups["name"].Value.ToLowerInvariant()
        $value = $am.Groups["value"].Value

        if ($name -eq "name1") {
            $name1 = $value
        }
        elseif ($name -eq "name2") {
            $name2 = $value
        }
    }

    return @($name1, $name2)
}

function Test-IsTargetParam {
    param(
        [string]$Name1,
        [string]$Name2
    )

    return $TargetParamRegex.IsMatch("$Name1 $Name2")
}

function Parse-Float4 {
    param([string]$Text)

    $parts = $Text.Trim() -split '\s+'

    if ($parts.Count -ne 4) {
        return $null
    }

    $values = New-Object double[] 4

    for ($i = 0; $i -lt 4; $i++) {
        $ok = [double]::TryParse(
            $parts[$i],
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$values[$i]
        )

        if (-not $ok) {
            return $null
        }
    }

    return $values
}

function Get-NeutralizedFloat4 {
    param([double[]]$Values)

    $r = $Values[0]
    $g = $Values[1]
    $b = $Values[2]
    $intensity = $Values[3]

    # Preserve black disabled lights exactly.
    if ($r -eq 0.0 -and $g -eq 0.0 -and $b -eq 0.0) {
        return $null
    }

    # Leave already-neutral RGB values unchanged.
    if ([Math]::Abs($r - $g) -lt 0.000000001 -and [Math]::Abs($g - $b) -lt 0.000000001) {
        return $null
    }

    $gray = (0.2126 * $r) + (0.7152 * $g) + (0.0722 * $b)

    return @($gray, $gray, $gray, $intensity)
}

function Process-GParamXml {
    param(
        [string]$SourceFile,
        [string]$DestFile,
        [string]$RelPath
    )

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $text = [System.IO.File]::ReadAllText($SourceFile, [System.Text.Encoding]::UTF8)

    # Keep line endings attached to each line.
    $lines = [regex]::Matches($text, ".*(?:\r\n|\n|\r|$)") |
        ForEach-Object { $_.Value } |
        Where-Object { $_ -ne "" }

    $out = [System.Text.StringBuilder]::new()

    $rows = New-Object System.Collections.Generic.List[object]

    $insideParam = $false
    $currentName1 = ""
    $currentName2 = ""
    $currentIsTarget = $false
    $lineNumber = 0

    foreach ($line in $lines) {
        $lineNumber++

        $lineNoNewline = $line -replace "(\r\n|\n|\r)$", ""
        $newline = ""
        if ($line.EndsWith("`r`n")) {
            $newline = "`r`n"
        }
        elseif ($line.EndsWith("`n")) {
            $newline = "`n"
        }
        elseif ($line.EndsWith("`r")) {
            $newline = "`r"
        }

        if ($ParamOpenRegex.IsMatch($lineNoNewline)) {
            $insideParam = $true
            $names = Get-ParamNamesFromLine -Line $lineNoNewline
            $currentName1 = $names[0]
            $currentName2 = $names[1]
            $currentIsTarget = Test-IsTargetParam -Name1 $currentName1 -Name2 $currentName2
        }

        if ($insideParam -and $currentIsTarget) {
            $vm = $ValueRegex.Match($lineNoNewline)

            if ($vm.Success) {
                $oldBody = $vm.Groups["body"].Value
                $oldValues = Parse-Float4 -Text $oldBody

                if ($null -ne $oldValues) {
                    $newValues = Get-NeutralizedFloat4 -Values $oldValues

                    if ($null -ne $newValues) {
                        $newBody = ($newValues | ForEach-Object { Format-LightFloat $_ }) -join " "

                        $newLine =
                            $vm.Groups["indent"].Value +
                            '<value id="' + $vm.Groups["id"].Value + '">' +
                            $newBody +
                            '</value>' +
                            $vm.Groups["trailing"].Value +
                            $newline

                        [void]$out.Append($newLine)

                        $rows.Add([pscustomobject]@{
                            file        = $RelPath
                            line        = $lineNumber
                            param_name1 = $currentName1
                            param_name2 = $currentName2
                            value_id    = $vm.Groups["id"].Value
                            old_value   = $oldBody
                            new_value   = $newBody
                        })

                        continue
                    }
                }
            }
        }

        [void]$out.Append($line)

        if ($insideParam -and $ParamCloseRegex.IsMatch($lineNoNewline)) {
            $insideParam = $false
            $currentName1 = ""
            $currentName2 = ""
            $currentIsTarget = $false
        }
    }

    $destDir = Split-Path -Parent $DestFile
    if (-not [string]::IsNullOrWhiteSpace($destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($DestFile, $out.ToString(), $utf8NoBom)

    return $rows
}

function Copy-AndProcessTree {
    param(
        [string]$SourceRoot,
        [string]$DestRoot
    )

    $reportRows = New-Object System.Collections.Generic.List[object]

    $sourceRootFull = [System.IO.Path]::GetFullPath($SourceRoot)

    Get-ChildItem -LiteralPath $SourceRoot -Recurse -Force | ForEach-Object {
        $src = $_.FullName
        $rel = [System.IO.Path]::GetRelativePath($sourceRootFull, $src)
        $dst = Join-Path $DestRoot $rel

        if ($_.PSIsContainer) {
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
            return
        }

        $nameLower = $_.Name.ToLowerInvariant()
        $isWitchy = ($nameLower -eq "_witchy-bnd4.xml") -or ($nameLower.EndsWith("_witchy-bnd4.xml"))
        $isGparamXml = $nameLower.EndsWith(".gparam.xml")

        if ($isGparamXml -and -not $isWitchy) {
            $relPosix = $rel -replace '\\', '/'
            $rows = Process-GParamXml -SourceFile $src -DestFile $dst -RelPath $relPosix

            foreach ($row in $rows) {
                $reportRows.Add($row)
            }
        }
        else {
            $dstDir = Split-Path -Parent $dst
            if (-not [string]::IsNullOrWhiteSpace($dstDir)) {
                New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
            }

            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }

    return $reportRows
}

function New-ZipFromFolder {
    param(
        [string]$Folder,
        [string]$ZipPath
    )

    $zipDir = Split-Path -Parent $ZipPath
    if (-not [string]::IsNullOrWhiteSpace($zipDir)) {
        New-Item -ItemType Directory -Path $zipDir -Force | Out-Null
    }

    if (Test-Path -LiteralPath $ZipPath) {
        throw "Output zip already exists, refusing to overwrite: $ZipPath"
    }

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $Folder,
        $ZipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )
}

function Write-ReportCsv {
    param(
        [string]$Path,
        [object[]]$Rows
    )

    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $Rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

$inputFull = [System.IO.Path]::GetFullPath($InputPath)
$outputFull = [System.IO.Path]::GetFullPath($OutputPath)

if (-not (Test-Path -LiteralPath $inputFull)) {
    throw "Input not found: $inputFull"
}

if (Test-Path -LiteralPath $outputFull) {
    throw "Output already exists, refusing to overwrite: $outputFull"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    if ([System.IO.Path]::GetExtension($outputFull).ToLowerInvariant() -eq ".zip") {
        $ReportPath = [System.IO.Path]::ChangeExtension($outputFull, ".csv")
    }
    else {
        $ReportPath = Join-Path (Split-Path -Parent $outputFull) ((Split-Path -Leaf $outputFull) + "_report.csv")
    }
}

$reportFull = [System.IO.Path]::GetFullPath($ReportPath)

if (Test-Path -LiteralPath $reportFull) {
    throw "Report already exists, refusing to overwrite: $reportFull"
}

$rows = $null

if ((Get-Item -LiteralPath $inputFull).PSIsContainer) {
    $rows = Copy-AndProcessTree -SourceRoot $inputFull -DestRoot $outputFull
}
else {
    $ext = [System.IO.Path]::GetExtension($inputFull).ToLowerInvariant()

    if ($ext -ne ".zip") {
        throw "Input file must be a .zip or an extracted folder: $inputFull"
    }

    $safeWorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bb_gparam_neutralize_" + [guid]::NewGuid().ToString("N"))
    $extractRoot = Join-Path $safeWorkRoot "input"
    $processedRoot = Join-Path $safeWorkRoot "output"

    try {
        New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $processedRoot -Force | Out-Null

        [System.IO.Compression.ZipFile]::ExtractToDirectory($inputFull, $extractRoot)

        $rows = Copy-AndProcessTree -SourceRoot $extractRoot -DestRoot $processedRoot

        New-ZipFromFolder -Folder $processedRoot -ZipPath $outputFull
    }
    finally {
        if (Test-Path -LiteralPath $safeWorkRoot) {
            Remove-Item -LiteralPath $safeWorkRoot -Recurse -Force
        }
    }
}

Write-ReportCsv -Path $reportFull -Rows $rows

Write-Host ""
Write-Host "Done."
Write-Host ("Changed rows: {0}" -f @($rows).Count)
Write-Host ("Output:       {0}" -f $outputFull)
Write-Host ("Report:       {0}" -f $reportFull)