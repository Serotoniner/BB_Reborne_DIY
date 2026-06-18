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
    BBReborneDIYTool.ps1

    WPF launcher and setup tool for the BB Reborne DIY workflow.

    Current scope:
    - Step 1: Setup tab.
      - Requires the user to set a game folder ending in dvdroot_ps4 before saving paths.
      - Lets the user select or create the modded output folder.
      - Checks whether PowerShell 7 / pwsh.exe is available.
      - Checks whether .NET 9 is available.
      - Installs or updates PowerShell 7 through winget when requested.
      - Installs the .NET 9 SDK through winget when requested.
      - Installs ImageMagick Q16-HDRI through winget when requested.
      - Downloads / extracts the three WitchyBND versions currently needed:
          - v3.0.0.1
          - v2.14.4.5
          - v2.4.0.1
      - Downloads texconv.exe directly from the latest Microsoft DirectXTex release endpoint.
      - Downloads / extracts the portable Real-ESRGAN ncnn Vulkan Windows package.
      - Replaces Real-ESRGAN's default models with BBReborneUpscaler.bin / BBReborneUpscaler.param from .\AI_upscaler.
      - Detects executable paths and saves them to JSON + PowerShell variables.
      - Probes CPU thread count, RAM, VRAM, and output drive free space to show a readiness/status summary.
      - Writes WitchyBND setup defaults and relies on the Global runner to rewrite version-specific WitchyBND settings before each script step.
      - Provides a launcher .cmd helper so the WPF tool can be started without typing the full PowerShell command.

    - Step 2: Mod files tab.
      - Shows the global patch row and the per-map build rows.
      - Runs the Global patch sequence through Scripts\Global\00_Run_Global_BBReborne_All.ps1.
      - Supports Global steps currently handled by the runner:
          - SFX remove player light
          - SFX M25
          - Menu fe
          - Gparam GameParam
          - Obj from diffs
          - Param DefaultDrawparam
      - Lets the user choose which map rows and which per-map steps should run.
      - Provides TOTAL-row checkboxes that check/uncheck all enabled rows at once for each map step.
      - Provides a No texture upscale toggle that passes -NoUpscale to the texture step, keeping treatments while targeting 1x textures.

    - Step 3: Param tweaks tab.
      - Scans gparam XML patch files under .\Diffs for the five Yebis params.
      - Shows map/time rows with spoiler-safe raw codes or friendly labels.
      - Provides nested editable columns for Exposure, Gamma, ColorS, MiddleGray, and LutSourceId.
      - Each nested param column shows User, Modded, and Vanilla values, with header buttons for User/Modded/Vanilla mass-copy actions.
      - Generates a full custom copy of the gparam patch diffs under Output\BBReborne_param_custom\_work, changing only editable +value lines from the User boxes.
      - Can run the map Param patch step against that custom diff copy, writing patched files under Output\BBReborne_param_custom.
      - Saves and reloads the last User values from Tools\BBReborneDIYTool.param_tweaks.user_values.json.
      - Removes the custom _work directory after successful Param patching.
      - Shows estimated time, elapsed time, completion status, and output folder hints.
      - Can hide map names by default to avoid spoilers.
      - Warns the user not to change focus while external tools are receiving automated input.
      - Uses visible child PowerShell windows for external tool/script execution instead of hiding WitchyBND behavior.

    Run:
      pwsh -NoProfile -ExecutionPolicy Bypass -STA -File .\BBReborneDIYTool.ps1

    Bootstrap from Windows PowerShell is also okay:
      powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\BBReborneDIYTool.ps1

    Notes:
    - The script never deletes or cleans a user-selected folder.
    - It creates a dedicated setup root under the user's Downloads folder by default.
    - ZIP extraction uses Expand-Archive -Force, which may overwrite files with the same path inside
      the dedicated tool folder, but it does not remove unrelated files.
    - Runtime patch/diff folders are treated as inputs; destructive cleanup is limited to dedicated
      work/output folders created by the tool or child scripts.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:MemoryStatusChecked = $false
$script:OutputSpaceStatusChecked = $false
$script:LastMemoryWarnings = @()
$script:LastOutputSpaceWarning = ''


if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This WPF prototype requires Windows.'
}

# WPF needs STA. Relaunch this same script as STA if needed.
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $hostExe = (Get-Process -Id $PID).Path
    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-STA',
        '-File', "`"$PSCommandPath`""
    )
    Start-Process -FilePath $hostExe -ArgumentList $argList
    exit
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms

function Get-DownloadsFolder {
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace('shell:Downloads')
        if ($folder -and $folder.Self -and $folder.Self.Path) {
            return $folder.Self.Path
        }
    } catch {}

    return (Join-Path $env:USERPROFILE 'Downloads')
}

function Quote-PSString {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "''" }
    return "'$($Value.Replace("'", "''"))'"
}

function Find-ExecutableOnPath {
    param([Parameter(Mandatory)][string]$Name)

    try {
        $cmd = Get-Command $Name -ErrorAction Stop
        if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) {
            return $cmd.Source
        }
    } catch {}

    return $null
}

function Find-FirstFile {
    param(
        [Parameter(Mandatory)][string[]]$Roots,
        [Parameter(Mandatory)][string]$Filter
    )

    foreach ($root in $Roots) {
        if (-not $root) { continue }
        if (-not (Test-Path -LiteralPath $root)) { continue }

        $direct = Join-Path $root $Filter
        if (Test-Path -LiteralPath $direct) {
            return $direct
        }

        $matches = @(Get-ChildItem -LiteralPath $root -Filter $Filter -File -Recurse -ErrorAction SilentlyContinue)
        if ($matches.Count -gt 0) {
            return $matches[0].FullName
        }
    }

    return $null
}

function Find-Pwsh7Exe {
    $candidates = New-Object System.Collections.Generic.List[string]

    $fromPath = Find-ExecutableOnPath -Name 'pwsh.exe'
    if ($fromPath) { $candidates.Add($fromPath) }

    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $fixed = @(
        (Join-Path $programFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path $programFiles 'PowerShell\7-preview\pwsh.exe')
    )

    foreach ($path in $fixed) {
        if ($path -and (Test-Path -LiteralPath $path)) { $candidates.Add($path) }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        try {
            $versionText = & $candidate -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
            $major = [int](([string]$versionText).Split('.')[0])
            if ($major -ge 7) {
                return $candidate
            }
        } catch {}
    }

    return $null
}

function Get-PwshVersionText {
    param([Parameter(Mandatory)][string]$PwshPath)

    try {
        $versionText = & $PwshPath -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
        return ([string]$versionText).Trim()
    } catch {
        return 'unknown'
    }
}

function Find-DotNet9Exe {
    $candidates = New-Object System.Collections.Generic.List[string]

    $fromPath = Find-ExecutableOnPath -Name 'dotnet.exe'
    if ($fromPath) { $candidates.Add($fromPath) }

    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $fixedDir = Join-Path $programFiles 'dotnet'
    $fixed = Join-Path $fixedDir 'dotnet.exe'
    if ($fixed -and (Test-Path -LiteralPath $fixed)) { $candidates.Add($fixed) }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        try {
            $sdkLines = @(& $candidate --list-sdks 2>$null)
            foreach ($line in $sdkLines) {
                if (([string]$line).StartsWith('9.')) {
                    return $candidate
                }
            }

            $runtimeLines = @(& $candidate --list-runtimes 2>$null)
            foreach ($line in $runtimeLines) {
                if (([string]$line).StartsWith('Microsoft.NETCore.App 9.')) {
                    return $candidate
                }
            }
        } catch {}
    }

    return $null
}

function Get-DotNet9VersionText {
    param([Parameter(Mandatory)][string]$DotNetPath)

    try {
        $sdkLines = @(& $DotNetPath --list-sdks 2>$null | Where-Object { ([string]$_).StartsWith('9.') })
        if ($sdkLines.Count -gt 0) {
            return ('SDK ' + ([string]$sdkLines[0]).Split(' ')[0])
        }

        $runtimeLines = @(& $DotNetPath --list-runtimes 2>$null | Where-Object { ([string]$_).StartsWith('Microsoft.NETCore.App 9.') })
        if ($runtimeLines.Count -gt 0) {
            $parts = ([string]$runtimeLines[0]).Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
            if ($parts.Count -ge 2) { return ('Runtime ' + $parts[1]) }
        }
    } catch {}

    return 'unknown 9.x install'
}

function Find-ImageMagickExe {
    $fromPath = Find-ExecutableOnPath -Name 'magick.exe'
    if ($fromPath) { return $fromPath }

    $roots = @(
        [Environment]::GetFolderPath('ProgramFiles'),
        [Environment]::GetFolderPath('ProgramFilesX86')
    ) | Where-Object { $_ }

    foreach ($root in $roots) {
        $matches = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'ImageMagick*' -ErrorAction SilentlyContinue)
        foreach ($dir in $matches) {
            $exe = Join-Path $dir.FullName 'magick.exe'
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }

    return $null
}

function Get-WingetExe {
    return (Find-ExecutableOnPath -Name 'winget.exe')
}


function Get-ObjectPropertyValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Convert-RegistryByteStringToText {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return '' }

    try {
        if ($Value -is [byte[]]) {
            $text = [System.Text.Encoding]::Unicode.GetString($Value)
            return ($text -replace "`0", '').Trim()
        }
    } catch {
        return ''
    }

    return ([string]$Value).Trim()
}

function Convert-VideoMemoryValueToBytes {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return 0 }

    try {
        if ($Value -is [byte[]]) {
            if ($Value.Length -ge 8) { return [double][BitConverter]::ToUInt64($Value, 0) }
            if ($Value.Length -ge 4) { return [double][BitConverter]::ToUInt32($Value, 0) }
            return 0
        }

        if ($Value -is [array] -and -not ($Value -is [string])) {
            $bytes = [byte[]]@($Value | ForEach-Object { [byte]$_ })
            if ($bytes.Length -ge 8) { return [double][BitConverter]::ToUInt64($bytes, 0) }
            if ($bytes.Length -ge 4) { return [double][BitConverter]::ToUInt32($bytes, 0) }
            return 0
        }

        $number = [double]$Value
        if ($number -gt 0) { return $number }
    } catch {
        return 0
    }

    return 0
}

function Add-VramCandidate {
    param(
        [Parameter(Mandatory)]$List,
        [AllowNull()][string]$Name,
        [Parameter(Mandatory)][double]$Bytes,
        [Parameter(Mandatory)][string]$Source
    )

    if ($Bytes -le 0) { return }

    [void]$List.Add([pscustomobject]@{
        Name   = if ([string]::IsNullOrWhiteSpace($Name)) { 'Unknown GPU' } else { $Name }
        Bytes  = [double]$Bytes
        Source = $Source
    })
}

function Add-GpuNameCandidate {
    param(
        [Parameter(Mandatory)]$List,
        [AllowNull()][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    $clean = ([string]$Name).Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { return }
    [void]$List.Add($clean)
}

function Add-VramCandidateFromMiB {
    param(
        [Parameter(Mandatory)]$List,
        [AllowNull()][string]$Name,
        [Parameter(Mandatory)][double]$MiB,
        [Parameter(Mandatory)][string]$Source
    )

    if ($MiB -le 0) { return }
    Add-VramCandidate -List $List -Name $Name -Bytes ($MiB * 1MB) -Source $Source
}

function Add-DxDiagGpuCandidates {
    param(
        [Parameter(Mandatory)]$Names,
        [Parameter(Mandatory)]$Candidates
    )

    $dxdiag = Join-Path $env:WINDIR 'System32\dxdiag.exe'
    if (-not (Test-Path -LiteralPath $dxdiag -PathType Leaf)) { return }

    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("bbreborne_dxdiag_" + [guid]::NewGuid().ToString('N') + '.txt')

    try {
        $proc = Start-Process -FilePath $dxdiag -ArgumentList @('/whql:off', '/t', $tempFile) -PassThru -WindowStyle Hidden
        if (-not $proc.WaitForExit(25000)) {
            try { $proc.Kill() } catch {}
            return
        }

        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 10) {
            if (Test-Path -LiteralPath $tempFile -PathType Leaf) {
                $item = Get-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
                if ($item -and $item.Length -gt 0) { break }
            }
            Start-Sleep -Milliseconds 250
        }

        if (-not (Test-Path -LiteralPath $tempFile -PathType Leaf)) { return }

        $currentName = ''
        foreach ($line in (Get-Content -LiteralPath $tempFile -ErrorAction SilentlyContinue)) {
            $text = [string]$line

            $mName = [regex]::Match($text, '^\s*Card name:\s*(.+?)\s*$')
            if ($mName.Success) {
                $currentName = $mName.Groups[1].Value.Trim()
                Add-GpuNameCandidate -List $Names -Name $currentName
                continue
            }

            foreach ($label in @('Dedicated Memory', 'Display Memory')) {
                $mMem = [regex]::Match($text, '^\s*' + [regex]::Escape($label) + ':\s*([0-9,\.]+)\s*MB\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($mMem.Success) {
                    $memText = $mMem.Groups[1].Value.Replace(',', '')
                    $memMiB = 0.0
                    if ([double]::TryParse($memText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$memMiB)) {
                        Add-VramCandidateFromMiB -List $Candidates -Name $currentName -MiB $memMiB -Source "dxdiag.$label"
                    }
                }
            }
        }
    } catch {
        # dxdiag fallback is best effort only.
    } finally {
        try {
            if (Test-Path -LiteralPath $tempFile -PathType Leaf) {
                Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

function Add-WmicGpuCandidates {
    param(
        [Parameter(Mandatory)]$Names,
        [Parameter(Mandatory)]$Candidates
    )

    $wmic = Join-Path $env:WINDIR 'System32\wbem\wmic.exe'
    if (-not (Test-Path -LiteralPath $wmic -PathType Leaf)) { return }

    try {
        $lines = @(& $wmic path win32_VideoController get Name,AdapterRAM /format:list 2>$null)
        if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) { return }

        $currentName = ''
        foreach ($line in $lines) {
            $text = ([string]$line).Trim()
            if ($text -match '^Name=(.+)$') {
                $currentName = $Matches[1].Trim()
                Add-GpuNameCandidate -List $Names -Name $currentName
                continue
            }
            if ($text -match '^AdapterRAM=(.+)$') {
                $bytes = Convert-VideoMemoryValueToBytes -Value $Matches[1]
                Add-VramCandidate -List $Candidates -Name $currentName -Bytes $bytes -Source 'wmic.Win32_VideoController.AdapterRAM'
            }
        }
    } catch {
        # WMIC is not present on every Windows install.
    }
}


function Add-GpuAdapterMemoryCounterCandidates {
    param(
        [Parameter(Mandatory)]$Names,
        [Parameter(Mandatory)]$Candidates
    )

    # Vendor-agnostic Windows performance counter used by the graphics stack.
    # This is the closest PowerShell-accessible source to Task Manager's
    # "Dedicated GPU memory" capacity. It usually exposes the real dedicated
    # memory limit even when Win32_VideoController.AdapterRAM is capped at ~4 GB.
    try {
        $counterPaths = @()

        try {
            $set = Get-Counter -ListSet 'GPU Adapter Memory' -ErrorAction Stop
            $counterPaths = @($set.Counter | Where-Object { $_ -match '\\Dedicated Limit$' })
        } catch {
            $counterPaths = @()
        }

        if ($counterPaths.Count -eq 0) {
            $counterPaths = @('\GPU Adapter Memory(*)\Dedicated Limit')
        }

        $counterResult = Get-Counter -Counter $counterPaths -ErrorAction Stop
        foreach ($sample in @($counterResult.CounterSamples)) {
            $bytes = 0.0
            try { $bytes = [double]$sample.CookedValue } catch { $bytes = 0.0 }
            if ($bytes -le 0) { continue }

            $instance = ''
            try { $instance = [string]$sample.InstanceName } catch { $instance = '' }
            if ([string]::IsNullOrWhiteSpace($instance)) {
                $instance = 'Windows GPU adapter'
            }

            Add-VramCandidate -List $Candidates -Name ("GPU Adapter Memory: $instance") -Bytes $bytes -Source 'PerformanceCounter.GPU Adapter Memory.Dedicated Limit'
        }
    } catch {
        # The GPU Adapter Memory counter set is not available on every Windows install.
    }
}





function Add-ExternalRegistryGpuVramCandidates {
    param(
        [Parameter(Mandatory)]$Candidates
    )

    # Run the exact registry query in a fresh PowerShell process, save the raw
    # output to a log, then read it back. This mirrors the manual command that
    # works even when the WPF runspace fails to read the wildcard registry path.
    $psExe = $null
    try {
        $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $psExe = $cmd.Source }
    } catch {}
    if (-not $psExe) {
        try {
            $cmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
            if ($cmd -and $cmd.Source) { $psExe = $cmd.Source }
        } catch {}
    }
    if (-not $psExe) { return }

    $logDir = Join-Path ([System.IO.Path]::GetTempPath()) 'BBReborneDIYTool'
    try {
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
    } catch {
        $logDir = [System.IO.Path]::GetTempPath()
    }

    $rawLog = Join-Path $logDir 'vram_registry_probe_raw.txt'
    $scriptFile = Join-Path $logDir 'vram_registry_probe.ps1'

    $probeScript = @'
$ErrorActionPreference = 'SilentlyContinue'
$OutFile = "__RAW_LOG__"

# Exact command that works manually on the user's machine.
$qwMemorySize = (Get-ItemProperty -Path "HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*" -Name HardwareInformation.qwMemorySize -ErrorAction SilentlyContinue)."HardwareInformation.qwMemorySize"

# Same query against CurrentControlSet as a fallback.
$qwMemorySizeCurrent = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*" -Name HardwareInformation.qwMemorySize -ErrorAction SilentlyContinue)."HardwareInformation.qwMemorySize"

# 32-bit value fallback for older drivers/adapters.
$memorySize = (Get-ItemProperty -Path "HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*" -Name HardwareInformation.MemorySize -ErrorAction SilentlyContinue)."HardwareInformation.MemorySize"
$memorySizeCurrent = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*" -Name HardwareInformation.MemorySize -ErrorAction SilentlyContinue)."HardwareInformation.MemorySize"

$lines = New-Object System.Collections.Generic.List[string]

foreach ($value in @($qwMemorySize)) {
    if ($null -ne $value -and ([string]$value).Trim() -ne '') {
        [void]$lines.Add('RegistryExactCommand.ControlSet001.HardwareInformation.qwMemorySize|' + ([string]$value).Trim())
    }
}

foreach ($value in @($qwMemorySizeCurrent)) {
    if ($null -ne $value -and ([string]$value).Trim() -ne '') {
        [void]$lines.Add('RegistryExactCommand.CurrentControlSet.HardwareInformation.qwMemorySize|' + ([string]$value).Trim())
    }
}

foreach ($value in @($memorySize)) {
    if ($null -ne $value -and ([string]$value).Trim() -ne '') {
        [void]$lines.Add('RegistryExactCommand.ControlSet001.HardwareInformation.MemorySize|' + ([string]$value).Trim())
    }
}

foreach ($value in @($memorySizeCurrent)) {
    if ($null -ne $value -and ([string]$value).Trim() -ne '') {
        [void]$lines.Add('RegistryExactCommand.CurrentControlSet.HardwareInformation.MemorySize|' + ([string]$value).Trim())
    }
}

$lines | Set-Content -LiteralPath $OutFile -Encoding UTF8
'@

    $probeScript = $probeScript.Replace('__RAW_LOG__', ($rawLog -replace "'", "''"))

    try {
        [System.IO.File]::WriteAllText($scriptFile, $probeScript, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        return
    }

    try {
        $proc = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptFile) -PassThru -WindowStyle Hidden
        if (-not $proc.WaitForExit(15000)) {
            try { $proc.Kill() } catch {}
            return
        }
    } catch {
        return
    }

    if (-not (Test-Path -LiteralPath $rawLog -PathType Leaf)) {
        try { Write-UiLog "VRAM registry probe did not create log: $rawLog" } catch {}
        return
    }

    try {
        try { Write-UiLog "VRAM registry probe log: $rawLog" } catch {}

        $lines = @(Get-Content -LiteralPath $rawLog -Encoding UTF8 -ErrorAction SilentlyContinue)
        foreach ($line in $lines) {
            $text = ([string]$line).Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { continue }

            # Expected format:
            #   RegistryExactCommand.ControlSet001.HardwareInformation.qwMemorySize|34190917632
            # Parse this directly instead of relying on dynamic object/property behavior.
            $m = [regex]::Match($text, '^(?<source>[^|]+)\|(?<bytes>\d+)\s*$')
            if (-not $m.Success) { continue }

            $source = $m.Groups['source'].Value
            $rawBytes = $m.Groups['bytes'].Value

            [double]$bytes = 0
            try {
                $bytes = [double]([UInt64]::Parse($rawBytes, [System.Globalization.CultureInfo]::InvariantCulture))
            } catch {
                $bytes = Convert-VideoMemoryValueToBytes -Value $rawBytes
            }

            Add-VramCandidate -List $Candidates -Name 'Windows display adapter registry value' -Bytes $bytes -Source $source
            try { Write-UiLog ("VRAM candidate: Windows display adapter registry value = {0} ({1})" -f (Format-BytesAsGB -Bytes $bytes), $source) } catch {}
        }
    } catch {
        # Best effort only.
    }
}


function Add-RegistryGpuVramCandidates {
    param(
        [Parameter(Mandatory)]$Names,
        [Parameter(Mandatory)]$Candidates
    )

    # Vendor-agnostic registry probe.
    # First pass intentionally mirrors the exact manual command that worked:
    #   (Get-ItemProperty -Path "HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*" -Name HardwareInformation.qwMemorySize -ErrorAction SilentlyContinue)."HardwareInformation.qwMemorySize"
    # This direct aggregate property access is more reliable here than looping over
    # returned registry objects first, because registry property names contain dots.

    $registryWildcards = @(
        'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*',
        'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*'
    ) | Select-Object -Unique

    foreach ($wildcardPath in $registryWildcards) {
        try {
            $qwValues = @((Get-ItemProperty -Path $wildcardPath -Name 'HardwareInformation.qwMemorySize' -ErrorAction SilentlyContinue).'HardwareInformation.qwMemorySize')
            foreach ($value in $qwValues) {
                $bytes = Convert-VideoMemoryValueToBytes -Value $value
                Add-VramCandidate -List $Candidates -Name 'Windows display adapter registry value' -Bytes $bytes -Source 'RegistryExact.HardwareInformation.qwMemorySize'
            }
        } catch {
            # Best effort only.
        }

        try {
            $memoryValues = @((Get-ItemProperty -Path $wildcardPath -Name 'HardwareInformation.MemorySize' -ErrorAction SilentlyContinue).'HardwareInformation.MemorySize')
            foreach ($value in $memoryValues) {
                $bytes = Convert-VideoMemoryValueToBytes -Value $value
                Add-VramCandidate -List $Candidates -Name 'Windows display adapter registry value' -Bytes $bytes -Source 'RegistryExact.HardwareInformation.MemorySize'
            }
        } catch {
            # Best effort only.
        }
    }

    # Second pass tries to attach friendlier names to the same registry values.
    foreach ($wildcardPath in $registryWildcards) {
        $items = @()
        try {
            $items = @(Get-ItemProperty -Path $wildcardPath -ErrorAction SilentlyContinue)
        } catch {
            $items = @()
        }

        foreach ($props in $items) {
            if ($null -eq $props) { continue }

            $name = ''
            try { $name = [string]$props.DriverDesc } catch { $name = '' }
            if ([string]::IsNullOrWhiteSpace($name)) {
                try { $name = Convert-RegistryByteStringToText -Value $props.'HardwareInformation.AdapterString' } catch { $name = '' }
            }
            if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Windows display adapter registry key' }
            Add-GpuNameCandidate -List $Names -Name $name

            try {
                $value = $props.'HardwareInformation.qwMemorySize'
                $bytes = Convert-VideoMemoryValueToBytes -Value $value
                Add-VramCandidate -List $Candidates -Name $name -Bytes $bytes -Source 'RegistryKey.HardwareInformation.qwMemorySize'
            } catch {
                # Property may not exist on every adapter key.
            }

            try {
                $value = $props.'HardwareInformation.MemorySize'
                $bytes = Convert-VideoMemoryValueToBytes -Value $value
                Add-VramCandidate -List $Candidates -Name $name -Bytes $bytes -Source 'RegistryKey.HardwareInformation.MemorySize'
            } catch {
                # Property may not exist on every adapter key.
            }
        }
    }
}

function Add-DxgiGpuCandidates {
    param(
        [Parameter(Mandatory)]$Names,
        [Parameter(Mandatory)]$Candidates
    )

    # Vendor-agnostic Windows DXGI probe. Task Manager gets dedicated GPU memory
    # from the graphics stack; DXGI exposes the same DedicatedVideoMemory field.
    try {
        if (-not ('BBReborneDxgiGpuProbe' -as [type])) {
            Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class BBReborneDxgiGpuProbe
{
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DXGI_ADAPTER_DESC
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Description;
        public uint VendorId;
        public uint DeviceId;
        public uint SubSysId;
        public uint Revision;
        public UIntPtr DedicatedVideoMemory;
        public UIntPtr DedicatedSystemMemory;
        public UIntPtr SharedSystemMemory;
        public LUID AdapterLuid;
    }

    [ComImport, Guid("2411e7e1-12ac-4ccf-bd14-9798e8534dc0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDXGIAdapter
    {
        [PreserveSig] int SetPrivateData(ref Guid Name, uint DataSize, IntPtr pData);
        [PreserveSig] int SetPrivateDataInterface(ref Guid Name, IntPtr pUnknown);
        [PreserveSig] int GetPrivateData(ref Guid Name, ref uint pDataSize, IntPtr pData);
        [PreserveSig] int GetParent(ref Guid riid, out IntPtr ppParent);
        [PreserveSig] int EnumOutputs(uint Output, out IntPtr ppOutput);
        [PreserveSig] int GetDesc(out DXGI_ADAPTER_DESC pDesc);
        [PreserveSig] int CheckInterfaceSupport(ref Guid InterfaceName, out long pUMDVersion);
    }

    [ComImport, Guid("7b7166ec-21c7-44ae-b21a-c9ae321ae369"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDXGIFactory
    {
        [PreserveSig] int SetPrivateData(ref Guid Name, uint DataSize, IntPtr pData);
        [PreserveSig] int SetPrivateDataInterface(ref Guid Name, IntPtr pUnknown);
        [PreserveSig] int GetPrivateData(ref Guid Name, ref uint pDataSize, IntPtr pData);
        [PreserveSig] int GetParent(ref Guid riid, out IntPtr ppParent);
        [PreserveSig] int EnumAdapters(uint Adapter, out IDXGIAdapter ppAdapter);
        [PreserveSig] int MakeWindowAssociation(IntPtr WindowHandle, uint Flags);
        [PreserveSig] int GetWindowAssociation(out IntPtr WindowHandle);
        [PreserveSig] int CreateSwapChain(IntPtr pDevice, IntPtr pDesc, out IntPtr ppSwapChain);
        [PreserveSig] int CreateSoftwareAdapter(IntPtr Module, out IDXGIAdapter ppAdapter);
    }

    [DllImport("dxgi.dll")]
    private static extern int CreateDXGIFactory(ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IDXGIFactory ppFactory);

    public class AdapterInfo
    {
        public string Name;
        public ulong DedicatedVideoMemory;
        public ulong DedicatedSystemMemory;
        public ulong SharedSystemMemory;
        public uint VendorId;
        public uint DeviceId;
    }

    public static AdapterInfo[] GetAdapters()
    {
        var list = new List<AdapterInfo>();
        IDXGIFactory factory = null;
        Guid factoryGuid = new Guid("7b7166ec-21c7-44ae-b21a-c9ae321ae369");
        int hr = CreateDXGIFactory(ref factoryGuid, out factory);
        if (hr < 0 || factory == null) return list.ToArray();

        try
        {
            uint index = 0;
            while (true)
            {
                IDXGIAdapter adapter = null;
                hr = factory.EnumAdapters(index, out adapter);
                if (hr != 0 || adapter == null) break;

                try
                {
                    DXGI_ADAPTER_DESC desc;
                    hr = adapter.GetDesc(out desc);
                    if (hr == 0)
                    {
                        list.Add(new AdapterInfo {
                            Name = (desc.Description ?? "").Trim(),
                            DedicatedVideoMemory = desc.DedicatedVideoMemory.ToUInt64(),
                            DedicatedSystemMemory = desc.DedicatedSystemMemory.ToUInt64(),
                            SharedSystemMemory = desc.SharedSystemMemory.ToUInt64(),
                            VendorId = desc.VendorId,
                            DeviceId = desc.DeviceId
                        });
                    }
                }
                finally
                {
                    if (adapter != null) Marshal.ReleaseComObject(adapter);
                }

                index++;
            }
        }
        finally
        {
            if (factory != null) Marshal.ReleaseComObject(factory);
        }

        return list.ToArray();
    }
}
'@ | Out-Null
        }

        $adapters = @([BBReborneDxgiGpuProbe]::GetAdapters())
        foreach ($adapter in $adapters) {
            $name = [string]$adapter.Name
            Add-GpuNameCandidate -List $Names -Name $name
            $bytes = Convert-VideoMemoryValueToBytes -Value $adapter.DedicatedVideoMemory
            Add-VramCandidate -List $Candidates -Name $name -Bytes $bytes -Source 'DXGI.DedicatedVideoMemory'
        }
    } catch {
        # DXGI probing is best-effort only. Continue with WMI/registry/dxdiag fallbacks.
    }
}


function Get-GpuVramCandidates {
    $candidates = New-Object System.Collections.Generic.List[object]
    $names = New-Object System.Collections.Generic.List[string]

    # Prefer the display-adapter registry memory size first. On some systems this is the
    # only generic Windows source that exposes the real dedicated VRAM shown by Task Manager.
    Add-ExternalRegistryGpuVramCandidates -Candidates $candidates
    Add-RegistryGpuVramCandidates -Names $names -Candidates $candidates

    # Try the Windows GPU Adapter Memory performance counter when available.
    Add-GpuAdapterMemoryCounterCandidates -Names $names -Candidates $candidates

    # DXGI is also vendor-agnostic and may expose DedicatedVideoMemory directly.
    Add-DxgiGpuCandidates -Names $names -Candidates $candidates

    # Vendor-agnostic Windows sources only. Win32_VideoController.AdapterRAM is often capped/wrong above 4 GB,
    # but it is useful for names and as a low-confidence fallback.
    try {
        $videoControllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
        foreach ($vc in $videoControllers) {
            $name = [string](Get-ObjectPropertyValue -Object $vc -Name 'Name')
            Add-GpuNameCandidate -List $names -Name $name
            $bytes = Convert-VideoMemoryValueToBytes -Value (Get-ObjectPropertyValue -Object $vc -Name 'AdapterRAM')
            Add-VramCandidate -List $candidates -Name $name -Bytes $bytes -Source 'Win32_VideoController.AdapterRAM'
        }
    } catch {
        # Continue with other sources.
    }

    # Older fallback for environments where CIM is blocked or unavailable.
    try {
        $videoControllers = @(Get-WmiObject -Class Win32_VideoController -ErrorAction Stop)
        foreach ($vc in $videoControllers) {
            $name = [string](Get-ObjectPropertyValue -Object $vc -Name 'Name')
            Add-GpuNameCandidate -List $names -Name $name
            $bytes = Convert-VideoMemoryValueToBytes -Value (Get-ObjectPropertyValue -Object $vc -Name 'AdapterRAM')
            Add-VramCandidate -List $candidates -Name $name -Bytes $bytes -Source 'Win32_VideoController.AdapterRAM.WMI'
        }
    } catch {
        # Get-WmiObject is unavailable in some PowerShell 7 environments.
    }

    # WMIC fallback sometimes succeeds even when CIM/WMI cmdlets are unavailable.
    Add-WmicGpuCandidates -Names $names -Candidates $candidates

    # Extra name fallback. Some systems expose display adapters here even when VRAM properties are not reliable.
    try {
        $displayPnP = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.PNPClass -eq 'Display' })
        foreach ($item in $displayPnP) {
            $name = [string](Get-ObjectPropertyValue -Object $item -Name 'Name')
            Add-GpuNameCandidate -List $names -Name $name
        }
    } catch {
        # Best effort only.
    }

    # Some Windows builds expose richer GPU memory information here.
    try {
        $wmiAdapters = @(Get-CimInstance -Namespace 'root\WMI' -ClassName 'MSFT_VideoAdapter' -ErrorAction Stop)
        foreach ($adapter in $wmiAdapters) {
            $name = [string](Get-ObjectPropertyValue -Object $adapter -Name 'Name')
            Add-GpuNameCandidate -List $names -Name $name

            foreach ($propName in @('DedicatedVideoMemory', 'DedicatedVideoMemorySize', 'AdapterDedicatedMemory')) {
                $bytes = Convert-VideoMemoryValueToBytes -Value (Get-ObjectPropertyValue -Object $adapter -Name $propName)
                Add-VramCandidate -List $candidates -Name $name -Bytes $bytes -Source "root\WMI.MSFT_VideoAdapter.$propName"
            }
        }
    } catch {
        # This class is not available on every system.
    }

    # Slow but broad Windows fallback. This also catches many hybrid iGPU/dGPU systems.
    if ($names.Count -eq 0 -or $candidates.Count -eq 0) {
        Add-DxDiagGpuCandidates -Names $names -Candidates $candidates
    }

    if ($names.Count -eq 0 -and $candidates.Count -gt 0) {
        foreach ($candidate in $candidates) {
            Add-GpuNameCandidate -List $names -Name ([string]$candidate.Name)
        }
    }

    return [pscustomobject]@{
        Names      = @($names | Where-Object { $_ } | Select-Object -Unique)
        Candidates = @($candidates)
    }
}


function Get-VramCandidatesFromRegistryRawLog {
    $result = New-Object System.Collections.Generic.List[object]
    $rawLog = Join-Path (Join-Path ([System.IO.Path]::GetTempPath()) 'BBReborneDIYTool') 'vram_registry_probe_raw.txt'

    if (-not (Test-Path -LiteralPath $rawLog -PathType Leaf)) {
        return @()
    }

    try {
        $lines = @(Get-Content -LiteralPath $rawLog -Encoding UTF8 -ErrorAction SilentlyContinue)
        foreach ($line in $lines) {
            $text = ([string]$line).Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { continue }

            $m = [regex]::Match($text, '^(?<source>[^|]+)\|(?<bytes>\d+)\s*$')
            if (-not $m.Success) { continue }

            $source = $m.Groups['source'].Value
            $rawBytes = $m.Groups['bytes'].Value

            [double]$bytes = 0
            try {
                $bytes = [double]([UInt64]::Parse($rawBytes, [System.Globalization.CultureInfo]::InvariantCulture))
            } catch {
                $bytes = Convert-VideoMemoryValueToBytes -Value $rawBytes
            }

            if ($bytes -gt 0) {
                [void]$result.Add([pscustomobject]@{
                    Name   = 'Windows display adapter registry value'
                    Bytes  = [double]$bytes
                    Source = $source
                })
            }
        }
    } catch {
        return @()
    }

    return [object[]]$result.ToArray()
}

function Get-SystemProbeInfo {
    $logicalProcessors = [Environment]::ProcessorCount
    $cpuNames = @()
    $gpuNames = @()
    [double]$totalRamBytes = 0
    [double]$maxVramBytes = 0
    $maxVramSource = ''
    $maxVramGpuName = ''
    $gpuProbe = $null

    try {
        $cpuNames = @(Get-CimInstance Win32_Processor -ErrorAction Stop | ForEach-Object { $_.Name } | Where-Object { $_ })
    } catch {
        $cpuNames = @('CPU detection unavailable')
    }

    try {
        $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($computerSystem.TotalPhysicalMemory) {
            $totalRamBytes = [double]$computerSystem.TotalPhysicalMemory
        }
    } catch {
        $totalRamBytes = 0
    }

    try {
        $gpuProbe = Get-GpuVramCandidates
        $gpuNames = @($gpuProbe.Names | Where-Object { $_ })
        if ($gpuNames.Count -eq 0) { $gpuNames = @('GPU detection unavailable') }

        $best = @($gpuProbe.Candidates | Where-Object { $_.Bytes -gt 0 } | Sort-Object Bytes -Descending | Select-Object -First 1)
        if ($best.Count -gt 0) {
            $maxVramBytes = [double]$best[0].Bytes
            $maxVramSource = [string]$best[0].Source
            $maxVramGpuName = [string]$best[0].Name
        }
    } catch {
        $gpuNames = @('GPU detection unavailable')
        $maxVramBytes = 0
        $maxVramSource = ''
        $maxVramGpuName = ''
    }

    # Hard fallback: if the external registry probe produced the raw log but the
    # normal candidate path failed to carry it through, read the log directly here.
    # This keeps the UI flexible and does not depend on GPU model names.
    $rawLogCandidates = @(Get-VramCandidatesFromRegistryRawLog)
    if ($rawLogCandidates.Count -gt 0) {
        if ($null -eq $gpuProbe) {
            $gpuProbe = [pscustomobject]@{
                Names      = @()
                Candidates = @()
            }
        }

        $existingCandidates = @($gpuProbe.Candidates)
        $gpuProbe = [pscustomobject]@{
            Names      = @($gpuProbe.Names)
            Candidates = @($existingCandidates + $rawLogCandidates)
        }

        $bestRaw = @($rawLogCandidates | Where-Object { $_.Bytes -gt 0 } | Sort-Object Bytes -Descending | Select-Object -First 1)
        if ($maxVramBytes -le 0 -and $bestRaw.Count -gt 0) {
            $maxVramBytes = [double]$bestRaw[0].Bytes
            $maxVramSource = [string]$bestRaw[0].Source
            $maxVramGpuName = [string]$bestRaw[0].Name
        }
    }

    # Do not infer VRAM or throttle from GPU model names. Future GPUs should work
    # through detected VRAM or through the user's manual VRAM override field.
    $gpuThrottle = 1
    if ($maxVramBytes -ge 16GB) {
        $gpuThrottle = 2
    }

    $cpuThrottle = [Math]::Max(1, $logicalProcessors - 2)

    $vramCandidateList = if ($null -ne $gpuProbe) { @($gpuProbe.Candidates) } else { @() }

    return [pscustomobject]@{
        LogicalProcessors  = $logicalProcessors
        CpuNames           = $cpuNames
        GpuNames           = $gpuNames
        TotalRamBytes      = $totalRamBytes
        MaxVramBytes       = $maxVramBytes
        MaxVramSource      = $maxVramSource
        MaxVramGpuName     = $maxVramGpuName
        DefaultCpuThrottle = $cpuThrottle
        DefaultGpuThrottle = $gpuThrottle
        VramCandidates     = $vramCandidateList
    }
}

function Get-PositiveIntFromTextBox {
    param(
        [Parameter(Mandatory)]$TextBox,
        [Parameter(Mandatory)][string]$Label
    )

    $raw = $TextBox.Text.Trim()
    $value = 0
    if (-not [int]::TryParse($raw, [ref]$value)) {
        throw "$Label must be a positive integer. Current value: $raw"
    }
    if ($value -lt 1) {
        throw "$Label must be at least 1. Current value: $value"
    }

    return $value
}

function Apply-SystemProbeDefaults {
    param([switch]$OverwriteExisting)

    $probe = Get-SystemProbeInfo
    $probe = Apply-GpuVramManualOverride -Probe $probe

    $TxtCpuInfo.Text = (($probe.CpuNames | Select-Object -Unique) -join ' | ')
    $TxtCpuLogical.Text = [string]$probe.LogicalProcessors
    $TxtGpuInfo.Text = (($probe.GpuNames | Select-Object -Unique) -join ' | ')

    if ($OverwriteExisting -or [string]::IsNullOrWhiteSpace($TxtCpuThrottle.Text)) {
        $TxtCpuThrottle.Text = [string]$probe.DefaultCpuThrottle
    }
    $gpuDetectionUnavailable = (($probe.GpuNames -join '|') -match 'GPU detection unavailable') -and ($probe.MaxVramBytes -le 0)
    if ($gpuDetectionUnavailable) {
        if ([string]::IsNullOrWhiteSpace($TxtGpuThrottle.Text)) {
            $TxtGpuThrottle.Text = '1'
            Write-UiLog 'GPU detection unavailable; GPU throttle was empty, so it was left at the conservative default of 1.'
        } else {
            Write-UiLog 'GPU detection unavailable; keeping existing GPU throttle value instead of resetting it.'
        }
    } elseif ($OverwriteExisting -or [string]::IsNullOrWhiteSpace($TxtGpuThrottle.Text)) {
        $TxtGpuThrottle.Text = [string]$probe.DefaultGpuThrottle
    }

    Update-MemoryStatus -Probe $probe | Out-Null
    Update-OutputSpaceStatus | Out-Null

    $ramText = if ($probe.TotalRamBytes -gt 0) { Format-BytesAsGB -Bytes $probe.TotalRamBytes } else { 'Unknown' }
    $vramText = if ($probe.MaxVramBytes -gt 0) { Format-BytesAsGB -Bytes $probe.MaxVramBytes } else { 'Unknown' }
    $topVramCandidates = @($probe.VramCandidates | Where-Object { $_.Bytes -gt 0 } | Sort-Object Bytes -Descending | Select-Object -First 5)
    foreach ($candidate in $topVramCandidates) {
        Write-UiLog ("VRAM candidate: {0} = {1} ({2})" -f $candidate.Name, (Format-BytesAsGB -Bytes ([double]$candidate.Bytes)), $candidate.Source)
    }
    Write-UiLog "System probe: logical CPU threads=$($probe.LogicalProcessors), RAM=$ramText, VRAM=$vramText ($($probe.MaxVramGpuName), $($probe.MaxVramSource)), default CPU throttle=$($probe.DefaultCpuThrottle), default GPU throttle=$($probe.DefaultGpuThrottle)."
}

function Format-BytesAsGB {
    param([Parameter(Mandatory)][double]$Bytes)
    return ('{0:N1} GB' -f ($Bytes / 1GB))
}


function Convert-GpuVramTextToBytes {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
    $raw = ([string]$Text).Trim()
    if ($raw -match '(?i)unknown|detected|inferred') { return 0 }

    $m = [regex]::Match($raw, '([0-9]+(?:[\.,][0-9]+)?)')
    if (-not $m.Success) { return 0 }

    $numberText = $m.Groups[1].Value.Replace(',', '.')
    $value = 0.0
    if (-not [double]::TryParse($numberText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        return 0
    }
    if ($value -le 0) { return 0 }

    if ($raw -match '(?i)\bTB\b|\bTiB\b') { return [double]($value * 1TB) }
    if ($raw -match '(?i)\bMB\b|\bMiB\b') { return [double]($value * 1MB) }
    return [double]($value * 1GB)
}

function Apply-GpuVramManualOverride {
    param([Parameter(Mandatory)]$Probe)

    # The GPU VRAM box is intentionally editable. Windows does not expose exact
    # dedicated VRAM reliably on every system, especially for newer cards. If the
    # user typed a plain value such as "24" or "24 GB", prefer it over unavailable
    # or suspiciously low automatic detection.
    $manualBytes = Convert-GpuVramTextToBytes -Text $TxtGpuVram.Text
    if ($manualBytes -le 0) { return $Probe }

    if ($Probe.MaxVramBytes -le 0 -or $manualBytes -gt $Probe.MaxVramBytes) {
        $Probe.MaxVramBytes = [double]$manualBytes
        $Probe.MaxVramSource = 'Manual override'
        $Probe.MaxVramGpuName = 'User-entered VRAM value'
    }

    if ($Probe.MaxVramBytes -ge 16GB) {
        $Probe.DefaultGpuThrottle = 2
    }

    return $Probe
}

function Update-CombinedRequirementsStatus {
    $warnings = New-Object System.Collections.Generic.List[string]

    if ($script:LastMemoryWarnings) {
        foreach ($warning in @($script:LastMemoryWarnings)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$warning)) {
                [void]$warnings.Add([string]$warning)
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$script:LastOutputSpaceWarning)) {
        [void]$warnings.Add([string]$script:LastOutputSpaceWarning)
    }

    if ($warnings.Count -gt 0) {
        $TxtMemoryStatus.Text = 'WARNING: ' + ($warnings -join ' ')
        $TxtMemoryStatus.Foreground = [System.Windows.Media.Brushes]::Orange
        return $false
    }

    if ($script:MemoryStatusChecked -and $script:OutputSpaceStatusChecked) {
        $TxtMemoryStatus.Text = 'OK: RAM, VRAM, and output free space meet the recommended thresholds.'
        $TxtMemoryStatus.Foreground = [System.Windows.Media.Brushes]::LightGreen
        return $true
    }

    $TxtMemoryStatus.Text = 'Not checked'
    $TxtMemoryStatus.Foreground = [System.Windows.Media.Brushes]::Gray
    return $false
}

function Update-MemoryStatus {
    param([Parameter(Mandatory)]$Probe)

    if ($Probe.TotalRamBytes -gt 0) {
        $TxtSystemRam.Text = Format-BytesAsGB -Bytes $Probe.TotalRamBytes
    } else {
        $TxtSystemRam.Text = 'Unknown'
    }

    if ($Probe.MaxVramBytes -gt 0) {
        if ([string]$Probe.MaxVramSource -eq 'Manual override') {
            $TxtGpuVram.Text = (Format-BytesAsGB -Bytes $Probe.MaxVramBytes) + ' manual'
        } else {
            $TxtGpuVram.Text = (Format-BytesAsGB -Bytes $Probe.MaxVramBytes) + ' highest detected'
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($TxtGpuVram.Text) -or $TxtGpuVram.Text -match '(?i)unknown|detected|inferred') {
            $TxtGpuVram.Text = 'Unknown - enter GB manually if needed'
        }
    }

    $warnings = New-Object System.Collections.Generic.List[string]

    if ($Probe.TotalRamBytes -gt 0 -and $Probe.TotalRamBytes -lt 32GB) {
        [void]$warnings.Add('System RAM is below 32 GB. Some patches use large in-memory editing and may fail or run slowly.')
    }

    if ($Probe.MaxVramBytes -gt 0) {
        if ($Probe.MaxVramBytes -lt 16GB) {
            [void]$warnings.Add('Dedicated GPU VRAM is below 16 GB. Running the final modded game is advised on a GPU with 16 GB VRAM or more.')
        }
    } else {
        [void]$warnings.Add('VRAM detection was unavailable. Enter dedicated GPU VRAM manually if Windows does not expose it. Running the final modded game is advised on a GPU with 16 GB VRAM or more.')
    }

    $script:MemoryStatusChecked = $true
    $script:LastMemoryWarnings = @($warnings)

    foreach ($warning in $warnings) { Write-UiLog "WARNING: $warning" }

    return (Update-CombinedRequirementsStatus)
}

function Get-OutputDriveSpaceInfo {
    param([Parameter(Mandatory)][string]$OutputPath)

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        throw 'Output folder is empty.'
    }

    $fullPath = [System.IO.Path]::GetFullPath($OutputPath.Trim())
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($rootPath)) {
        throw "Could not determine drive root for output folder: $fullPath"
    }

    $drive = New-Object System.IO.DriveInfo($rootPath)
    if (-not $drive.IsReady) {
        throw "Output drive is not ready: $rootPath"
    }

    return [pscustomobject]@{
        OutputPath = $fullPath
        Root       = $rootPath
        FreeBytes  = [double]$drive.AvailableFreeSpace
        TotalBytes = [double]$drive.TotalSize
    }
}

function Update-OutputSpaceStatus {
    try {
        $info = Get-OutputDriveSpaceInfo -OutputPath $TxtOutputRoot.Text
        $freeText = Format-BytesAsGB -Bytes $info.FreeBytes

        $TxtOutputPathProbe.Text = $info.OutputPath
        $TxtOutputDrive.Text = $info.Root
        $TxtOutputFreeSpace.Text = $freeText

        $script:OutputSpaceStatusChecked = $true

        if ($info.FreeBytes -lt 100GB) {
            $script:LastOutputSpaceWarning = "Output drive $($info.Root) has less than 100 GB free ($freeText). Processes may fail due to low available space."
            $TxtOutputSpaceStatus.Text = $script:LastOutputSpaceWarning
            $TxtOutputSpaceStatus.Foreground = [System.Windows.Media.Brushes]::Orange
            Write-UiLog "WARNING: $($script:LastOutputSpaceWarning)"
            return (Update-CombinedRequirementsStatus)
        }

        $script:LastOutputSpaceWarning = ''
        $TxtOutputSpaceStatus.Text = "Output drive OK: $freeText free."
        $TxtOutputSpaceStatus.Foreground = [System.Windows.Media.Brushes]::LightGreen
        return (Update-CombinedRequirementsStatus)
    } catch {
        $TxtOutputPathProbe.Text = $TxtOutputRoot.Text.Trim()
        $TxtOutputDrive.Text = ''
        $TxtOutputFreeSpace.Text = ''
        $script:OutputSpaceStatusChecked = $true
        $script:LastOutputSpaceWarning = "Could not check output free space. $($_.Exception.Message)"
        $TxtOutputSpaceStatus.Text = $script:LastOutputSpaceWarning
        $TxtOutputSpaceStatus.Foreground = [System.Windows.Media.Brushes]::Orange
        Write-UiLog "WARNING: $($script:LastOutputSpaceWarning)"
        return (Update-CombinedRequirementsStatus)
    }
}

function Get-WitchyBndUserSettingsPath {
    $appData = [Environment]::GetFolderPath('ApplicationData')
    return (Join-Path (Join-Path $appData 'WitchyBND') 'appsettings.user.json')
}

function Get-WitchyBnd3001RoamingSettingsJson {
    $settings = [ordered]@{
        Bnd                        = $true
        ParamDefaultValueThreshold = 1
        ParamCellStyle             = 0
        Recursive                  = $true
        EndDelay                   = 100
        PauseOnError               = $false
        Parallel                   = $true
        Expert                     = $false
        Offline                    = $true
        TaeFolder                  = $false
        DeferTools                 = [ordered]@{}
        Flexible                   = $true
        LastUpdateCheck            = '2026-01-15T20:01:33.8508924-03:00'
        SkipUpdateVersion          = '3.0.0.0'
        LastLaunchedVersion        = '3.0.0.1'
        BackupMethod               = 1
        GitBackup                  = $false
    }

    return ($settings | ConvertTo-Json -Depth 8)
}

function Get-WitchyBnd21445RoamingSettingsJson {
    $settings = [ordered]@{
        Bnd                        = $false
        Dcx                        = $false
        ParamDefaultValueThreshold = 1
        ParamCellStyle             = 0
        Recursive                  = $true
        EndDelay                   = 100
        PauseOnError               = $false
        Parallel                   = $true
        Expert                     = $false
        Offline                    = $true
        TaeFolder                  = $false
        DeferTools                 = [ordered]@{}
        Flexible                   = $false
        LastUpdateCheck            = '2026-01-15T20:01:33.8508924-03:00'
        SkipUpdateVersion          = '3.0.0.0'
        LastLaunchedVersion        = '2.14.4.5'
        BackupMethod               = 1
        GitBackup                  = $false
    }

    return ($settings | ConvertTo-Json -Depth 8)
}

function Get-WitchyBndRecommendedSettingsJson {
    # Default setup-time roaming profile. The global runner rewrites this before
    # every WitchyBND-backed global script so the active version gets its own settings.
    return (Get-WitchyBnd21445RoamingSettingsJson)
}

function Get-WitchyBnd2401LocalSettingsJson {
    $settings = [ordered]@{
        Bnd                = $false
        Dcx                = $false
        ParamDefaultValues = $true
        Recursive          = $true
        EndDelay           = 100
        PauseOnError       = $false
        Parallel           = $false
        Expert             = $false
        Offline            = $false
    }

    return ($settings | ConvertTo-Json -Depth 8)
}

function Install-BBReborneUpscalerModels {
    $sourceDir = Join-Path $scriptRoot 'AI_upscaler'
    $sourceBin = Join-Path $sourceDir 'BBReborneUpscaler.bin'
    $sourceParam = Join-Path $sourceDir 'BBReborneUpscaler.param'

    if (-not (Test-Path -LiteralPath $sourceBin -PathType Leaf)) {
        throw "Missing custom upscaler file: $sourceBin"
    }
    if (-not (Test-Path -LiteralPath $sourceParam -PathType Leaf)) {
        throw "Missing custom upscaler file: $sourceParam"
    }

    $realEsrganTool = Get-ToolByKey -Key 'RE'
    $realEsrganDir = Get-ToolInstallDir -Tool $realEsrganTool
    $modelsDir = Join-Path $realEsrganDir 'models'

    $toolRootFull = [System.IO.Path]::GetFullPath($TxtToolRoot.Text.Trim())
    $modelsDirFull = [System.IO.Path]::GetFullPath($modelsDir)
    $expectedModelsDirFull = [System.IO.Path]::GetFullPath((Join-Path (Get-ToolInstallDir -Tool $realEsrganTool) 'models'))

    if (-not $modelsDirFull.StartsWith($toolRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify Real-ESRGAN models folder outside the configured tool root: $modelsDirFull"
    }
    if ($modelsDirFull -ne $expectedModelsDirFull) {
        throw "Unexpected Real-ESRGAN models folder path: $modelsDirFull"
    }

    New-Item -ItemType Directory -Path $modelsDirFull -Force | Out-Null

    $existingItems = @(Get-ChildItem -LiteralPath $modelsDirFull -Force -ErrorAction SilentlyContinue)
    if ($existingItems.Count -gt 0) {
        $backupRoot = Join-Path $realEsrganDir '_models_backup'
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $backupDir = Join-Path $backupRoot "models_$stamp"
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

        foreach ($item in $existingItems) {
            Move-Item -LiteralPath $item.FullName -Destination $backupDir -Force
        }

        Write-UiLog "Real-ESRGAN default models moved to backup: $backupDir"
    }

    Copy-Item -LiteralPath $sourceBin -Destination (Join-Path $modelsDirFull 'BBReborneUpscaler.bin') -Force
    Copy-Item -LiteralPath $sourceParam -Destination (Join-Path $modelsDirFull 'BBReborneUpscaler.param') -Force

    Write-UiLog "Custom Real-ESRGAN model installed: $(Join-Path $modelsDirFull 'BBReborneUpscaler.bin')"
    Write-UiLog "Custom Real-ESRGAN model installed: $(Join-Path $modelsDirFull 'BBReborneUpscaler.param')"
}

function Get-DiffRoot {
    return (Join-Path $scriptRoot 'Diffs')
}

function Get-RequiredOutputRoot {
    $outputRoot = $TxtOutputRoot.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($outputRoot)) {
        throw 'Output folder is empty.'
    }
    return ([System.IO.Path]::GetFullPath($outputRoot))
}

function Ensure-ModOutputFolders {
    $outputRoot = Get-RequiredOutputRoot
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    foreach ($folderName in $AllOutputFolders) {
        $folderPath = Join-Path $outputRoot $folderName
        New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
        Write-UiLog "Output folder ready: $folderPath"
    }

    Update-OutputSpaceStatus | Out-Null
}

function Get-OutputFolderPath {
    param([Parameter(Mandatory)][string]$FolderName)
    return (Join-Path (Get-RequiredOutputRoot) $FolderName)
}

function Get-DiffCandidatesForScope {
    param(
        [Parameter(Mandatory)][string]$Scope,
        [AllowNull()][string]$MapCode
    )

    $diffRoot = Get-DiffRoot
    if (-not (Test-Path -LiteralPath $diffRoot -PathType Container)) {
        return @()
    }

    if ($Scope -eq 'Global') {
        return @(
            Get-ChildItem -LiteralPath $diffRoot -Recurse -File -Include '*.patch','*.diff' -ErrorAction SilentlyContinue |
                Where-Object {
                    $path = $_.FullName
                    $GlobalOutputFolders | Where-Object { $path -match [regex]::Escape($_) }
                }
        )
    }

    $mapLower = $MapCode.ToLowerInvariant()
    return @(
        Get-ChildItem -LiteralPath $diffRoot -Recurse -File -Include '*.patch','*.diff' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName.ToLowerInvariant().Contains($mapLower) }
    )
}


function Test-GlobalGeneratedFiles {
    Ensure-ModOutputFolders

    $outputRoot = Get-RequiredOutputRoot
    $expectedFiles = @(
        'BBReborne_sfx\sfx\frpg_sfxbnd_commoneffects.ffxbnd.dcx',
        'BBReborne_sfx\sfx\frpg_sfxbnd_m25.ffxbnd.dcx',
        'BBReborne_menu\menu\fe.gfx',
        'BBReborne_gparam\param\gameparam\gameparam.parambnd.dcx'
    )

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($relative in $expectedFiles) {
        $path = Join-Path $outputRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [void]$missing.Add($relative)
        }
    }

    $objRoot = Join-Path $outputRoot 'BBReborne_obj'
    $objFiles = @()
    if (Test-Path -LiteralPath $objRoot -PathType Container) {
        $objFiles = @(Get-ChildItem -LiteralPath $objRoot -Recurse -File -Filter '*.objbnd.dcx' -ErrorAction SilentlyContinue)
    }

    if ($objFiles.Count -eq 0) {
        [void]$missing.Add('BBReborne_obj\*.objbnd.dcx')
    }

    if ($missing.Count -gt 0) {
        Write-UiLog "GLOBAL check: missing $($missing.Count) expected output item(s):"
        foreach ($item in $missing) { Write-UiLog "  Missing: $item" }
        return 'Missing'
    }

    Write-UiLog "GLOBAL check: expected global outputs found. OBJ binders found: $($objFiles.Count)."
    return 'Generated'
}


function Count-FilesSafe {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Filter,
        [switch]$Recurse
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return 0 }
    $gci = @{ LiteralPath=$Root; File=$true; Filter=$Filter; ErrorAction='SilentlyContinue' }
    if ($Recurse) { $gci.Recurse = $true }
    return @((Get-ChildItem @gci)).Count
}

function Count-MapFolderPatchFiles {
    param(
        [Parameter(Mandatory)][string]$MapCode,
        [Parameter(Mandatory)][string]$Pattern
    )
    $count = 0
    $diffRoot = Get-DiffRoot
    foreach ($folder in @(Get-MapFoldersForMapCode -MapCode $MapCode)) {
        $patchDir = Join-Path (Join-Path (Join-Path $diffRoot 'map') $folder) '_patches'
        $count += (Count-FilesSafe -Root $patchDir -Filter $Pattern)
    }
    return $count
}

function Count-MapFolderOutputFiles {
    param(
        [Parameter(Mandatory)][string]$OutputFolderName,
        [Parameter(Mandatory)][string]$MapCode,
        [Parameter(Mandatory)][string]$Pattern
    )
    $count = 0
    $root = Get-OutputFolderPath -FolderName $OutputFolderName
    foreach ($folder in @(Get-MapFoldersForMapCode -MapCode $MapCode)) {
        $dir = Join-Path (Join-Path $root 'map') $folder
        $count += (Count-FilesSafe -Root $dir -Filter $Pattern)
    }
    return $count
}


function Get-MapStudioPatchFiles {
    $diffRoot = Get-DiffRoot
    $msbPatchDir = Join-Path (Join-Path (Join-Path $diffRoot 'map') 'mapstudio') '_patches'
    if (-not (Test-Path -LiteralPath $msbPatchDir -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $msbPatchDir -File -Recurse -Filter '*.patch' -ErrorAction SilentlyContinue | Sort-Object FullName -Unique)
}

function Get-MapStudioPatchLeafBase {
    param([Parameter(Mandatory)][string]$Leaf)

    $base = [string]$Leaf
    if ($base.EndsWith('.patch', [StringComparison]::OrdinalIgnoreCase)) { $base = $base.Substring(0, $base.Length - 6) }
    if ($base.EndsWith('.msb.json', [StringComparison]::OrdinalIgnoreCase)) { $base = $base.Substring(0, $base.Length - 9) }
    elseif ($base.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) { $base = $base.Substring(0, $base.Length - 5) }
    if ($base.EndsWith('.msb.dcx', [StringComparison]::OrdinalIgnoreCase)) { $base = $base.Substring(0, $base.Length - 8) }
    elseif ($base.EndsWith('.msb', [StringComparison]::OrdinalIgnoreCase)) { $base = $base.Substring(0, $base.Length - 4) }
    elseif ($base.EndsWith('.dcx', [StringComparison]::OrdinalIgnoreCase)) { $base = $base.Substring(0, $base.Length - 4) }
    return $base
}

function Test-MapStudioPatchMatchesFolder {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$PatchFile,
        [Parameter(Mandatory)][string]$MapFolder
    )

    $leafBase = Get-MapStudioPatchLeafBase -Leaf $PatchFile.Name
    if ($leafBase.Equals($MapFolder, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($PatchFile.Name.StartsWith($MapFolder, [StringComparison]::OrdinalIgnoreCase)) { return $true }

    # Mapstudio patches can target numbered MSB files, e.g.:
    #   m24_00_00_01.patch -> m24_00_00_01.msb.dcx
    # while the selectable folder is represented by:
    #   m24_00_00_00
    # Match by the stable three-part prefix m24_00_00_.
    $folderPrefix = $MapFolder -replace '_[^_]+$', '_'
    if ($leafBase.StartsWith($folderPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($PatchFile.Name.StartsWith($folderPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }

    # Fall back to the patch header/content. Some older mapstudio patches have
    # generic names or use .json instead of .msb.json in the diff header.
    try {
        $mapEsc = [regex]::Escape($MapFolder)
        $prefixEsc = [regex]::Escape($folderPrefix)
        foreach ($line in @(Get-Content -LiteralPath $PatchFile.FullName -TotalCount 80 -ErrorAction Stop)) {
            if ($line -match $mapEsc) { return $true }
            if ($line -match $prefixEsc) { return $true }
        }
    }
    catch {}

    return $false
}

function Get-MapStudioExpectedFoldersForMapCode {
    param([Parameter(Mandatory)][string]$MapCode)

    $patches = @(Get-MapStudioPatchFiles)
    $expected = New-Object System.Collections.ArrayList
    foreach ($folder in @(Get-MapFoldersForMapCode -MapCode $MapCode)) {
        foreach ($patch in $patches) {
            if (Test-MapStudioPatchMatchesFolder -PatchFile $patch -MapFolder $folder) {
                $leafBase = Get-MapStudioPatchLeafBase -Leaf $patch.Name
                if ([string]::IsNullOrWhiteSpace($leafBase)) { $leafBase = $folder }
                [void]$expected.Add($leafBase)
            }
        }
    }
    return @($expected.ToArray() | Sort-Object -Unique)
}


function Get-GparamExpectedBinderLeavesForMapCode {
    param([Parameter(Mandatory)][string]$MapCode)

    $diffRoot = Get-DiffRoot
    $drawparamPatchRoot = Join-Path (Join-Path $diffRoot 'param') 'drawparam'
    $short = Get-ShortMapCode -MapCode $MapCode
    $expected = New-Object System.Collections.ArrayList

    if (-not (Test-Path -LiteralPath $drawparamPatchRoot -PathType Container)) { return @() }

    $patches = @(Get-ChildItem -LiteralPath $drawparamPatchRoot -File -Recurse -Filter '*.gparam.xml.patch' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith(($short + '_'), [StringComparison]::OrdinalIgnoreCase) })

    foreach ($patch in $patches) {
        $binderLeaf = ''

        # Preferred working layout:
        #   Diffs\param\drawparam\m21_00_0000-gparambnd-dcx\_patches\m21_00_0000.gparam.xml.patch
        $parent = Split-Path -Parent $patch.FullName
        $parentLeaf = Split-Path -Leaf $parent
        $candidateLeaf = $parentLeaf
        if ($candidateLeaf -ieq '_patches') {
            $candidateLeaf = Split-Path -Leaf (Split-Path -Parent $parent)
        }

        if ($candidateLeaf -match '^(m\d{2}_\d{2}_\d{4})-gparambnd-dcx$') {
            $binderLeaf = ($Matches[1] + '.gparambnd.dcx')
        }

        # Fallback from patch filename:
        #   m21_00_0000.gparam.xml.patch -> m21_00_0000.gparambnd.dcx
        if ([string]::IsNullOrWhiteSpace($binderLeaf)) {
            $name = $patch.Name
            if ($name -match '^(m\d{2}_\d{2}_\d{4})\.gparam\.xml\.patch$') {
                $binderLeaf = ($Matches[1] + '.gparambnd.dcx')
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($binderLeaf)) {
            [void]$expected.Add($binderLeaf)
        }
    }

    return @($expected.ToArray() | Sort-Object -Unique)
}


function Get-MapPatchCheckRows {
    param([Parameter(Mandatory)][string]$MapCode)

    $rows = New-Object System.Collections.ArrayList
    $diffRoot = Get-DiffRoot
    $gameRoot = $TxtGameRoot.Text.Trim()
    $outputRoot = Get-RequiredOutputRoot
    $short = Get-ShortMapCode -MapCode $MapCode
    $sPrefix = Get-SparamPrefixForMapCode -MapCode $MapCode

    function Add-CheckRow([string]$StepId,[string]$Name,[int]$Expected,[int]$Generated,[string]$Note) {
        [void]$rows.Add([pscustomobject]@{
            Step = [string]$StepId
            Name = [string]$Name
            Expected = [int]$Expected
            Generated = [int]$Generated
            Ok = [bool]($Generated -ge $Expected)
            Note = [string]$Note
        })
    }

    $expectedFlver = Count-MapFolderPatchFiles -MapCode $MapCode -Pattern '*.flver.patch'
    $generatedFlver = Count-MapFolderOutputFiles -OutputFolderName 'BBReborne_flver' -MapCode $MapCode -Pattern '*.flver.dcx'
    Add-CheckRow '01' 'FLVER' $expectedFlver $generatedFlver 'Expected from *.flver.patch files.'

    $expectedMsbFolders = @(Get-MapStudioExpectedFoldersForMapCode -MapCode $MapCode)
    $expectedMsb = $expectedMsbFolders.Count
    $generatedMsb = 0
    $outMsb = Join-Path (Join-Path (Join-Path $outputRoot 'BBReborne_map') 'map') 'mapstudio'
    foreach ($folder in $expectedMsbFolders) {
        if (Test-Path -LiteralPath (Join-Path $outMsb ($folder + '.msb.dcx')) -PathType Leaf) { $generatedMsb++ }
    }
    $msbNote = if ($expectedMsbFolders.Count -gt 0) {
        'Expected mapstudio outputs: ' + (($expectedMsbFolders | ForEach-Object { $_ + '.msb.dcx' }) -join ', ')
    } else {
        'No mapstudio patches detected for this map.'
    }
    Add-CheckRow '02' 'Map / MSB' $expectedMsb $generatedMsb $msbNote

    $expectedBtl = Count-MapFolderPatchFiles -MapCode $MapCode -Pattern '*.btl.patch'
    $generatedBtl = Count-MapFolderOutputFiles -OutputFolderName 'BBReborne_maplight' -MapCode $MapCode -Pattern '*.btl.dcx'
    Add-CheckRow '03' 'Maplight BTL' $expectedBtl $generatedBtl 'Expected from *.btl.patch files.'

    $expectedBtpb = Count-MapFolderPatchFiles -MapCode $MapCode -Pattern '*.btpb.patch'
    $generatedBtpb = Count-MapFolderOutputFiles -OutputFolderName 'BBReborne_maplight' -MapCode $MapCode -Pattern '*.btpb.dcx'
    Add-CheckRow '04' 'Maplight BTPB' $expectedBtpb $generatedBtpb 'Expected from *.btpb.patch files.'

    $drawparamPatchRoot = Join-Path (Join-Path $diffRoot 'param') 'drawparam'
    $expectedParamLeaves = @(Get-GparamExpectedBinderLeavesForMapCode -MapCode $MapCode)
    $expectedParam = $expectedParamLeaves.Count
    $paramOut = Join-Path (Join-Path (Join-Path $outputRoot 'BBReborne_param') 'param') 'drawparam'
    $generatedParam = 0
    foreach ($leaf in $expectedParamLeaves) {
        if (Test-Path -LiteralPath (Join-Path $paramOut $leaf) -PathType Leaf) { $generatedParam++ }
    }
    $paramNote = if ($expectedParamLeaves.Count -gt 0) {
        'Expected drawparam outputs: ' + ($expectedParamLeaves -join ', ')
    } else {
        'No mXX drawparam gparambnd patches detected for this map.'
    }
    Add-CheckRow '05' 'Param' $expectedParam $generatedParam $paramNote

    $expectedSparam = 0
    if (Test-Path -LiteralPath $drawparamPatchRoot -PathType Container) {
        $patchDirsToCheck = @()
        $directSparamPatchDir = Join-Path $drawparamPatchRoot '_patches'
        if (Test-Path -LiteralPath $directSparamPatchDir -PathType Container) { $patchDirsToCheck += $directSparamPatchDir }
        $patchDirsToCheck += $drawparamPatchRoot

        $expectedSparam = @(
            foreach ($pd in $patchDirsToCheck) {
                Get-ChildItem -LiteralPath $pd -File -Recurse -Filter '*.gparam.dcx.xml.patch' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name.StartsWith($sPrefix, [StringComparison]::OrdinalIgnoreCase) }
            }
        ) | Sort-Object FullName -Unique | Measure-Object | Select-Object -ExpandProperty Count
    }
    $sparamOut = Join-Path (Join-Path (Join-Path $outputRoot 'BBReborne_sparam') 'param') 'drawparam'
    $generatedSparam = Count-FilesSafe -Root $sparamOut -Filter ($sPrefix + '*.gparam.dcx')
    Add-CheckRow '06' 'Sparam' $expectedSparam $generatedSparam 'Expected from sXX_*.gparam.dcx.xml.patch files.'

    $expectedGi = 0
    if ([bool](Get-MapBackendOption -MapCode $MapCode -Name 'EnableGI' -DefaultValue $false) -and -not [string]::IsNullOrWhiteSpace($gameRoot)) {
        $giIn = Join-Path (Join-Path $gameRoot 'map') $short
        if (Test-Path -LiteralPath $giIn -PathType Container) {
            foreach ($archive in @(Get-ChildItem -LiteralPath $giIn -File -Filter ("gi_env_{0}*.tpfbdt" -f $short) -ErrorAction SilentlyContinue)) {
                $header = $archive.FullName -replace '\.tpfbdt$', '.tpfbhd'
                if (Test-Path -LiteralPath $header -PathType Leaf) { $expectedGi += 2 }
            }
        }
    }
    $giOut = Join-Path (Join-Path (Join-Path $outputRoot 'BBReborne_GI') 'map') $short
    $generatedGi = (Count-FilesSafe -Root $giOut -Filter ("gi_env_{0}*.tpfbdt" -f $short)) + (Count-FilesSafe -Root $giOut -Filter ("gi_env_{0}*.tpfbhd" -f $short))
    Add-CheckRow '07' 'GI' $expectedGi $generatedGi 'Expected from GI .tpfbdt/.tpfbhd input pairs when GI is enabled.'

    $expectedTextures = 0
    if (-not [string]::IsNullOrWhiteSpace($gameRoot)) {
        $texIn = Join-Path (Join-Path $gameRoot 'map') $short
        if (Test-Path -LiteralPath $texIn -PathType Container) {
            foreach ($archive in @(Get-ChildItem -LiteralPath $texIn -File -Filter ("{0}*.tpfbdt" -f $short) -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'gi_env_*' })) {
                $expectedTextures++
                $header = $archive.FullName -replace '\.tpfbdt$', '.tpfbhd'
                if (Test-Path -LiteralPath $header -PathType Leaf) { $expectedTextures++ }
            }
        }
    }
    $texOut = Join-Path (Join-Path (Join-Path $outputRoot 'BBReborne_textures') 'map') $short
    $generatedTextures = (Count-FilesSafe -Root $texOut -Filter ("{0}*.tpfbdt" -f $short)) + (Count-FilesSafe -Root $texOut -Filter ("{0}*.tpfbhd" -f $short))
    Add-CheckRow '08' 'Textures' $expectedTextures $generatedTextures 'Expected from texture .tpfbdt/.tpfbhd input files.'

    return @($rows.ToArray())
}

function Test-GeneratedFilesForScope {
    param(
        [Parameter(Mandatory)][string]$Scope,
        [AllowNull()][string]$MapCode
    )

    if ($Scope -eq 'Global') {
        return (Test-GlobalGeneratedFiles)
    }

    Ensure-ModOutputFolders
    $rows = @(Get-MapPatchCheckRows -MapCode $MapCode)
    $activeRows = @($rows | Where-Object { $_.Expected -gt 0 })
    $missingRows = @($activeRows | Where-Object { -not $_.Ok })

    $totalExpected = 0
    $totalGenerated = 0
    foreach ($row in $rows) {
        $totalExpected += [int]$row.Expected
        $totalGenerated += [int]$row.Generated
        $status = if ($row.Expected -eq 0) { 'skip' } elseif ($row.Ok) { 'ok' } else { 'missing' }
        Write-UiLog ("{0} check step {1} {2}: expected={3}, generated={4}, status={5}. {6}" -f $Scope, $row.Step, $row.Name, $row.Expected, $row.Generated, $status, $row.Note)
    }

    Write-UiLog ("{0} check total: expected={1}, generated={2}, missing steps={3}" -f $Scope, $totalExpected, $totalGenerated, $missingRows.Count)

    if ($activeRows.Count -eq 0) {
        Write-UiLog "$Scope check: no expected patch/texture/GI outputs could be inferred."
        return 'No expected files'
    }

    if ($missingRows.Count -gt 0) {
        $missingStepIds = (@($missingRows | ForEach-Object { [string]$_.Step }) -join ',')
        $missingStepNames = (@($missingRows | ForEach-Object { ("{0} {1}" -f $_.Step, $_.Name) }) -join '; ')
        Write-UiLog ("{0} check missing steps: {1}" -f $Scope, $missingStepNames)
        return ("Missing: {0} ({1}/{2})" -f $missingStepIds, ($activeRows.Count - $missingRows.Count), $activeRows.Count)
    }

    return ("Generated ({0})" -f $totalGenerated)
}

function Join-WindowsCommandLine {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $quoted = foreach ($arg in $Arguments) {
        if ($null -eq $arg) { '""'; continue }
        $text = [string]$arg
        if ($text -notmatch '[\s"]') {
            $text
            continue
        }

        '"' + ($text -replace '([\\]*)"', '$1$1\"' -replace '([\\]+)$', '$1$1') + '"'
    }

    return ($quoted -join ' ')
}

function Get-PwshForWorkflow {
    $pwsh = $null

    if ($RowControls.ContainsKey('PS7')) {
        $candidate = $RowControls['PS7'].Exe.Text.Trim()
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $pwsh = $candidate
        }
    }

    if (-not $pwsh) {
        $pwsh = Find-Pwsh7Exe
    }

    if (-not $pwsh) {
        throw 'PowerShell 7 / pwsh.exe was not found. Run Step 1 setup first.'
    }

    return $pwsh
}

function Find-LatestGlobalRunSummary {
    param([Parameter(Mandatory)][datetime]$StartedAfter)

    $globalLogRoot = Join-Path $TxtOutputRoot.Text.Trim() '_logs\global'
    if (-not (Test-Path -LiteralPath $globalLogRoot -PathType Container)) {
        return $null
    }

    $threshold = $StartedAfter.AddSeconds(-5)

    $summaries = @(
        Get-ChildItem -LiteralPath $globalLogRoot -Recurse -File -Filter 'global_run_summary.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $threshold } |
            Sort-Object LastWriteTime -Descending
    )

    if ($summaries.Count -eq 0) {
        return $null
    }

    return $summaries[0].FullName
}

function Read-GlobalRunSummary {
    param([Parameter(Mandatory)][string]$SummaryPath)

    if (-not (Test-Path -LiteralPath $SummaryPath -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $SummaryPath -Raw -ErrorAction Stop | ConvertFrom-Json)
    } catch {
        Write-UiLog "Could not parse global summary JSON: $($_.Exception.Message)"
        return $null
    }
}

function Start-VisibleGlobalPatchProcess {
    Ensure-ModOutputFolders

    $toolRoot = $TxtToolRoot.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($toolRoot)) {
        throw 'Tool root is empty.'
    }

    $toolPathsPs1 = Join-Path $toolRoot 'BBReborneDIYTool.paths.ps1'
    Save-PathFiles -Silent

    if (-not (Test-Path -LiteralPath $toolPathsPs1 -PathType Leaf)) {
        throw "Tool paths file was not created: $toolPathsPs1"
    }

    $runner = Join-Path $scriptRoot 'Scripts\Global\00_Run_Global_BBReborne_All.ps1'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
        throw "GLOBAL runner script not found: $runner"
    }

    $pwsh = Get-PwshForWorkflow

    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $runner,
        '-ToolPathsPs1', $toolPathsPs1,
        '-GameRoot', $TxtGameRoot.Text.Trim(),
        '-OutputRoot', $TxtOutputRoot.Text.Trim(),
        '-CpuThrottle', $TxtCpuThrottle.Text.Trim(),
        '-GpuThrottle', $TxtGpuThrottle.Text.Trim(),
        '-PwshExe', $pwsh
    )

    $argLine = Join-WindowsCommandLine -Arguments $argList

    Write-UiLog 'GLOBAL patches: launching visible PowerShell process.'
    Write-UiLog 'A separate PowerShell window will stay open while the global scripts run.'
    Write-UiLog 'Do not click other windows while WitchyBND is waiting for its menu input.'
    Write-UiLog "Runner: $runner"

    if ($MapRowControls.ContainsKey('GLOBAL')) {
        $MapRowControls['GLOBAL'].Status.Text = 'Running'
        $MapRowControls['GLOBAL'].Patch.IsEnabled = $false
    }

    $startedAt = Get-Date
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $proc = Start-Process `
        -FilePath $pwsh `
        -ArgumentList $argLine `
        -WindowStyle Normal `
        -PassThru

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Tag = [pscustomobject]@{
        Process   = $proc
        Stopwatch = $sw
        StartedAt = $startedAt
    }

    $timer.Add_Tick({
        param($sender, $eventArgs)

        $state = $sender.Tag
        $elapsedSeconds = $state.Stopwatch.Elapsed.TotalSeconds

        if ($MapRowControls.ContainsKey('GLOBAL')) {
            $MapRowControls['GLOBAL'].Elapsed.Text = (Format-ElapsedSeconds -Seconds $elapsedSeconds)
        }

        if (-not $state.Process.HasExited) {
            return
        }

        $sender.Stop()
        $state.Stopwatch.Stop()

        if ($MapRowControls.ContainsKey('GLOBAL')) {
            $MapRowControls['GLOBAL'].Patch.IsEnabled = $true
        }

        $exitCode = $state.Process.ExitCode
        Write-UiLog "GLOBAL patches: PowerShell process exited with code $exitCode."

        $summaryPath = Find-LatestGlobalRunSummary -StartedAfter $state.StartedAt
        $summary = $null

        if ($summaryPath) {
            Write-UiLog "GLOBAL summary: $summaryPath"
            $summary = Read-GlobalRunSummary -SummaryPath $summaryPath
        } else {
            Write-UiLog 'GLOBAL summary was not found. Using dashboard stopwatch elapsed time.'
        }

        if ($summary -and $summary.TotalElapsedSeconds) {
            $elapsedSeconds = [double]$summary.TotalElapsedSeconds
        }

        if ($summary) {
            Write-UiLog ("GLOBAL completed scripts: {0} / {1}" -f $summary.CompletedSteps, $summary.TotalSteps)
        }

        if ($summary -and $summary.Ok -eq $true) {
            Set-ScopeElapsed -ScopeCode 'GLOBAL' -Seconds $elapsedSeconds -Completed
            if ($MapRowControls.ContainsKey('GLOBAL')) {
                $MapRowControls['GLOBAL'].Status.Text = 'Completed'
            }
            Test-GeneratedFilesForScope -Scope 'Global' -MapCode $null | Out-Null
            return
        }

        $ScopeElapsedSeconds['GLOBAL'] = $elapsedSeconds
        if ($MapRowControls.ContainsKey('GLOBAL')) {
            $MapRowControls['GLOBAL'].Elapsed.Text = (Format-ElapsedSeconds -Seconds $elapsedSeconds)
            if ($exitCode -eq 0) {
                $MapRowControls['GLOBAL'].Status.Text = 'Finished / check files'
            } else {
                $MapRowControls['GLOBAL'].Status.Text = 'Failed'
            }
        }
        Update-ModTotals
    }.GetNewClosure())

    $timer.Start()
}

function Show-GlobalPatchFocusWarning {
    $message = @(
        'Global patches will open one or more PowerShell and external tool windows.',
        '',
        'Some tools receive automated keyboard input. While the process is running, do not click other windows, type, Alt-Tab, or change focus when a tool prompt is active.',
        '',
        'The UI will keep updating elapsed time. Wait for the global run to finish before using the computer again.'
    ) -join "`n"

    $result = [System.Windows.MessageBox]::Show(
        $Window,
        $message,
        'Before running Global patches',
        [System.Windows.MessageBoxButton]::OKCancel,
        [System.Windows.MessageBoxImage]::Warning
    )

    return ($result -eq [System.Windows.MessageBoxResult]::OK)
}

function Invoke-GlobalPatchStub {
    if (-not (Show-GlobalPatchFocusWarning)) {
        Write-UiLog 'GLOBAL patches: cancelled before launch.'
        return
    }

    Start-VisibleGlobalPatchProcess
}
$MapPatchBackend = @{
    M21 = @{ EnableGI = $false }
    M22 = @{ EnableGI = $false }
    M23 = @{ EnableGI = $false }
    M24 = @{ EnableGI = $false }
    M25 = @{ EnableGI = $false }
    M26 = @{ EnableGI = $false }
    M27 = @{ EnableGI = $false }
    M28 = @{ EnableGI = $false }
    M29 = @{ EnableGI = $false }
    M32 = @{ EnableGI = $true }
    M33 = @{ EnableGI = $false }
    M34 = @{ EnableGI = $false }
    M35 = @{ EnableGI = $false }
    M36 = @{ EnableGI = $false }
}

function Get-MapFoldersForMapCode {
    param([Parameter(Mandatory)][string]$MapCode)

    switch ($MapCode.ToUpperInvariant()) {
        'M21' { return @('m21_00_00_00','m21_01_00_00') }
        'M24' { return @('m24_00_00_00','m24_01_00_00','m24_02_00_00') }
        default {
            $clean = $MapCode.ToLowerInvariant()
            if ($clean -match '^m\d{2}$') { return @('{0}_00_00_00' -f $clean) }
            if ($clean -match '^m\d{2}_\d{2}_\d{2}_\d{2}$') { return @($clean) }
            throw "Unsupported map code: $MapCode"
        }
    }
}

function Get-ShortMapCode {
    param([Parameter(Mandatory)][string]$MapCode)

    $clean = $MapCode.ToLowerInvariant()
    if ($clean -match '^(m\d{2})') { return $Matches[1] }
    throw "Unsupported map code: $MapCode"
}

function Get-SparamPrefixForMapCode {
    param([Parameter(Mandatory)][string]$MapCode)

    $short = Get-ShortMapCode -MapCode $MapCode
    return ('s{0}_' -f $short.Substring(1,2))
}

function Get-MapBackendOption {
    param(
        [Parameter(Mandatory)][string]$MapCode,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$DefaultValue = $null
    )

    $key = $MapCode.ToUpperInvariant()
    if ($MapPatchBackend.ContainsKey($key) -and $MapPatchBackend[$key].ContainsKey($Name)) {
        return $MapPatchBackend[$key][$Name]
    }
    return $DefaultValue
}


function Get-MapFlverAvailability {
    param([Parameter(Mandatory)][string]$MapCode)

    $patchCount = Count-MapFolderPatchFiles -MapCode $MapCode -Pattern '*.flver.patch'
    $hasPatches = ([int]$patchCount -gt 0)
    $reason = ''
    if (-not $hasPatches) { $reason = 'No FLVER patches found for this map' }

    return [pscustomobject]@{
        # UI availability for step 01 follows the FLVER patch repository.
        # Missing original FLVER inputs are reported by Check files or by the step itself.
        Enabled    = [bool]$hasPatches
        HasPatches = [bool]$hasPatches
        PatchCount = [int]$patchCount
        Reason     = [string]$reason
    }
}

function Test-MapFlverPatchesAvailable {
    param([Parameter(Mandatory)][string]$MapCode)
    return [bool](Get-MapFlverAvailability -MapCode $MapCode).Enabled
}

function Get-MapMsbAvailability {
    param([Parameter(Mandatory)][string]$MapCode)

    $expectedFolders = @(Get-MapStudioExpectedFoldersForMapCode -MapCode $MapCode)
    $patchCount = [int]$expectedFolders.Count
    $hasPatches = ($patchCount -gt 0)
    $reason = ''
    if (-not $hasPatches) { $reason = 'No mapstudio/MSB patches found for this map' }

    return [pscustomobject]@{
        # UI availability for step 02 follows the mapstudio patch repository.
        # Missing original MSB inputs are reported by Check files or by the step itself.
        Enabled         = [bool]$hasPatches
        HasPatches      = [bool]$hasPatches
        PatchCount      = [int]$patchCount
        ExpectedTargets = @($expectedFolders)
        Reason          = [string]$reason
    }
}

function Test-MapMsbPatchesAvailable {
    param([Parameter(Mandatory)][string]$MapCode)
    return [bool](Get-MapMsbAvailability -MapCode $MapCode).Enabled
}

function Get-MapBtlAvailability {
    param([Parameter(Mandatory)][string]$MapCode)

    $patchCount = Count-MapFolderPatchFiles -MapCode $MapCode -Pattern '*.btl.patch'
    $hasPatches = ([int]$patchCount -gt 0)
    $reason = ''
    if (-not $hasPatches) { $reason = 'No BTL patches found for this map' }

    return [pscustomobject]@{
        # UI availability for step 03 follows the BTL patch repository.
        # Missing original BTL inputs are reported by Check files or by the step itself.
        Enabled    = [bool]$hasPatches
        HasPatches = [bool]$hasPatches
        PatchCount = [int]$patchCount
        Reason     = [string]$reason
    }
}

function Test-MapBtlPatchesAvailable {
    param([Parameter(Mandatory)][string]$MapCode)
    return [bool](Get-MapBtlAvailability -MapCode $MapCode).Enabled
}

function Get-MapBtpbAvailability {
    param([Parameter(Mandatory)][string]$MapCode)

    $diffRoot = Get-DiffRoot
    $gameRoot = $TxtGameRoot.Text.Trim()

    $patchHits = @()
    $inputHits = @()

    foreach ($folder in @(Get-MapFoldersForMapCode -MapCode $MapCode)) {
        $patchDir = Join-Path (Join-Path (Join-Path $diffRoot 'map') $folder) '_patches'
        if (Test-Path -LiteralPath $patchDir -PathType Container) {
            $patchHits += @(Get-ChildItem -LiteralPath $patchDir -File -Filter '*.btpb.patch' -ErrorAction SilentlyContinue)
        }

        if (-not [string]::IsNullOrWhiteSpace($gameRoot)) {
            $inputDir = Join-Path (Join-Path $gameRoot 'map') $folder
            if (Test-Path -LiteralPath $inputDir -PathType Container) {
                $inputHits += @(Get-ChildItem -LiteralPath $inputDir -File -Filter '*.btpb.dcx' -ErrorAction SilentlyContinue)
            }
        }
    }

    $hasPatches = ($patchHits.Count -gt 0)
    $hasInputs  = ($inputHits.Count -gt 0)
    $reason = ''
    if (-not $hasPatches) { $reason = 'No BTPB patches found for this map' }
    elseif (-not $hasInputs) { $reason = 'BTPB patches found; matching input check is deferred to the step/check-files output' }

    return [pscustomobject]@{
        # UI availability for step 04 follows the BTPB diff repository.
        # Missing inputs are reported by Check files or by the step itself, not by greying out the box.
        Enabled    = [bool]$hasPatches
        HasPatches = [bool]$hasPatches
        HasInputs  = [bool]$hasInputs
        Reason     = [string]$reason
    }
}

function Test-MapBtpbPatchesAvailable {
    param([Parameter(Mandatory)][string]$MapCode)
    return [bool](Get-MapBtpbAvailability -MapCode $MapCode).Enabled
}

function Get-MapSparamAvailability {
    param([Parameter(Mandatory)][string]$MapCode)

    $diffRoot = Get-DiffRoot
    $drawparamPatchRoot = Join-Path (Join-Path $diffRoot 'param') 'drawparam'
    $gameRoot = $TxtGameRoot.Text.Trim()
    $drawparamInputRoot = if (-not [string]::IsNullOrWhiteSpace($gameRoot)) { Join-Path (Join-Path $gameRoot 'param') 'drawparam' } else { '' }

    $prefix = Get-SparamPrefixForMapCode -MapCode $MapCode

    # Keep these as explicit ArrayLists. Some PowerShell pipelines collapse to a
    # scalar object when exactly one file is found, and WPF then surfaces the
    # confusing "The property 'Count' cannot be found" error during row setup.
    $patchHitsList = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $drawparamPatchRoot -PathType Container) {
        $patchDirsToCheck = New-Object System.Collections.ArrayList
        $directSparamPatchDir = Join-Path $drawparamPatchRoot '_patches'
        if (Test-Path -LiteralPath $directSparamPatchDir -PathType Container) { [void]$patchDirsToCheck.Add($directSparamPatchDir) }
        [void]$patchDirsToCheck.Add($drawparamPatchRoot)

        foreach ($pd in @($patchDirsToCheck.ToArray() | Sort-Object -Unique)) {
            $hits = @(Get-ChildItem -LiteralPath $pd -File -Recurse -Filter '*.gparam.dcx.xml.patch' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
            foreach ($hit in $hits) { [void]$patchHitsList.Add($hit) }
        }
    }

    $patchHits = @($patchHitsList.ToArray() | Sort-Object FullName -Unique)

    $inputHits = @()
    if (-not [string]::IsNullOrWhiteSpace($drawparamInputRoot) -and (Test-Path -LiteralPath $drawparamInputRoot -PathType Container)) {
        $inputHits = @(Get-ChildItem -LiteralPath $drawparamInputRoot -File -Filter ($prefix + '*.gparam.dcx') -ErrorAction SilentlyContinue)
    }

    $hasPatches = (@($patchHits).Count -gt 0)
    $hasInputs  = (@($inputHits).Count -gt 0)
    $reason = ''
    if (-not $hasPatches) { $reason = 'No Sparam patches found for this map' }
    elseif (-not $hasInputs) { $reason = 'Sparam patches found; matching input check is deferred to the step/check-files output' }

    return [pscustomobject]@{
        # UI availability for step 06 follows the Sparam patch repository.
        # Sparam patches live in Diffs\param\drawparam\_patches because the source files are loose.
        Enabled    = [bool]$hasPatches
        HasPatches = [bool]$hasPatches
        HasInputs  = [bool]$hasInputs
        PatchCount = [int]@($patchHits).Count
        InputCount = [int]@($inputHits).Count
        Reason     = [string]$reason
    }
}

function Test-MapSparamPatchesAvailable {
    param([Parameter(Mandatory)][string]$MapCode)
    return [bool](Get-MapSparamAvailability -MapCode $MapCode).Enabled
}

function Test-MapGiInputsAvailable {
    param([Parameter(Mandatory)][string]$MapCode)

    $gameRoot = $TxtGameRoot.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($gameRoot)) { return $false }

    $short = Get-ShortMapCode -MapCode $MapCode
    $giDir = Join-Path (Join-Path $gameRoot 'map') $short
    if (-not (Test-Path -LiteralPath $giDir -PathType Container)) { return $false }

    $archives = @(Get-ChildItem -LiteralPath $giDir -File -Filter ("gi_env_{0}*.tpfbdt" -f $short) -ErrorAction SilentlyContinue)
    if ($archives.Count -eq 0) { return $false }

    foreach ($archive in $archives) {
        $header = $archive.FullName -replace '\.tpfbdt$', '.tpfbhd'
        if (Test-Path -LiteralPath $header -PathType Leaf) { return $true }
    }
    return $false
}

function New-MapStepDefinition {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Script,
        [bool]$Enabled = $true,
        [string]$Reason = ''
    )

    return [pscustomobject]@{
        Id      = [string]$Id
        Name    = [string]$Name
        Script  = [string]$Script
        Enabled = [bool]$Enabled
        Reason  = [string]$Reason
    }
}

function Get-MapStepDefinitions {
    param([Parameter(Mandatory)][string]$MapCode)

    $mapCodeText = [string]$MapCode
    $mapScriptsRoot = Join-Path (Join-Path $scriptRoot 'Scripts') 'Mapfiles'

    $flverAvailability = Get-MapFlverAvailability -MapCode $mapCodeText
    $hasFlver = [bool]$flverAvailability.Enabled
    $flverReason = [string]$flverAvailability.Reason

    $msbAvailability = Get-MapMsbAvailability -MapCode $mapCodeText
    $hasMsb = [bool]$msbAvailability.Enabled
    $msbReason = [string]$msbAvailability.Reason

    $btlAvailability = Get-MapBtlAvailability -MapCode $mapCodeText
    $hasBtl = [bool]$btlAvailability.Enabled
    $btlReason = [string]$btlAvailability.Reason

    $btpbAvailability = Get-MapBtpbAvailability -MapCode $mapCodeText
    $hasBtpb = [bool]$btpbAvailability.Enabled
    $btpbReason = [string]$btpbAvailability.Reason

    $sparamAvailability = Get-MapSparamAvailability -MapCode $mapCodeText
    $hasSparam = [bool]$sparamAvailability.Enabled
    $sparamReason = [string]$sparamAvailability.Reason

    $enableGI = [bool](Get-MapBackendOption -MapCode $mapCodeText -Name 'EnableGI' -DefaultValue $false)
    $hasGiInputs = [bool](Test-MapGiInputsAvailable -MapCode $mapCodeText)
    # UI availability for step 07 follows only the backend EnableGI flag.
    # Missing GI input files are reported by Check files or by the step itself.
    $giEnabled = [bool]$enableGI
    $giReason = ''
    if (-not $enableGI) { $giReason = 'GI disabled in $MapPatchBackend' }
    elseif (-not $hasGiInputs) { $giReason = 'GI enabled in backend; no GI .tpfbdt/.tpfbhd input pair found yet' }

    # Keep this as a plain PowerShell object array. Do not use a .NET generic List here;
    # WPF/event marshalling can surface a vague "Argument types do not match" error
    # when the generic collection is returned through this button path.
    $steps = @(
        (New-MapStepDefinition -Id '01' -Name 'FLVER'        -Script (Join-Path $mapScriptsRoot '01_Mapfiles_BBReborne_FLVER.ps1')                -Enabled $hasFlver -Reason $flverReason),
        (New-MapStepDefinition -Id '02' -Name 'Map / MSB'    -Script (Join-Path $mapScriptsRoot '02_Mapfiles_BBReborne_Map.ps1')                  -Enabled $hasMsb -Reason $msbReason),
        (New-MapStepDefinition -Id '03' -Name 'Maplight BTL' -Script (Join-Path $mapScriptsRoot '03_Mapfiles_BBReborne_Maplight_BTL.ps1')         -Enabled $hasBtl -Reason $btlReason),
        (New-MapStepDefinition -Id '04' -Name 'Maplight BTPB' -Script (Join-Path $mapScriptsRoot '04_Mapfiles_BBReborne_Maplight_BTPB.ps1')        -Enabled $hasBtpb -Reason $btpbReason),
        (New-MapStepDefinition -Id '05' -Name 'Param'        -Script (Join-Path $mapScriptsRoot '05_Mapfiles_BBReborne_Param.ps1')                -Enabled $true  -Reason ''),
        (New-MapStepDefinition -Id '06' -Name 'Sparam'       -Script (Join-Path $mapScriptsRoot '06_Mapfiles_BBReborne_Sparam.ps1')               -Enabled $hasSparam -Reason $sparamReason),
        (New-MapStepDefinition -Id '07' -Name 'GI'           -Script (Join-Path $mapScriptsRoot '07_Mapfiles_BBReborne_GI.ps1')                   -Enabled $giEnabled -Reason $giReason),
        (New-MapStepDefinition -Id '08' -Name 'Textures'     -Script (Join-Path $mapScriptsRoot '08_Mapfiles_BBReborne_Textures.ps1')             -Enabled $true  -Reason '')
    )

    return $steps
}


function Get-MapStepCheckboxSelected {
    param(
        [Parameter(Mandatory)][string]$MapCode,
        [Parameter(Mandatory)][string]$StepId
    )

    if ($MapStepCheckControls.ContainsKey($MapCode)) {
        $byStep = $MapStepCheckControls[$MapCode]
        if ($byStep -and $byStep.ContainsKey($StepId)) {
            return ([bool]$byStep[$StepId].IsChecked)
        }
    }
    return $true
}

function Get-EffectiveMapSteps {
    param([Parameter(Mandatory)][string]$MapCode)

    # Build plain PowerShell arrays only. Do not use .NET generic lists or a
    # PSCustomObject with generic list values here: this path is called from WPF
    # button events and can otherwise surface the vague "Argument types do not match".
    $allSteps = @()
    foreach ($step in @(Get-MapStepDefinitions -MapCode ([string]$MapCode))) {
        $allSteps += $step
    }

    $enabledSteps = @()
    $skippedSteps = @()

    foreach ($step in $allSteps) {
        $stepId = [string]$step.Id
        $stepName = [string]$step.Name
        $stepScript = [string]$step.Script

        if ([bool]$step.Enabled -ne $true) {
            $skippedSteps += (New-MapStepDefinition -Id $stepId -Name $stepName -Script $stepScript -Enabled $false -Reason ([string]$step.Reason))
            continue
        }

        if (-not (Get-MapStepCheckboxSelected -MapCode ([string]$MapCode) -StepId $stepId)) {
            $skippedSteps += (New-MapStepDefinition -Id $stepId -Name $stepName -Script $stepScript -Enabled $false -Reason 'Unchecked in UI')
            continue
        }

        $enabledSteps += (New-MapStepDefinition -Id $stepId -Name $stepName -Script $stepScript -Enabled $true -Reason '')
    }

    return @{
        All     = @($allSteps)
        Enabled = @($enabledSteps)
        Skipped = @($skippedSteps)
    }
}

function Refresh-MapStepCheckboxAvailability {
    foreach ($map in $Maps) {
        $mapCode = [string]$map.Code
        if (-not $MapStepCheckControls.ContainsKey($mapCode)) { continue }

        $steps = @(Get-MapStepDefinitions -MapCode $mapCode)
        foreach ($step in $steps) {
            $stepId = [string]$step.Id
            if (-not $MapStepCheckControls[$mapCode].ContainsKey($stepId)) { continue }

            $cb = $MapStepCheckControls[$mapCode][$stepId]
            $cb.IsEnabled = [bool]$step.Enabled
            if (-not $step.Enabled) {
                $cb.IsChecked = $false
                $cb.Opacity = 0.35
                $cb.ToolTip = ("{0} {1}: {2}" -f $step.Id, $step.Name, $step.Reason)
            }
            else {
                $cb.Opacity = 1.0
                if ($null -eq $cb.IsChecked) { $cb.IsChecked = $true }
                $cb.ToolTip = ("{0} {1}" -f $step.Id, $step.Name)
            }
        }
    }

    Update-MapStepBulkCheckboxState
}

function New-MapRunnerScript {
    param(
        [Parameter(Mandatory)][string]$MapCode,
        [Parameter(Mandatory)][object[]]$EnabledSteps,
        $SkippedSteps = @(),
        [Parameter(Mandatory)][string]$RunnerPath,
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$ToolPathsPs1,
        [Parameter(Mandatory)][string]$PwshExe
    )

    $gameRoot = $TxtGameRoot.Text.Trim()
    $outputRoot = $TxtOutputRoot.Text.Trim()
    $cpuThrottle = $TxtCpuThrottle.Text.Trim()
    $gpuThrottle = $TxtGpuThrottle.Text.Trim()
    $noUpscaleTextures = ([bool]$ChkNoUpscaleTextures.IsChecked)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('$ErrorActionPreference = ''Stop''')
    $lines.Add('$global:PSNativeCommandUseErrorActionPreference = $false')
    $lines.Add('$MapCode = ' + (Quote-PSString $MapCode))
    $lines.Add('$PwshExe = ' + (Quote-PSString $PwshExe))
    $lines.Add('$SummaryPath = ' + (Quote-PSString $SummaryPath))
    $lines.Add('$steps = @(')

    foreach ($step in $EnabledSteps) {
        $args = @(
            '-ToolPathsPs1', $ToolPathsPs1,
            '-GameRoot', $gameRoot,
            '-OutputRoot', $outputRoot,
            '-MapCode', $MapCode
        )

        # Do not pass one common throttle parameter to every step.
        # 05 Param and 06 Sparam intentionally do not declare -CpuThrottle.
        if (@('01','02','03','04','07','08') -contains ([string]$step.Id)) {
            $args += @('-CpuThrottle', $cpuThrottle)
        }

        if (@('05','06') -contains ([string]$step.Id)) {
            $args += @('-LogDir', (Split-Path -Parent $SummaryPath))
        }

        if ($step.Id -eq '08') {
            $args += @('-GpuThrottle', $gpuThrottle)
            if ($noUpscaleTextures) {
                $args += '-NoUpscale'
            }
        }

        $argText = (($args | ForEach-Object { Quote-PSString ([string]$_) }) -join ', ')
        $lines.Add(('    [pscustomobject]@{{ Id={0}; Name={1}; Script={2}; Args=@({3}) }}' -f (Quote-PSString $step.Id), (Quote-PSString $step.Name), (Quote-PSString $step.Script), $argText))
    }

    $lines.Add(')')
    $lines.Add('$skippedSteps = @(')

    foreach ($step in @($SkippedSteps)) {
        $lines.Add(('    [pscustomobject]@{{ Id={0}; Name={1}; Reason={2} }}' -f (Quote-PSString ([string]$step.Id)), (Quote-PSString ([string]$step.Name)), (Quote-PSString ([string]$step.Reason))))
    }

    $lines.Add(')')
    $lines.Add('$timer = [Diagnostics.Stopwatch]::StartNew()')
    $lines.Add('$completed = 0')
    $lines.Add('$ok = $false')
    $lines.Add('$exitCode = 0')
    $lines.Add('$failedStepId = [string]::Empty')
    $lines.Add('$failedStepName = [string]::Empty')
    $lines.Add('$failedMessage = [string]::Empty')
    $lines.Add('$failedStack = [string]::Empty')
    $lines.Add('$transcriptPath = Join-Path (Split-Path -Parent $SummaryPath) ''runner_transcript.txt''')
    $lines.Add('New-Item -ItemType Directory -Path (Split-Path -Parent $SummaryPath) -Force | Out-Null')
    $lines.Add('try { Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null } catch { Write-Host "Could not start transcript: $($_.Exception.Message)" -ForegroundColor Yellow }')
    $lines.Add('try {')
    $lines.Add('    Write-Host ""')
    $lines.Add('    Write-Host ("BBReborne map patch run: {0}" -f $MapCode) -ForegroundColor Green')
    $lines.Add('    if (@($skippedSteps).Count -gt 0) {')
    $lines.Add('        Write-Host "Skipped steps:" -ForegroundColor DarkYellow')
    $lines.Add('        foreach ($skip in $skippedSteps) { Write-Host ("  SKIP {0} {1}: {2}" -f $skip.Id, $skip.Name, $skip.Reason) -ForegroundColor DarkYellow }')
    $lines.Add('    } else {')
    $lines.Add('        Write-Host "Skipped steps: none" -ForegroundColor DarkGray')
    $lines.Add('    }')
    $lines.Add('    foreach ($step in $steps) {')
    $lines.Add('        $failedStepId = [string]$step.Id')
    $lines.Add('        $failedStepName = [string]$step.Name')
    $lines.Add('        Write-Host ""')
    $lines.Add('        Write-Host ("===== Step {0}: {1} =====" -f $step.Id, $step.Name) -ForegroundColor Cyan')
    $lines.Add('        if (-not (Test-Path -LiteralPath $step.Script -PathType Leaf)) { throw "Step script not found: $($step.Script)" }')
    $lines.Add('        & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $step.Script @($step.Args)')
    $lines.Add('        $native = $LASTEXITCODE')
    $lines.Add('        if ($native -ne 0) { throw "Step $($step.Id) $($step.Name) failed with exit code $native" }')
    $lines.Add('        $completed++')
    $lines.Add('    }')
    $lines.Add('    $ok = $true')
    $lines.Add('$failedStepId = [string]::Empty')
    $lines.Add('$failedStepName = [string]::Empty')
    $lines.Add('}')
    $lines.Add('catch {')
    $lines.Add('    $exitCode = 1')
    $lines.Add('    $failedMessage = $_.Exception.Message')
    $lines.Add('    if ($_.ScriptStackTrace) { $failedStack = $_.ScriptStackTrace }')
    $lines.Add('    Write-Host ""')
    $lines.Add('    Write-Host "MAP RUN FAILED" -ForegroundColor Red')
    $lines.Add('    Write-Host ("Failed step: {0} {1}" -f $failedStepId, $failedStepName) -ForegroundColor Red')
    $lines.Add('    Write-Host $failedMessage -ForegroundColor Red')
    $lines.Add('    if ($failedStack) { Write-Host ""; Write-Host "Stack:" -ForegroundColor Red; Write-Host $failedStack -ForegroundColor Red }')
    $lines.Add('}')
    $lines.Add('finally {')
    $lines.Add('    $timer.Stop()')
    $lines.Add('    $summary = [ordered]@{')
    $lines.Add('        MapCode = $MapCode')
    $lines.Add('        Ok = $ok')
    $lines.Add('        ExitCode = $exitCode')
    $lines.Add('        CompletedSteps = $completed')
    $lines.Add('        TotalSteps = @($steps).Count')
    $lines.Add('        SkippedStepIds = @($skippedSteps | ForEach-Object { [string]$_.Id })')
    $lines.Add('        SkippedSteps = @($skippedSteps)')
    $lines.Add('        FailedStepId = $failedStepId')
    $lines.Add('        FailedStepName = $failedStepName')
    $lines.Add('        FailedMessage = $failedMessage')
    $lines.Add('        TranscriptPath = $transcriptPath')
    $lines.Add('        TotalElapsedSeconds = $timer.Elapsed.TotalSeconds')
    $lines.Add('    }')
    $lines.Add('    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8')
    $lines.Add('    Write-Host ""')
    $lines.Add('    Write-Host ("Summary: {0}" -f $SummaryPath) -ForegroundColor Yellow')
    $lines.Add('    Write-Host ("Transcript: {0}" -f $transcriptPath) -ForegroundColor Yellow')
    $lines.Add('    try { Stop-Transcript | Out-Null } catch {}')
    $lines.Add('    if (-not $ok) {')
    $lines.Add('        Write-Host ""')
    $lines.Add('        Read-Host "Press ENTER to close this failed map run window"')
    $lines.Add('    }')
    $lines.Add('}')
    $lines.Add('exit $exitCode')
    New-Item -ItemType Directory -Path (Split-Path -Parent $RunnerPath) -Force | Out-Null
    Set-Content -LiteralPath $RunnerPath -Value $lines -Encoding UTF8
}

function Read-MapRunSummary {
    param([Parameter(Mandatory)][string]$SummaryPath)

    if (-not (Test-Path -LiteralPath $SummaryPath -PathType Leaf)) { return $null }
    try {
        return (Get-Content -LiteralPath $SummaryPath -Raw -ErrorAction Stop | ConvertFrom-Json)
    } catch {
        Write-UiLog "Could not parse map summary JSON: $($_.Exception.Message)"
        return $null
    }
}

function Show-MapPatchFocusWarning {
    param(
        [Parameter(Mandatory)][string]$MapCode,
        [Parameter(Mandatory)][object[]]$Steps,
        [Parameter(Mandatory)][object[]]$SkippedSteps
    )

    $stepLines = @($Steps | ForEach-Object { "  $($_.Id) $($_.Name)" })
    if ($stepLines.Count -eq 0) { $stepLines = @('  none') }
    $skipLines = @($SkippedSteps | ForEach-Object { "  SKIP $($_.Id) $($_.Name): $($_.Reason)" })

    $message = @(
        "Map $MapCode will run these patch steps:",
        ($stepLines -join "`n"),
        '',
        $(if ($skipLines.Count -gt 0) { "Skipped:`n$($skipLines -join "`n")" } else { 'No backend/input skips for this map.' }),
        '',
        'A visible PowerShell window will open. Avoid using the computer while WitchyBND prompts or GPU texture steps are active.'
    ) -join "`n"

    $result = [System.Windows.MessageBox]::Show(
        $message,
        "Before running $MapCode patches",
        [System.Windows.MessageBoxButton]::OKCancel,
        [System.Windows.MessageBoxImage]::Warning
    )

    return ($result -eq [System.Windows.MessageBoxResult]::OK)
}

function Start-VisibleMapPatchProcess {
    param([Parameter(Mandatory)][string]$MapCode)

    Ensure-ModOutputFolders
    Save-PathFiles -Silent

    $toolRoot = $TxtToolRoot.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($toolRoot)) { throw 'Tool root is empty.' }

    $toolPathsPs1 = Join-Path $toolRoot 'BBReborneDIYTool.paths.ps1'
    if (-not (Test-Path -LiteralPath $toolPathsPs1 -PathType Leaf)) {
        throw "Tool paths file was not created: $toolPathsPs1"
    }

    $pwsh = Get-PwshForWorkflow

    Refresh-MapStepCheckboxAvailability
    $stepSelection = Get-EffectiveMapSteps -MapCode $MapCode
    $enabledSteps = @($stepSelection.Enabled)
    $skippedSteps = @($stepSelection.Skipped)

    if ($enabledSteps.Count -eq 0) {
        Write-UiLog "$MapCode patches: no enabled steps after backend/input filtering."
        return
    }

    foreach ($s in $skippedSteps) {
        Write-UiLog "$MapCode patches: skipping $($s.Id) $($s.Name): $($s.Reason)"
    }

    if (-not (Show-MapPatchFocusWarning -MapCode $MapCode -Steps $enabledSteps -SkippedSteps $skippedSteps)) {
        Write-UiLog "$MapCode patches: cancelled before launch."
        return
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $mapLogRoot = Join-Path (Join-Path (Join-Path $TxtOutputRoot.Text.Trim() '_logs') 'maps') $MapCode
    $runDir = Join-Path $mapLogRoot $stamp
    $runner = Join-Path $runDir ("run_{0}.ps1" -f $MapCode)
    $summaryPath = Join-Path $runDir 'map_run_summary.json'

    New-MapRunnerScript -MapCode $MapCode -EnabledSteps $enabledSteps -SkippedSteps $skippedSteps -RunnerPath $runner -SummaryPath $summaryPath -ToolPathsPs1 $toolPathsPs1 -PwshExe $pwsh

    if ([bool]$ChkNoUpscaleTextures.IsChecked) {
        Write-UiLog "$MapCode patches: texture step will use -NoUpscale."
    }

    Write-UiLog "$MapCode patches: launching visible PowerShell process."
    Write-UiLog "Runner: $runner"
    Write-UiLog "Summary: $summaryPath"

    if ($MapRowControls.ContainsKey($MapCode)) {
        $MapRowControls[$MapCode].Status.Text = 'Running'
        $MapRowControls[$MapCode].Patch.IsEnabled = $false
    }

    $argList = [string[]]@(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $runner
    )
    $argLine = Join-WindowsCommandLine -Arguments $argList

    $startedAt = Get-Date
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $pwsh -ArgumentList $argLine -WindowStyle Normal -PassThru

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Tag = [pscustomobject]@{
        Process     = $proc
        Stopwatch   = $sw
        StartedAt   = $startedAt
        MapCode     = $MapCode
        SummaryPath = $summaryPath
    }

    $timer.Add_Tick({
        param($sender, $eventArgs)

        $state = $sender.Tag
        $scopeCode = [string]$state.MapCode
        $elapsedSeconds = [double]$state.Stopwatch.Elapsed.TotalSeconds

        if ($MapRowControls.ContainsKey($scopeCode)) {
            $MapRowControls[$scopeCode].Elapsed.Text = (Format-ElapsedSeconds -Seconds $elapsedSeconds)
        }

        if (-not $state.Process.HasExited) { return }

        $sender.Stop()
        $state.Stopwatch.Stop()

        if ($MapRowControls.ContainsKey($scopeCode)) {
            $MapRowControls[$scopeCode].Patch.IsEnabled = $true
        }

        $exitCode = $state.Process.ExitCode
        Write-UiLog "$scopeCode patches: PowerShell process exited with code $exitCode."

        $summary = Read-MapRunSummary -SummaryPath $state.SummaryPath
        if ($summary -and $summary.TotalElapsedSeconds) {
            $elapsedSeconds = [double]$summary.TotalElapsedSeconds
        }

        if ($summary) {
            Write-UiLog ("$scopeCode completed scripts: {0} / {1}" -f $summary.CompletedSteps, $summary.TotalSteps)
            if ($summary.FailedStepId) {
                Write-UiLog ("$scopeCode failed at step {0} {1}: {2}" -f $summary.FailedStepId, $summary.FailedStepName, $summary.FailedMessage)
            }
            if ($summary.TranscriptPath) {
                Write-UiLog ("$scopeCode transcript: {0}" -f $summary.TranscriptPath)
            }
        }

        if ($summary -and $summary.Ok -eq $true) {
            Set-ScopeElapsed -ScopeCode $scopeCode -Seconds $elapsedSeconds -Completed
            if ($MapRowControls.ContainsKey($scopeCode)) { $MapRowControls[$scopeCode].Status.Text = 'Completed' }
            Test-GeneratedFilesForScope -Scope $scopeCode -MapCode $scopeCode | Out-Null
            return
        }

        $ScopeElapsedSeconds[$scopeCode] = $elapsedSeconds
        if ($MapRowControls.ContainsKey($scopeCode)) {
            $MapRowControls[$scopeCode].Elapsed.Text = (Format-ElapsedSeconds -Seconds $elapsedSeconds)
            if ($exitCode -eq 0) { $MapRowControls[$scopeCode].Status.Text = 'Finished / check files' }
            else { $MapRowControls[$scopeCode].Status.Text = 'Failed' }
        }
        Update-ModTotals
    }.GetNewClosure())

    $timer.Start()
}


function New-AllMapRunnerScript {
    param(
        [Parameter(Mandatory)][object[]]$MapRuns,
        [Parameter(Mandatory)][string]$RunnerPath,
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$PwshExe
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('$ErrorActionPreference = ''Stop''')
    $lines.Add('$global:PSNativeCommandUseErrorActionPreference = $false')
    $lines.Add('$PwshExe = ' + (Quote-PSString $PwshExe))
    $lines.Add('$SummaryPath = ' + (Quote-PSString $SummaryPath))
    $lines.Add('$mapRuns = @(')
    foreach ($run in $MapRuns) {
        $lines.Add(('    [pscustomobject]@{{ MapCode={0}; Runner={1}; Summary={2}; SkippedStepIds={3}; SkippedStepText={4} }}' -f (Quote-PSString ([string]$run.MapCode)), (Quote-PSString ([string]$run.Runner)), (Quote-PSString ([string]$run.Summary)), (Quote-PSString ([string]$run.SkippedStepIds)), (Quote-PSString ([string]$run.SkippedStepText))))
    }
    $lines.Add(')')
    $lines.Add('$timer = [Diagnostics.Stopwatch]::StartNew()')
    $lines.Add('$completed = 0')
    $lines.Add('$ok = $false')
    $lines.Add('$exitCode = 0')
    $lines.Add('$failedMapCode = [string]::Empty')
    $lines.Add('$failedMessage = [string]::Empty')
    $lines.Add('$failedStack = [string]::Empty')
    $lines.Add('$transcriptPath = Join-Path (Split-Path -Parent $SummaryPath) ''all_maps_transcript.txt''')
    $lines.Add('New-Item -ItemType Directory -Path (Split-Path -Parent $SummaryPath) -Force | Out-Null')
    $lines.Add('try { Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null } catch { Write-Host "Could not start transcript: $($_.Exception.Message)" -ForegroundColor Yellow }')
    $lines.Add('try {')
    $lines.Add('    Write-Host ""')
    $lines.Add('    Write-Host "BBReborne run all map patches" -ForegroundColor Green')
    $lines.Add('    foreach ($run in $mapRuns) {')
    $lines.Add('        $failedMapCode = [string]$run.MapCode')
    $lines.Add('        Write-Host ""')
    $lines.Add('        Write-Host ("##################################################") -ForegroundColor DarkYellow')
    $lines.Add('        Write-Host ("Starting map: {0}" -f $run.MapCode) -ForegroundColor DarkYellow')
    $lines.Add('        if (-not [string]::IsNullOrWhiteSpace([string]$run.SkippedStepIds)) { Write-Host ("Skipped steps for {0}: {1}" -f $run.MapCode, $run.SkippedStepIds) -ForegroundColor DarkYellow }')
    $lines.Add('        Write-Host ("##################################################") -ForegroundColor DarkYellow')
    $lines.Add('        if (-not (Test-Path -LiteralPath $run.Runner -PathType Leaf)) { throw "Map runner not found: $($run.Runner)" }')
    $lines.Add('        & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $run.Runner')
    $lines.Add('        $native = $LASTEXITCODE')
    $lines.Add('        if ($native -ne 0) { throw "Map $($run.MapCode) failed with exit code $native" }')
    $lines.Add('        $completed++')
    $lines.Add('    }')
    $lines.Add('    $ok = $true')
    $lines.Add('    $failedMapCode = [string]::Empty')
    $lines.Add('}')
    $lines.Add('catch {')
    $lines.Add('    $exitCode = 1')
    $lines.Add('    $failedMessage = $_.Exception.Message')
    $lines.Add('    if ($_.ScriptStackTrace) { $failedStack = $_.ScriptStackTrace }')
    $lines.Add('    Write-Host ""')
    $lines.Add('    Write-Host "RUN ALL MAP PATCHES FAILED" -ForegroundColor Red')
    $lines.Add('    Write-Host ("Failed map: {0}" -f $failedMapCode) -ForegroundColor Red')
    $lines.Add('    Write-Host $failedMessage -ForegroundColor Red')
    $lines.Add('    if ($failedStack) { Write-Host ""; Write-Host "Stack:" -ForegroundColor Red; Write-Host $failedStack -ForegroundColor Red }')
    $lines.Add('}')
    $lines.Add('finally {')
    $lines.Add('    $timer.Stop()')
    $lines.Add('    $summary = [ordered]@{')
    $lines.Add('        Ok = $ok')
    $lines.Add('        ExitCode = $exitCode')
    $lines.Add('        CompletedMaps = $completed')
    $lines.Add('        TotalMaps = @($mapRuns).Count')
    $lines.Add('        FailedMapCode = $failedMapCode')
    $lines.Add('        FailedMessage = $failedMessage')
    $lines.Add('        TranscriptPath = $transcriptPath')
    $lines.Add('        TotalElapsedSeconds = $timer.Elapsed.TotalSeconds')
    $lines.Add('        MapSummaries = @($mapRuns | ForEach-Object { $_.Summary })')
    $lines.Add('    }')
    $lines.Add('    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8')
    $lines.Add('    Write-Host ""')
    $lines.Add('    Write-Host ("Summary: {0}" -f $SummaryPath) -ForegroundColor Yellow')
    $lines.Add('    Write-Host ("Transcript: {0}" -f $transcriptPath) -ForegroundColor Yellow')
    $lines.Add('    try { Stop-Transcript | Out-Null } catch {}')
    $lines.Add('    if (-not $ok) {')
    $lines.Add('        Write-Host ""')
    $lines.Add('        Read-Host "Press ENTER to close this failed run-all window"')
    $lines.Add('    }')
    $lines.Add('}')
    $lines.Add('exit $exitCode')

    New-Item -ItemType Directory -Path (Split-Path -Parent $RunnerPath) -Force | Out-Null
    Set-Content -LiteralPath $RunnerPath -Value $lines -Encoding UTF8
}

function Read-AllMapRunSummary {
    param([Parameter(Mandatory)][string]$SummaryPath)

    if (-not (Test-Path -LiteralPath $SummaryPath -PathType Leaf)) { return $null }
    try {
        return (Get-Content -LiteralPath $SummaryPath -Raw -ErrorAction Stop | ConvertFrom-Json)
    } catch {
        Write-UiLog "Could not parse all-map summary JSON: $($_.Exception.Message)"
        return $null
    }
}

function Show-AllMapPatchFocusWarning {
    param([Parameter(Mandatory)]$MapRuns)

    $mapRunItems = @()
    foreach ($run in $MapRuns) {
        if ($null -ne $run) { $mapRunItems += $run }
    }

    $mapLines = @($mapRunItems | ForEach-Object {
        $skipIds = [string]$_.SkippedStepIds
        if ([string]::IsNullOrWhiteSpace($skipIds)) { $skipIds = 'none' }
        "  $($_.MapCode): $($_.EnabledStepCount) step(s), skipped: $skipIds"
    })
    if ($mapLines.Count -eq 0) { $mapLines = @('  none') }

    $message = @(
        'Run all map patch pipelines sequentially?',
        '',
        ($mapLines -join "`n"),
        '',
        'This opens one visible PowerShell window and runs one map after another. It can take a long time. Avoid using the computer while WitchyBND prompts or GPU texture steps are active.'
    ) -join "`n"

    $result = [System.Windows.MessageBox]::Show(
        $message,
        'Run all map patches',
        [System.Windows.MessageBoxButton]::OKCancel,
        [System.Windows.MessageBoxImage]::Warning
    )

    return ($result -eq [System.Windows.MessageBoxResult]::OK)
}

function Start-VisibleAllMapPatchProcess {
    Ensure-ModOutputFolders
    Save-PathFiles -Silent

    $toolRoot = $TxtToolRoot.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($toolRoot)) { throw 'Tool root is empty.' }

    $toolPathsPs1 = Join-Path $toolRoot 'BBReborneDIYTool.paths.ps1'
    if (-not (Test-Path -LiteralPath $toolPathsPs1 -PathType Leaf)) {
        throw "Tool paths file was not created: $toolPathsPs1"
    }

    $pwsh = Get-PwshForWorkflow
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $allLogRoot = Join-Path (Join-Path (Join-Path $TxtOutputRoot.Text.Trim() '_logs') 'maps') 'ALL'
    $runDir = Join-Path $allLogRoot $stamp
    $masterRunner = Join-Path $runDir 'run_all_maps.ps1'
    $masterSummary = Join-Path $runDir 'all_map_run_summary.json'

    Refresh-MapStepCheckboxAvailability

    $mapRuns = @()
    foreach ($map in $Maps) {
        $mapCode = [string]$map.Code
        $stepSelection = Get-EffectiveMapSteps -MapCode $mapCode
        $enabledSteps = @($stepSelection.Enabled)
        $skippedSteps = @($stepSelection.Skipped)
        if ($enabledSteps.Count -eq 0) {
            Write-UiLog "$mapCode run-all: no enabled steps after backend/input filtering; skipping map."
            continue
        }

        foreach ($s in $skippedSteps) {
            Write-UiLog "$mapCode run-all: skipping $($s.Id) $($s.Name): $($s.Reason)"
        }

        $mapRunDir = Join-Path $runDir $mapCode
        $runner = Join-Path $mapRunDir ("run_{0}.ps1" -f $mapCode)
        $summaryPath = Join-Path $mapRunDir 'map_run_summary.json'
        New-MapRunnerScript -MapCode $mapCode -EnabledSteps $enabledSteps -SkippedSteps $skippedSteps -RunnerPath $runner -SummaryPath $summaryPath -ToolPathsPs1 $toolPathsPs1 -PwshExe $pwsh

        $skippedStepIds = (@($skippedSteps | ForEach-Object { [string]$_.Id }) -join ',')
        $skippedStepText = (@($skippedSteps | ForEach-Object { ("{0} {1}: {2}" -f $_.Id, $_.Name, $_.Reason) }) -join '; ')

        $mapRuns += [pscustomobject]@{
            MapCode = $mapCode
            Runner = $runner
            Summary = $summaryPath
            EnabledStepCount = [int]$enabledSteps.Count
            SkippedStepCount = [int]$skippedSteps.Count
            SkippedStepIds = [string]$skippedStepIds
            SkippedStepText = [string]$skippedStepText
        }
    }

    if ($mapRuns.Count -eq 0) {
        Write-UiLog 'Run all patches: no enabled map runs.'
        return
    }

    if (-not (Show-AllMapPatchFocusWarning -MapRuns $mapRuns)) {
        Write-UiLog 'Run all patches: cancelled before launch.'
        return
    }

    New-AllMapRunnerScript -MapRuns $mapRuns -RunnerPath $masterRunner -SummaryPath $masterSummary -PwshExe $pwsh

    if ([bool]$ChkNoUpscaleTextures.IsChecked) {
        Write-UiLog 'Run all patches: texture steps will use -NoUpscale.'
    }

    Write-UiLog 'Run all patches: launching visible PowerShell process.'
    Write-UiLog "Runner: $masterRunner"
    Write-UiLog "Summary: $masterSummary"

    foreach ($map in $Maps) {
        $code = [string]$map.Code
        if ($MapRowControls.ContainsKey($code)) {
            $MapRowControls[$code].Status.Text = 'Queued'
            $MapRowControls[$code].Patch.IsEnabled = $false
        }
    }
    $runAllButton = C 'BtnRunAllMapPatches'
    $runAllButton.IsEnabled = $false

    $argList = [string[]]@(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $masterRunner
    )
    $argLine = Join-WindowsCommandLine -Arguments $argList

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $pwsh -ArgumentList $argLine -WindowStyle Normal -PassThru

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromSeconds(5)
    $timer.Tag = [pscustomobject]@{
        Process = $proc
        Stopwatch = $sw
        MapRuns = $mapRuns
        SummaryPath = $masterSummary
    }

    $timer.Add_Tick({
        param($sender, $eventArgs)

        $state = $sender.Tag
        foreach ($run in @($state.MapRuns)) {
            $scopeCode = [string]$run.MapCode
            $summary = Read-MapRunSummary -SummaryPath ([string]$run.Summary)
            if ($summary) {
                $elapsedSeconds = [double]$summary.TotalElapsedSeconds
                if ($summary.Ok -eq $true) {
                    Set-ScopeElapsed -ScopeCode $scopeCode -Seconds $elapsedSeconds -Completed
                    if ($MapRowControls.ContainsKey($scopeCode)) { $MapRowControls[$scopeCode].Status.Text = 'Completed' }
                }
                else {
                    $ScopeElapsedSeconds[$scopeCode] = $elapsedSeconds
                    if ($MapRowControls.ContainsKey($scopeCode)) {
                        $MapRowControls[$scopeCode].Elapsed.Text = (Format-ElapsedSeconds -Seconds $elapsedSeconds)
                        $MapRowControls[$scopeCode].Status.Text = 'Failed'
                    }
                }
            }
            elseif ($MapRowControls.ContainsKey($scopeCode)) {
                if ($MapRowControls[$scopeCode].Status.Text -eq 'Queued') { $MapRowControls[$scopeCode].Status.Text = 'Pending' }
            }
        }

        if (-not $state.Process.HasExited) { return }

        $sender.Stop()
        $state.Stopwatch.Stop()
        $exitCode = $state.Process.ExitCode
        Write-UiLog "Run all patches: PowerShell process exited with code $exitCode."

        foreach ($map in $Maps) {
            $code = [string]$map.Code
            if ($MapRowControls.ContainsKey($code)) { $MapRowControls[$code].Patch.IsEnabled = $true }
        }
        (C 'BtnRunAllMapPatches').IsEnabled = $true

        $summaryAll = Read-AllMapRunSummary -SummaryPath ([string]$state.SummaryPath)
        if ($summaryAll) {
            Write-UiLog ("Run all patches completed maps: {0} / {1}" -f $summaryAll.CompletedMaps, $summaryAll.TotalMaps)
            if ($summaryAll.FailedMapCode) {
                Write-UiLog ("Run all patches failed at map {0}: {1}" -f $summaryAll.FailedMapCode, $summaryAll.FailedMessage)
            }
            if ($summaryAll.TranscriptPath) { Write-UiLog ("Run all patches transcript: {0}" -f $summaryAll.TranscriptPath) }
        }

        foreach ($run in @($state.MapRuns)) {
            $scopeCode = [string]$run.MapCode
            $summary = Read-MapRunSummary -SummaryPath ([string]$run.Summary)
            if ($summary -and $summary.Ok -eq $true) {
                Set-ScopeElapsed -ScopeCode $scopeCode -Seconds ([double]$summary.TotalElapsedSeconds) -Completed
                Test-GeneratedFilesForScope -Scope $scopeCode -MapCode $scopeCode | Out-Null
            }
            elseif ($MapRowControls.ContainsKey($scopeCode) -and $MapRowControls[$scopeCode].Status.Text -in @('Queued','Pending')) {
                $MapRowControls[$scopeCode].Status.Text = if ($exitCode -eq 0) { 'Not run' } else { 'Stopped' }
            }
        }
        Update-ModTotals
    }.GetNewClosure())

    $timer.Start()
}

function Invoke-AllMapPatches {
    Start-VisibleAllMapPatchProcess
}

function Invoke-MapPatchStub {
    param([Parameter(Mandatory)][string]$MapCode)

    Start-VisibleMapPatchProcess -MapCode ([string]$MapCode)
}

function Write-WitchySettingsFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [switch]$CreateBackup,
        [string]$SettingsJson = ''
    )

    $settingsDir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null

    if ($CreateBackup -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $leaf = Split-Path -Leaf $Path
        $backupPath = Join-Path $settingsDir ("{0}.backup_{1}.json" -f $leaf, $stamp)
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
        Write-UiLog "$Label settings backup created: $backupPath"
    }

    if ([string]::IsNullOrWhiteSpace($SettingsJson)) {
        $SettingsJson = Get-WitchyBndRecommendedSettingsJson
    }

    [System.IO.File]::WriteAllText(
        $Path,
        $SettingsJson,
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-UiLog "$Label settings written: $Path"
}

function Get-WitchyBnd2401LocalSettingsPaths {
    $paths = New-Object System.Collections.Generic.List[string]

    try {
        $tool = Get-ToolByKey -Key 'W2401'
        if ($tool) {
            $installDir = Get-ToolInstallDir -Tool $tool
            if (-not [string]::IsNullOrWhiteSpace($installDir)) {
                [void]$paths.Add((Join-Path $installDir 'appsettings.user.json'))
                [void]$paths.Add((Join-Path $installDir 'appsettings.json'))
            }
        }
    } catch {
        Write-UiLog "WitchyBND v2.4.0.1 local settings path fallback used: $($_.Exception.Message)"
    }

    if ($paths.Count -eq 0) {
        $toolRoot = $TxtToolRoot.Text.Trim()
        if (-not [string]::IsNullOrWhiteSpace($toolRoot)) {
            $installDir = Join-Path $toolRoot 'WitchyBND\WitchyBND-v2.4.0.1'
            [void]$paths.Add((Join-Path $installDir 'appsettings.user.json'))
            [void]$paths.Add((Join-Path $installDir 'appsettings.json'))
        }
    }

    return [object[]]($paths.ToArray() | Select-Object -Unique)
}

function Write-WitchyBndRecommendedSettings {
    param([switch]$Silent)

    $writtenPaths = New-Object System.Collections.Generic.List[string]

    $roamingPath = Get-WitchyBndUserSettingsPath
    Write-WitchySettingsFile -Path $roamingPath -Label 'WitchyBND roaming default v2.14.4.5' -CreateBackup -SettingsJson (Get-WitchyBnd21445RoamingSettingsJson)
    [void]$writtenPaths.Add($roamingPath)

    $local2401Paths = @(Get-WitchyBnd2401LocalSettingsPaths)
    if ($local2401Paths.Count -gt 0) {
        foreach ($local2401Path in $local2401Paths) {
            if ([string]::IsNullOrWhiteSpace($local2401Path)) { continue }
            Write-WitchySettingsFile -Path $local2401Path -Label 'WitchyBND v2.4.0.1 local settings' -CreateBackup -SettingsJson (Get-WitchyBnd2401LocalSettingsJson)
            [void]$writtenPaths.Add($local2401Path)
        }
    } else {
        Write-UiLog 'WitchyBND v2.4.0.1 local settings skipped: tool root is empty.'
    }

    if (-not $Silent) {
        [System.Windows.MessageBox]::Show(
            "WitchyBND setup settings written:`n$($writtenPaths -join "`n")`n`nThe Global runner will also rewrite the correct WitchyBND settings before each script step.",
            'WitchyBND settings updated',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    }
}

function Test-GameRootPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Ok = $false; Message = 'Game folder is required.' }
    }

    $trimmed = $Path.Trim().TrimEnd('\', '/')
    $leaf = Split-Path -Leaf $trimmed

    if ($leaf -ne 'dvdroot_ps4') {
        return [pscustomobject]@{ Ok = $false; Message = 'The selected folder must end with dvdroot_ps4.' }
    }

    if (-not (Test-Path -LiteralPath $trimmed -PathType Container)) {
        return [pscustomobject]@{ Ok = $false; Message = 'The selected dvdroot_ps4 folder does not exist.' }
    }

    return [pscustomobject]@{ Ok = $true; Message = 'Game folder OK.' }
}

$downloadsFolder = Get-DownloadsFolder
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $downloadsFolder 'BBReborneDIYTool' }
$defaultSetupRoot = $scriptRoot
$defaultDownloadDir = Join-Path $defaultSetupRoot '_downloads'
$defaultToolRoot = Join-Path $defaultSetupRoot 'Tools'
$defaultOutputRoot = Join-Path $defaultSetupRoot 'ModdedFiles'

$GlobalOutputFolders = @(
    'BBReborne_gparam',
    'BBReborne_menu',
    'BBReborne_obj',
    'BBReborne_sfx'
)

$MapOutputFolders = @(
    'BBReborne_flver',
    'BBReborne_GI',
    'BBReborne_map',
    'BBReborne_maplight',
    'BBReborne_param',
    'BBReborne_sparam',
    'BBReborne_textures'
)

$AllOutputFolders = @($GlobalOutputFolders + $MapOutputFolders)

$Maps = @(
    [pscustomobject]@{ Code = 'M21'; Name = 'Hunters Dream'; Estimate = 'TBD' },
    [pscustomobject]@{ Code = 'M22'; Name = 'Hemwick Charnel Lane'; Estimate = 'TBD' },
    [pscustomobject]@{ Code = 'M23'; Name = 'Old Yharnam'; Estimate = 'TBD' },
    [pscustomobject]@{ Code = 'M24'; Name = 'Yahrnam'; Estimate = 'TBD' },
    [pscustomobject]@{ Code = 'M25'; Name = 'Forsaken Castle Cainhurst'; Estimate = 'TBD' },
    [pscustomobject]@{ Code = 'M26'; Name = 'Nightmare of Mensis'; Estimate = 'TBD' },
    [pscustomobject]@{ Code = 'M27'; Name = 'Forbidden Woods'; Estimate = 'TBD' },
    [pscustomobject]@{ Code = 'M28'; Name = "Yahar'gul Unseen Village"; Estimate = 'TBD' },
    [pscustomobject]@{ Code = 'M29'; Name = 'Chalice Dungeons'; Estimate = 'TBD' },
    [pscustomobject]@{ Code = 'M32'; Name = 'Byrgenwerth'; Estimate = 'TBD' },
    [pscustomobject]@{ Code = 'M33'; Name = 'Nightmare Frontier'; Estimate = 'TBD' },
    [pscustomobject]@{ Code = 'M34'; Name = "Hunter's Nightmare"; Estimate = 'TBD' },
    [pscustomobject]@{ Code = 'M35'; Name = 'Research Hall'; Estimate = 'TBD' },
    [pscustomobject]@{ Code = 'M36'; Name = 'Fishing Hamlet'; Estimate = 'TBD' }
)

$Tools = @(
    [pscustomobject]@{
        Key           = 'PS7'
        Label         = 'PowerShell 7'
        Variable      = 'BBR_Pwsh7Exe'
        Kind          = 'WingetRuntime'
        WingetId      = 'Microsoft.PowerShell'
        PayloadLabel  = 'winget: Microsoft.PowerShell'
        ExeName       = 'pwsh.exe'
        FolderName    = ''
        Url           = ''
        ZipName       = ''
        RunElevated   = $false
        Tooltip       = 'PowerShell 7 is recommended for running the workflow scripts. Install/update it with winget, then restart this setup tool in pwsh if needed.'
    },
    [pscustomobject]@{
        Key           = 'DOTNET9'
        Label         = '.NET 9 SDK'
        Variable      = 'BBR_DotNetExe'
        Kind          = 'WingetExe'
        WingetId      = 'Microsoft.DotNet.SDK.9'
        PayloadLabel  = 'winget: Microsoft.DotNet.SDK.9'
        ExeName       = 'dotnet.exe'
        FolderName    = ''
        Url           = ''
        ZipName       = ''
        RunElevated   = $false
        Tooltip       = 'Installs the .NET 9 SDK through winget if dotnet 9.x is not detected. The SDK includes what is needed to build and run .NET 9 console tools.'
    },
    [pscustomobject]@{
        Key           = 'W3001'
        Label         = 'WitchyBND v3.0.0.1'
        Variable      = 'BBR_WitchyBND_v3_0_0_1'
        Kind          = 'ZipTool'
        WingetId      = ''
        PayloadLabel  = ''
        ExeName       = 'WitchyBND.exe'
        FolderName    = 'WitchyBND\WitchyBND-v3.0.0.1-win-x64'
        Url           = 'https://github.com/ividyon/WitchyBND/releases/download/v3.0.0.1/WitchyBND-v3.0.0.1-win-x64.zip'
        ZipName       = 'WitchyBND-v3.0.0.1-win-x64.zip'
        RunElevated   = $false
        Tooltip       = 'Download and extract this WitchyBND version. The setup tool writes the required settings; patch scripts launch WitchyBND directly with their original command behavior.'
    },
    [pscustomobject]@{
        Key           = 'W21445'
        Label         = 'WitchyBND v2.14.4.5'
        Variable      = 'BBR_WitchyBND_v2_14_4_5'
        Kind          = 'ZipTool'
        WingetId      = ''
        PayloadLabel  = ''
        ExeName       = 'WitchyBND.exe'
        FolderName    = 'WitchyBND\WitchyBND-v2.14.4.5'
        Url           = 'https://github.com/ividyon/WitchyBND/releases/download/v2.14.4.5/WitchyBND-v2.14.4.5.zip'
        ZipName       = 'WitchyBND-v2.14.4.5.zip'
        RunElevated   = $false
        Tooltip       = 'Download and extract this WitchyBND version. The setup tool writes the required settings; patch scripts launch WitchyBND directly with their original command behavior.'
    },
    [pscustomobject]@{
        Key           = 'W2401'
        Label         = 'WitchyBND v2.4.0.1'
        Variable      = 'BBR_WitchyBND_v2_4_0_1'
        Kind          = 'ZipTool'
        WingetId      = ''
        PayloadLabel  = ''
        ExeName       = 'WitchyBND.exe'
        FolderName    = 'WitchyBND\WitchyBND-v2.4.0.1'
        Url           = 'https://github.com/ividyon/WitchyBND/releases/download/v2.4.0.1/WitchyBND-v2.4.0.1.zip'
        ZipName       = 'WitchyBND-v2.4.0.1.zip'
        RunElevated   = $false
        Tooltip       = 'Download and extract this WitchyBND version. The setup tool writes its required local appsettings.json; patch scripts launch WitchyBND directly with their original command behavior.'
    },
    [pscustomobject]@{
        Key           = 'IM'
        Label         = 'ImageMagick Q16-HDRI'
        Variable      = 'BBR_ImageMagickExe'
        Kind          = 'WingetExe'
        WingetId      = 'ImageMagick.Q16-HDRI'
        PayloadLabel  = 'winget: ImageMagick.Q16-HDRI'
        ExeName       = 'magick.exe'
        FolderName    = ''
        Url           = ''
        ZipName       = ''
        RunElevated   = $false
        Tooltip       = 'Installs ImageMagick Q16-HDRI through winget, then detects magick.exe. Used by texture conversion and channel manipulation scripts.'
    },
    [pscustomobject]@{
        Key           = 'TEX'
        Label         = 'texconv.exe'
        Variable      = 'BBR_TexconvExe'
        Kind          = 'DirectExe'
        WingetId      = ''
        PayloadLabel  = ''
        ExeName       = 'texconv.exe'
        FolderName    = 'DirectXTex'
        Url           = 'https://github.com/Microsoft/DirectXTex/releases/latest/download/texconv.exe'
        ZipName       = ''
        RunElevated   = $false
        Tooltip       = 'Downloads texconv.exe directly into the dedicated tool folder. Used for DDS decoding/encoding and format inspection.'
    },
    [pscustomobject]@{
        Key           = 'RE'
        Label         = 'Real-ESRGAN ncnn Vulkan'
        Variable      = 'BBR_RealEsrganExe'
        Kind          = 'ZipTool'
        WingetId      = ''
        PayloadLabel  = ''
        ExeName       = 'realesrgan-ncnn-vulkan.exe'
        FolderName    = 'RealESRGAN\realesrgan-ncnn-vulkan-20220424-windows'
        Url           = 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-windows.zip'
        ZipName       = 'realesrgan-ncnn-vulkan-20220424-windows.zip'
        RunElevated   = $false
        Tooltip       = 'Downloads and extracts the portable Real-ESRGAN ncnn Vulkan Windows package. No Python/CUDA environment is needed for this executable package.'
    },
    [pscustomobject]@{
        Key           = 'GIT'
        Label         = 'Git for Windows'
        Variable      = 'BBR_GitExe'
        Kind          = 'WingetExe'
        WingetId      = 'Git.Git'
        PayloadLabel  = 'winget: Git.Git'
        ExeName       = 'git.exe'
        FolderName    = ''
        Url           = ''
        ZipName       = ''
        RunElevated   = $false
        Tooltip       = 'Installs Git for Windows through winget using the exact package ID Git.Git, then detects git.exe from PATH.'
    },
    [pscustomobject]@{
        Key           = 'BTAB'
        Label         = 'BtabJsonTool'
        Variable      = 'BBR_BtabJsonToolExe'
        Kind          = 'LocalExe'
        WingetId      = ''
        PayloadLabel  = 'local: Tools\BtabJsonTool\bin\Release\net9.0\BtabJsonTool.exe'
        ExeName       = 'BtabJsonTool.exe'
        FolderName    = 'BtabJsonTool\bin\Release\net9.0'
        Url           = ''
        ZipName       = ''
        RunElevated   = $false
        Tooltip       = 'Local required tool. Expected beside this script under Tools\BtabJsonTool\bin\Release\net9.0\BtabJsonTool.exe.'
    },
    [pscustomobject]@{
        Key           = 'BTL'
        Label         = 'BtlJsonTool'
        Variable      = 'BBR_BtlJsonToolExe'
        Kind          = 'LocalExe'
        WingetId      = ''
        PayloadLabel  = 'local: Tools\BtlJsonTool\bin\Release\net9.0\BtlJsonTool.exe'
        ExeName       = 'BtlJsonTool.exe'
        FolderName    = 'BtlJsonTool\bin\Release\net9.0'
        Url           = ''
        ZipName       = ''
        RunElevated   = $false
        Tooltip       = 'Local required tool. Expected beside this script under Tools\BtlJsonTool\bin\Release\net9.0\BtlJsonTool.exe.'
    },
    [pscustomobject]@{
        Key           = 'BTPB'
        Label         = 'BtpbJsonTool'
        Variable      = 'BBR_BtpbJsonToolExe'
        Kind          = 'LocalExe'
        WingetId      = ''
        PayloadLabel  = 'local: Tools\BtpbJsonTool\bin\Release\net9.0\BtpbJsonTool.exe'
        ExeName       = 'BtpbJsonTool.exe'
        FolderName    = 'BtpbJsonTool\bin\Release\net9.0'
        Url           = ''
        ZipName       = ''
        RunElevated   = $false
        Tooltip       = 'Local required tool. Expected beside this script under Tools\BtpbJsonTool\bin\Release\net9.0\BtpbJsonTool.exe.'
    },
    [pscustomobject]@{
        Key           = 'DCX'
        Label         = 'DCXTool'
        Variable      = 'BBR_DCXToolExe'
        Kind          = 'LocalExe'
        WingetId      = ''
        PayloadLabel  = 'local: Tools\DCXTool\bin\Release\net9.0\DCXTool.exe'
        ExeName       = 'DCXTool.exe'
        FolderName    = 'DCXTool\bin\Release\net9.0'
        Url           = ''
        ZipName       = ''
        RunElevated   = $false
        Tooltip       = 'Local required tool. Expected beside this script under Tools\DCXTool\bin\Release\net9.0\DCXTool.exe.'
    },
    [pscustomobject]@{
        Key           = 'FLVER'
        Label         = 'FlverJsonTool'
        Variable      = 'BBR_FlverJsonToolExe'
        Kind          = 'LocalExe'
        WingetId      = ''
        PayloadLabel  = 'local: Tools\FlverJsonTool\bin\Release\net9.0\FlverJsonTool.exe'
        ExeName       = 'FlverJsonTool.exe'
        FolderName    = 'FlverJsonTool\bin\Release\net9.0'
        Url           = ''
        ZipName       = ''
        RunElevated   = $false
        Tooltip       = 'Local required tool. Expected beside this script under Tools\FlverJsonTool\bin\Release\net9.0\FlverJsonTool.exe.'
    },
    [pscustomobject]@{
        Key           = 'FXR'
        Label         = 'FxrJsonTool'
        Variable      = 'BBR_FxrJsonToolExe'
        Kind          = 'LocalExe'
        WingetId      = ''
        PayloadLabel  = 'local: Tools\FxrJsonTool\bin\Release\net9.0\FxrJsonTool.exe'
        ExeName       = 'FxrJsonTool.exe'
        FolderName    = 'FxrJsonTool\bin\Release\net9.0'
        Url           = ''
        ZipName       = ''
        RunElevated   = $false
        Tooltip       = 'Local required tool. Expected beside this script under Tools\FxrJsonTool\bin\Release\net9.0\FxrJsonTool.exe.'
    },
    [pscustomobject]@{
        Key           = 'MSBB'
        Label         = 'MsbbJsonTool'
        Variable      = 'BBR_MsbbJsonToolExe'
        Kind          = 'LocalExe'
        WingetId      = ''
        PayloadLabel  = 'local: Tools\MsbbJsonTool\bin\Release\net9.0\MsbbJsonTool.exe'
        ExeName       = 'MsbbJsonTool.exe'
        FolderName    = 'MsbbJsonTool\bin\Release\net9.0'
        Url           = ''
        ZipName       = ''
        RunElevated   = $false
        Tooltip       = 'Local required tool. Expected beside this script under Tools\MsbbJsonTool\bin\Release\net9.0\MsbbJsonTool.exe.'
    },
    [pscustomobject]@{
        Key           = 'NVA'
        Label         = 'NvaJsonTool'
        Variable      = 'BBR_NvaJsonToolExe'
        Kind          = 'LocalExe'
        WingetId      = ''
        PayloadLabel  = 'local: Tools\NvaJsonTool\bin\Release\net9.0\NvaJsonTool.exe'
        ExeName       = 'NvaJsonTool.exe'
        FolderName    = 'NvaJsonTool\bin\Release\net9.0'
        Url           = ''
        ZipName       = ''
        RunElevated   = $false
        Tooltip       = 'Local required tool. Expected beside this script under Tools\NvaJsonTool\bin\Release\net9.0\NvaJsonTool.exe.'
    }
)

[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="BB Reborne DIY Tool"
        Height="860" Width="1340"
        MinHeight="740" MinWidth="1120"
        WindowStartupLocation="CenterScreen"
        Background="#202020"
        Foreground="#F0F0F0">
    <Window.Resources>
        <SolidColorBrush x:Key="BodyBrush" Color="#202020"/>
        <SolidColorBrush x:Key="PanelBrush" Color="#3F3F3F"/>
        <SolidColorBrush x:Key="BorderBrushSoft" Color="#646464"/>
        <SolidColorBrush x:Key="TextBrush" Color="#F0F0F0"/>
        <SolidColorBrush x:Key="MutedTextBrush" Color="#D0D0D0"/>
        <SolidColorBrush x:Key="InputBrush" Color="#2B2B2B"/>
        <SolidColorBrush x:Key="ButtonBrush" Color="#505050"/>
        <SolidColorBrush x:Key="ButtonHoverBrush" Color="#5A5A5A"/>

        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Background" Value="{StaticResource PanelBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrushSoft}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="GroupBox">
                        <Grid Margin="0,6,0,0">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <Border Grid.RowSpan="2"
                                    Margin="0,10,0,0"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{TemplateBinding BorderThickness}"
                                    CornerRadius="6"/>
                            <Border Grid.Row="0"
                                    Margin="12,0,0,0"
                                    Padding="7,0"
                                    Background="{StaticResource BodyBrush}"
                                    HorizontalAlignment="Left">
                                <ContentPresenter ContentSource="Header"
                                                  RecognizesAccessKey="True"
                                                  TextElement.Foreground="{StaticResource TextBrush}"/>
                            </Border>
                            <ContentPresenter Grid.Row="1" Margin="8,12,8,8"/>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Background" Value="{StaticResource InputBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrushSoft}"/>
            <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Background" Value="{StaticResource ButtonBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrushSoft}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,3"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"
                                              Margin="{TemplateBinding Padding}"
                                              RecognizesAccessKey="True"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="{StaticResource ButtonHoverBrush}"/>
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#777777"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#353535"/>
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#888888"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#888888"/>
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#303030"/>
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#4A4A4A"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TabControl">
            <Setter Property="Background" Value="{StaticResource BodyBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrushSoft}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabControl">
                        <Grid Background="{TemplateBinding Background}">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <TabPanel Grid.Row="0"
                                      Panel.ZIndex="1"
                                      Background="{StaticResource BodyBrush}"
                                      IsItemsHost="True"/>
                            <Border Grid.Row="1"
                                    Background="{StaticResource BodyBrush}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="1"
                                    CornerRadius="0,6,6,6">
                                <ContentPresenter ContentSource="SelectedContent" Margin="0"/>
                            </Border>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Background" Value="#303030"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrushSoft}"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border x:Name="TabBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="1,1,1,0"
                                CornerRadius="5,5,0,0"
                                Margin="0,0,4,0"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter ContentSource="Header"
                                              HorizontalAlignment="Center"
                                              VerticalAlignment="Center"
                                              RecognizesAccessKey="True"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="TabBorder" Property="Background" Value="{StaticResource PanelBrush}"/>
                                <Setter TargetName="TabBorder" Property="BorderBrush" Value="{StaticResource BorderBrushSoft}"/>
                                <Setter Property="Panel.ZIndex" Value="2"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="TabBorder" Property="Background" Value="#4A4A4A"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#888888"/>
                                <Setter TargetName="TabBorder" Property="Background" Value="#2A2A2A"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ScrollViewer">
            <Setter Property="Background" Value="{StaticResource PanelBrush}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ScrollViewer}">
                        <Grid Background="{TemplateBinding Background}">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <ScrollContentPresenter x:Name="PART_ScrollContentPresenter"
                                                    Grid.Row="0"
                                                    Grid.Column="0"
                                                    CanContentScroll="{TemplateBinding CanContentScroll}"
                                                    CanHorizontallyScroll="False"
                                                    CanVerticallyScroll="False"
                                                    Content="{TemplateBinding Content}"
                                                    ContentTemplate="{TemplateBinding ContentTemplate}"
                                                    ContentStringFormat="{TemplateBinding ContentStringFormat}"
                                                    Margin="{TemplateBinding Padding}"/>

                            <ScrollBar x:Name="PART_VerticalScrollBar"
                                       Grid.Row="0"
                                       Grid.Column="1"
                                       Orientation="Vertical"
                                       Maximum="{TemplateBinding ScrollableHeight}"
                                       ViewportSize="{TemplateBinding ViewportHeight}"
                                       Value="{Binding VerticalOffset, RelativeSource={RelativeSource TemplatedParent}, Mode=OneWay}"
                                       Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"/>

                            <ScrollBar x:Name="PART_HorizontalScrollBar"
                                       Grid.Row="1"
                                       Grid.Column="0"
                                       Orientation="Horizontal"
                                       Maximum="{TemplateBinding ScrollableWidth}"
                                       ViewportSize="{TemplateBinding ViewportWidth}"
                                       Value="{Binding HorizontalOffset, RelativeSource={RelativeSource TemplatedParent}, Mode=OneWay}"
                                       Visibility="{TemplateBinding ComputedHorizontalScrollBarVisibility}"/>

                            <Border x:Name="ScrollCorner"
                                    Grid.Row="1"
                                    Grid.Column="1"
                                    Background="#2B2B2B"
                                    BorderBrush="#4A4A4A"
                                    BorderThickness="1"
                                    Visibility="Collapsed"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <MultiTrigger>
                                <MultiTrigger.Conditions>
                                    <Condition SourceName="PART_VerticalScrollBar" Property="Visibility" Value="Visible"/>
                                    <Condition SourceName="PART_HorizontalScrollBar" Property="Visibility" Value="Visible"/>
                                </MultiTrigger.Conditions>
                                <Setter TargetName="ScrollCorner" Property="Visibility" Value="Visible"/>
                            </MultiTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ThemedScrollThumb" TargetType="{x:Type Thumb}">
            <Setter Property="Background" Value="#686868"/>
            <Setter Property="BorderBrush" Value="#777777"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Thumb}">
                        <Border x:Name="ThumbBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5"/>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ThumbBorder" Property="Background" Value="#7A7A7A"/>
                                <Setter TargetName="ThumbBorder" Property="BorderBrush" Value="#8A8A8A"/>
                            </Trigger>
                            <Trigger Property="IsDragging" Value="True">
                                <Setter TargetName="ThumbBorder" Property="Background" Value="#8A8A8A"/>
                                <Setter TargetName="ThumbBorder" Property="BorderBrush" Value="#9A9A9A"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="InvisibleScrollRepeatButton" TargetType="{x:Type RepeatButton}">
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type RepeatButton}">
                        <Border Background="Transparent"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <ControlTemplate x:Key="ThemedVerticalScrollBar" TargetType="{x:Type ScrollBar}">
            <Grid Width="14" Background="#2B2B2B">
                <Border Background="#2B2B2B" BorderBrush="#4A4A4A" BorderThickness="1" CornerRadius="5"/>
                <Track x:Name="PART_Track" IsDirectionReversed="True" Margin="2">
                    <Track.DecreaseRepeatButton>
                        <RepeatButton Style="{StaticResource InvisibleScrollRepeatButton}" Command="ScrollBar.PageUpCommand"/>
                    </Track.DecreaseRepeatButton>
                    <Track.Thumb>
                        <Thumb Style="{StaticResource ThemedScrollThumb}" MinHeight="24"/>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton>
                        <RepeatButton Style="{StaticResource InvisibleScrollRepeatButton}" Command="ScrollBar.PageDownCommand"/>
                    </Track.IncreaseRepeatButton>
                </Track>
            </Grid>
        </ControlTemplate>

        <ControlTemplate x:Key="ThemedHorizontalScrollBar" TargetType="{x:Type ScrollBar}">
            <Grid Height="14" Background="#2B2B2B">
                <Border Background="#2B2B2B" BorderBrush="#4A4A4A" BorderThickness="1" CornerRadius="5"/>
                <Track x:Name="PART_Track" Margin="2">
                    <Track.DecreaseRepeatButton>
                        <RepeatButton Style="{StaticResource InvisibleScrollRepeatButton}" Command="ScrollBar.PageLeftCommand"/>
                    </Track.DecreaseRepeatButton>
                    <Track.Thumb>
                        <Thumb Style="{StaticResource ThemedScrollThumb}" MinWidth="24"/>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton>
                        <RepeatButton Style="{StaticResource InvisibleScrollRepeatButton}" Command="ScrollBar.PageRightCommand"/>
                    </Track.IncreaseRepeatButton>
                </Track>
            </Grid>
        </ControlTemplate>

        <Style TargetType="{x:Type ScrollBar}">
            <Setter Property="Background" Value="#2B2B2B"/>
            <Setter Property="Foreground" Value="#686868"/>
            <Setter Property="BorderBrush" Value="#4A4A4A"/>
            <Setter Property="Width" Value="14"/>
            <Setter Property="Template" Value="{StaticResource ThemedVerticalScrollBar}"/>
            <Style.Triggers>
                <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="Width" Value="Auto"/>
                    <Setter Property="Height" Value="14"/>
                    <Setter Property="Template" Value="{StaticResource ThemedHorizontalScrollBar}"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid Margin="14" Background="{StaticResource BodyBrush}">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Text="BB Reborne DIY Tool" FontSize="22" FontWeight="SemiBold" Margin="0,0,0,12"/>

        <TabControl Grid.Row="1">
            <TabItem Header="Step 1: Setup">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="180"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <Border Grid.Row="0" Padding="12" CornerRadius="8" BorderBrush="{StaticResource BorderBrushSoft}" BorderThickness="1" Background="{StaticResource PanelBrush}">
                        <TextBlock TextWrapping="Wrap" FontSize="14">
                            Prepare the external tools used by the DIY workflow. The usual flow is: select the game folder ending in dvdroot_ps4, check existing tools, download or install missing ones, extract ZIP-based tools, write WitchyBND settings, then save the detected paths for the later steps.
                        </TextBlock>
                    </Border>

                    <GroupBox Grid.Row="1" Header="Setup folders" Margin="0,12,0,10"
                              ToolTip="The game folder must be the dvdroot_ps4 folder. ZIPs and downloaded executables go into the download cache. Portable tools go under the tool root. Installed system tools are detected from PATH or Program Files.">
                        <Grid Margin="10">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="130"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="110"/>
                            </Grid.ColumnDefinitions>

                            <Label Grid.Row="0" Grid.Column="0" Content="Game folder:" VerticalAlignment="Center"/>
                            <TextBox Grid.Row="0" Grid.Column="1" Name="TxtGameRoot" Margin="4" Height="26"
                                     ToolTip="Select the game folder itself. The final folder name must be dvdroot_ps4."/>
                            <Button Grid.Row="0" Grid.Column="2" Name="BtnBrowseGameRoot" Content="Browse..." Margin="4" Height="26"/>

                            <TextBlock Grid.Row="1" Grid.Column="1" Name="TxtGameRootStatus" Text="Game folder is required." Margin="6,0,4,6" FontSize="12"/>

                            <Label Grid.Row="2" Grid.Column="0" Content="Output folder:" VerticalAlignment="Center"/>
                            <TextBox Grid.Row="2" Grid.Column="1" Name="TxtOutputRoot" Margin="4" Height="26"
                                     ToolTip="Default folder for modded output files. This is separate from the selected game folder so generated files are not written directly into the source folder."/>
                            <Button Grid.Row="2" Grid.Column="2" Name="BtnBrowseOutputRoot" Content="Browse..." Margin="4" Height="26"/>

                            <Label Grid.Row="3" Grid.Column="0" Content="Download cache:" VerticalAlignment="Center"/>
                            <TextBox Grid.Row="3" Grid.Column="1" Name="TxtDownloadDir" Margin="4" Height="26"
                                     ToolTip="Default is inside the tool folder. ZIPs and direct executable downloads are cached here unless the tool has a dedicated final path."/>
                            <Button Grid.Row="3" Grid.Column="2" Name="BtnBrowseDownload" Content="Browse..." Margin="4" Height="26"/>

                            <Label Grid.Row="4" Grid.Column="0" Content="Tool root:" VerticalAlignment="Center"/>
                            <TextBox Grid.Row="4" Grid.Column="1" Name="TxtToolRoot" Margin="4" Height="26"
                                     ToolTip="Portable tools are placed below this root, one folder per tool/version. The script saves path files here."/>
                            <Button Grid.Row="4" Grid.Column="2" Name="BtnBrowseToolRoot" Content="Browse..." Margin="4" Height="26"/>
                        </Grid>
                    </GroupBox>

                    <WrapPanel Grid.Row="2" Margin="0,0,0,10">
                        <Button Name="BtnSetupAllPortable" Content="Setup required tools" Width="175" Height="32" Margin="0,0,8,0"
                                ToolTip="One-click setup: checks existing tools, installs missing winget tools, downloads missing portable ZIPs/EXEs, extracts ZIPs, applies WitchyBND settings, refreshes detection, and saves paths when the dvdroot_ps4 folder is valid."/>
                        <TextBlock Name="TxtSetupAllStatus" Text="" VerticalAlignment="Center" Margin="4,0,0,0" FontSize="13" Foreground="#B7F7B2"/>
                    </WrapPanel>

                    <GroupBox Grid.Row="3" Header="Tools" Margin="0,0,0,10" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrushSoft}">
                        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto">
                            <Grid Name="ToolsGrid" Margin="10"/>
                        </ScrollViewer>
                    </GroupBox>

                    <GroupBox Grid.Row="4" Header="Log" Margin="0,0,0,10" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrushSoft}">
                        <TextBox Name="TxtLog" Margin="8" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
                                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                                 FontFamily="Consolas" FontSize="12"/>
                    </GroupBox>

                    <DockPanel Grid.Row="5" LastChildFill="False">
                        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                            <Button Name="BtnRestartPwsh7" Content="Restart in PS7" Width="110" Height="30" Margin="0,0,8,0"
                                    ToolTip="Relaunches this same setup script using the detected pwsh.exe."/>
                            <Button Name="BtnSavePaths" Content="Save paths" Width="100" Height="30" Margin="0,0,8,0"
                                    ToolTip="Writes BBReborneDIYTool.paths.json and BBReborneDIYTool.paths.ps1 with the current paths."/>
                            <Button Name="BtnOpenSetupFolder" Content="Open setup folder" Width="130" Height="30" Margin="0,0,8,0"/>
                            <Button Name="BtnClose" Content="Close" Width="80" Height="30"/>
                        </StackPanel>
                    </DockPanel>
                </Grid>
            </TabItem>

            <TabItem Header="Step 2: Mod files">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <Border Grid.Row="0" Padding="12" CornerRadius="8" BorderBrush="{StaticResource BorderBrushSoft}" BorderThickness="1" Background="{StaticResource PanelBrush}">
                        <TextBlock TextWrapping="Wrap" FontSize="14">
                            Probe this computer and define global parameters used by later PowerShell script calls. CPU throttle defaults to logical CPU threads minus 2, minimum 1. GPU throttle becomes 2 when detected or manually entered VRAM is 16 GB or higher. RAM, VRAM, and output drive space are checked together in the readiness message beside the VRAM box.
                        </TextBlock>
                    </Border>

                    <GroupBox Grid.Row="1" Header="Global run parameters" Margin="0,12,0,10" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrushSoft}">
                        <Grid Margin="10">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="1.2*"/>
                                <ColumnDefinition Width="150"/>
                            </Grid.ColumnDefinitions>

                            <StackPanel Grid.Row="0" Grid.Column="0" Margin="4">
                                <TextBlock Text="CPU throttle" FontWeight="SemiBold" Margin="0,0,0,4"/>
                                <TextBox Name="TxtCpuThrottle" Height="26" ToolTip="Default is logical CPU threads minus 2, minimum 1. This will be passed to script parameters such as CPU throttle / thread count."/>
                            </StackPanel>

                            <StackPanel Grid.Row="0" Grid.Column="1" Margin="4">
                                <TextBlock Text="GPU throttle" FontWeight="SemiBold" Margin="0,0,0,4"/>
                                <TextBox Name="TxtGpuThrottle" Height="26" ToolTip="Default is 1. It becomes 2 when detected or manually entered VRAM is 16 GB or higher. You can edit it manually."/>
                            </StackPanel>

                            <StackPanel Grid.Row="0" Grid.Column="2" Margin="4">
                                <TextBlock Text="Output free space" FontWeight="SemiBold" Margin="0,0,0,4"/>
                                <TextBox Name="TxtOutputFreeSpace" IsReadOnly="True" Height="26"/>
                            </StackPanel>

                            <Button Grid.Row="0" Grid.Column="3" Name="BtnProbeSystem" Content="Probe system" Margin="4,22,4,4" Height="26" ToolTip="Refresh CPU/GPU/RAM/VRAM detection, apply throttle defaults, and check output drive free space. If VRAM is unknown, enter it manually in GB."/>

                            <StackPanel Grid.Row="1" Grid.Column="0" Margin="4">
                                <TextBlock Text="System RAM" FontWeight="SemiBold" Margin="0,0,0,4"/>
                                <TextBox Name="TxtSystemRam" IsReadOnly="True" Height="26"/>
                            </StackPanel>

                            <StackPanel Grid.Row="1" Grid.Column="1" Margin="4">
                                <TextBlock Text="GPU VRAM" FontWeight="SemiBold" Margin="0,0,0,4"/>
                                <TextBox Name="TxtGpuVram" Height="26" ToolTip="Highest detected dedicated VRAM from all GPUs. If Windows does not expose it, enter a manual value such as 16 or 24 GB."/>
                            </StackPanel>

                            <TextBlock Grid.Row="1" Grid.Column="2" Grid.ColumnSpan="2" Name="TxtMemoryStatus" Text="Not checked" Margin="4,22,4,2" TextWrapping="Wrap" VerticalAlignment="Top"/>

                            <TextBlock Name="TxtOutputSpaceStatus" Visibility="Collapsed" Text="Not checked"/>

                            <StackPanel Visibility="Collapsed">
                                <TextBox Name="TxtCpuInfo"/>
                                <TextBox Name="TxtCpuLogical"/>
                                <TextBox Name="TxtGpuInfo"/>
                                <TextBox Name="TxtOutputPathProbe"/>
                                <TextBox Name="TxtOutputDrive"/>
                            </StackPanel>
                        </Grid>
                    </GroupBox>

                    <GroupBox Grid.Row="2" Header="Mod file generation" Margin="0,0,0,10" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrushSoft}">
                        <Grid Margin="10">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>

                            <TextBlock Grid.Row="0" TextWrapping="Wrap" Margin="4,0,4,10">
                                Run Global patches and M21 first to calibrate estimated times. Several PowerShell windows may appear during this initial process; do not click away or change window focus while commands are being sent to external tools. Map names are hidden by default to avoid spoilers.
                            </TextBlock>

                            <DockPanel Grid.Row="1" LastChildFill="False" Margin="4,0,4,10">
                                <TextBlock DockPanel.Dock="Left" Text="Output folders are created automatically under the selected output folder." VerticalAlignment="Center"/>
                                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                    <Button Name="BtnRunAllMapPatches" Content="Run all patches" Width="125" Height="28" Margin="12,0,0,0" ToolTip="Run all map patch pipelines sequentially, respecting backend skips such as GI EnableGI."/>
                                    <CheckBox Name="ChkNoUpscaleTextures" Content="No texture upscale" Margin="12,4,0,0" Foreground="{StaticResource TextBrush}" ToolTip="Pass -NoUpscale to the texture step. Keeps texture treatments but outputs 1x textures."/>
                                    <CheckBox Name="ChkShowMapNames" Content="Show name spoilers" Margin="12,4,0,0" Foreground="{StaticResource TextBrush}" ToolTip="Display map names instead of only map codes."/>
                                </StackPanel>
                            </DockPanel>

                            <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto">
                                <Grid Name="MapsGrid" Margin="4"/>
                            </ScrollViewer>
                        </Grid>
                    </GroupBox>
                </Grid>
            </TabItem>

            <TabItem Header="Step 3: Param tweaks">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <TextBlock Grid.Row="0" TextWrapping="Wrap" Margin="4,0,4,10">
                        Edit Yebis values exposed by the gparam patch files. Generate patches writes a modified copy under the selected output folder, leaving the original Diffs folder untouched.
                    </TextBlock>

                    <DockPanel Grid.Row="1" LastChildFill="False" Margin="4,0,4,10">
                        <TextBlock DockPanel.Dock="Left" Name="TxtParamTweaksStatus" Text="Param tweak rows not loaded yet." VerticalAlignment="Center"/>
                        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                            <Button Name="BtnRefreshParamTweaks" Content="1 - Reload Values" Width="135" Height="28" Margin="12,0,0,0" ToolTip="Reload Yebis tweak rows from the current patch files under Diffs and recover the last saved User values."/>
                            <Button Name="BtnGenerateParamTweaksPatches" Content="2 - Generate Patches" Width="150" Height="28" Margin="8,0,0,0" ToolTip="Save User values and generate a modified copy of the gparam patch files under Output\BBReborne_param_custom\_work."/>
                            <Button Name="BtnPatchParamTweaksFiles" Content="3 - Patch Params" Width="130" Height="28" Margin="8,0,0,0" ToolTip="Run the map Param patch step using the custom patch copy under Output\BBReborne_param_custom\_work."/>
                            <CheckBox Name="ChkShowParamTweaksSpoilers" Content="Show name spoilers" Margin="12,4,0,0" Foreground="{StaticResource TextBrush}" ToolTip="Display friendly map/time names instead of raw codes."/>
                        </StackPanel>
                    </DockPanel>

                    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto">
                        <Grid Name="ParamTweaksGrid" Margin="4"/>
                    </ScrollViewer>
                </Grid>
            </TabItem>

        </TabControl>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $Xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)

function C {
    param([Parameter(Mandatory)][string]$Name)
    $ctrl = $Window.FindName($Name)
    if (-not $ctrl) { throw "Missing WPF control: $Name" }
    return $ctrl
}

$TxtGameRoot = C 'TxtGameRoot'
$TxtGameRootStatus = C 'TxtGameRootStatus'
$TxtOutputRoot = C 'TxtOutputRoot'
$TxtDownloadDir = C 'TxtDownloadDir'
$TxtToolRoot = C 'TxtToolRoot'
$TxtCpuInfo = C 'TxtCpuInfo'
$TxtCpuLogical = C 'TxtCpuLogical'
$TxtCpuThrottle = C 'TxtCpuThrottle'
$TxtGpuInfo = C 'TxtGpuInfo'
$TxtGpuThrottle = C 'TxtGpuThrottle'
$TxtSystemRam = C 'TxtSystemRam'
$TxtGpuVram = C 'TxtGpuVram'
$TxtMemoryStatus = C 'TxtMemoryStatus'
$TxtOutputPathProbe = C 'TxtOutputPathProbe'
$TxtOutputDrive = C 'TxtOutputDrive'
$TxtOutputFreeSpace = C 'TxtOutputFreeSpace'
$TxtOutputSpaceStatus = C 'TxtOutputSpaceStatus'
$TxtSetupAllStatus = C 'TxtSetupAllStatus'
$TxtLog = C 'TxtLog'
$ToolsGrid = C 'ToolsGrid'
$MapsGrid = C 'MapsGrid'
$ChkNoUpscaleTextures = C 'ChkNoUpscaleTextures'
$ParamTweaksGrid = C 'ParamTweaksGrid'
$TxtParamTweaksStatus = C 'TxtParamTweaksStatus'
$ChkShowParamTweaksSpoilers = C 'ChkShowParamTweaksSpoilers'

$TxtOutputRoot.Text = $defaultOutputRoot
$TxtDownloadDir.Text = $defaultDownloadDir
$TxtToolRoot.Text = $defaultToolRoot

$RowControls = @{}
$MapRowControls = @{}
$MapStepCheckControls = @{}
$MapStepBulkCheckControls = @{}
$script:IsUpdatingMapStepBulkChecks = $false
$ParamTweaksRowControls = @()
$TotalsControls = @{}
$ScopeElapsedSeconds = @{}
$ScopeCompleted = @{}

# Reference elapsed times captured from a full successful run.
# Map estimates are scaled from these references as new completed map timings are reported.
$ScopeReferenceSeconds = [ordered]@{
    GLOBAL = 69.0
    M21    = 1210.0
    M22    = 1797.0
    M23    = 2550.0
    M24    = 7546.0
    M25    = 1329.0
    M26    = 1615.0
    M27    = 1242.0
    M28    = 2620.0
    M29    = 4048.0
    M32    = 2208.0
    M33    = 1637.0
    M34    = 2927.0
    M35    = 1256.0
    M36    = 1400.0
}

function Write-UiLog {
    param([AllowNull()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $TxtLog.AppendText("[$timestamp] $Message`r`n")
    $TxtLog.ScrollToEnd()
    [System.Windows.Forms.Application]::DoEvents()
}

function Show-UiError {
    param([Parameter(Mandatory)][string]$Message)

    Write-UiLog "ERROR: $Message"

    try {
        [System.Windows.MessageBox]::Show(
            [string]$Message,
            'Error',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
    catch {
        # Do not let a MessageBox overload/conversion problem hide the real error.
        Write-Host "ERROR: $Message" -ForegroundColor Red
        Write-Host "MessageBox display failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Update-GameRootStatus {
    $result = Test-GameRootPath -Path $TxtGameRoot.Text
    $TxtGameRootStatus.Text = $result.Message
    if ($result.Ok) {
        $TxtGameRootStatus.Foreground = [System.Windows.Media.Brushes]::DarkGreen
    } else {
        $TxtGameRootStatus.Foreground = [System.Windows.Media.Brushes]::DarkRed
    }
    return $result
}

function Require-ValidGameRoot {
    $result = Update-GameRootStatus
    if (-not $result.Ok) {
        throw $result.Message
    }

    return $TxtGameRoot.Text.Trim().TrimEnd('\', '/')
}

function Get-ToolByKey {
    param([Parameter(Mandatory)][string]$Key)
    return $Tools | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
}

function Test-IsWitchyTool {
    param([AllowNull()]$Tool)

    if ($null -eq $Tool) { return $false }
    return @('W3001', 'W21445', 'W2401') -contains [string]$Tool.Key
}

function Test-ToolUsesToolRoot {
    param([AllowNull()]$Tool)

    if ($null -eq $Tool) { return $false }
    return @('ZipTool', 'DirectExe', 'LocalExe') -contains [string]$Tool.Kind
}

function Get-ToolRelativeExePath {
    param([Parameter(Mandatory)]$Tool)

    if (-not (Test-ToolUsesToolRoot -Tool $Tool)) { return $null }
    if (-not $Tool.ExeName) { return $null }
    if (-not $Tool.FolderName) { return $Tool.ExeName }
    return (Join-Path $Tool.FolderName $Tool.ExeName)
}

function Get-DownloadPayloadPath {
    param([Parameter(Mandatory)]$Tool)

    switch ($Tool.Kind) {
        'ZipTool'   { return (Join-Path $TxtDownloadDir.Text $Tool.ZipName) }
        'DirectExe' { return (Get-DirectExeFinalPath -Tool $Tool) }
        'LocalExe'  { return (Get-DirectExeFinalPath -Tool $Tool) }
        default     { return $Tool.PayloadLabel }
    }
}

function Get-ToolInstallDir {
    param([Parameter(Mandatory)]$Tool)

    if (-not $Tool.FolderName) { return $TxtToolRoot.Text }
    return (Join-Path $TxtToolRoot.Text $Tool.FolderName)
}

function Get-DirectExeFinalPath {
    param([Parameter(Mandatory)]$Tool)

    $relativeExe = Get-ToolRelativeExePath -Tool $Tool
    if ($relativeExe) {
        return (Join-Path $TxtToolRoot.Text $relativeExe)
    }

    $dir = Get-ToolInstallDir -Tool $Tool
    return (Join-Path $dir $Tool.ExeName)
}

function Find-ToolExeInToolRoot {
    param([Parameter(Mandatory)]$Tool)

    if (-not (Test-ToolUsesToolRoot -Tool $Tool)) { return $null }

    switch ($Tool.Kind) {
        'DirectExe' {
            $final = Get-DirectExeFinalPath -Tool $Tool
            if (Test-Path -LiteralPath $final -PathType Leaf) { return $final }
            return $null
        }
        'LocalExe' {
            $final = Get-DirectExeFinalPath -Tool $Tool
            if (Test-Path -LiteralPath $final -PathType Leaf) { return $final }
            return $null
        }
        'ZipTool' {
            $searchRoot = Get-ToolInstallDir -Tool $Tool
            return (Find-FirstFile -Roots @($searchRoot) -Filter $Tool.ExeName)
        }
        default {
            return $null
        }
    }
}

function Find-ToolExe {
    param([Parameter(Mandatory)]$Tool)

    switch ($Tool.Kind) {
        'WingetRuntime' {
            return (Find-Pwsh7Exe)
        }
        'WingetExe' {
            if ($Tool.Key -eq 'IM') { return (Find-ImageMagickExe) }
            if ($Tool.Key -eq 'DOTNET9') { return (Find-DotNet9Exe) }
            return (Find-ExecutableOnPath -Name $Tool.ExeName)
        }
        'DirectExe' {
            return (Find-ToolExeInToolRoot -Tool $Tool)
        }
        'LocalExe' {
            return (Find-ToolExeInToolRoot -Tool $Tool)
        }
        'ZipTool' {
            return (Find-ToolExeInToolRoot -Tool $Tool)
        }
        default {
            return $null
        }
    }
}

function Set-RowStatus {
    param(
        [Parameter(Mandatory)]$Tool,
        [Parameter(Mandatory)][string]$Status
    )

    $RowControls[$Tool.Key].Status.Text = $Status
}

function Set-ToolReadyStatus {
    param(
        [Parameter(Mandatory)]$Tool,
        [Parameter(Mandatory)][string]$ExePath
    )

    if ($Tool.Kind -eq 'WingetRuntime') {
        $versionText = Get-PwshVersionText -PwshPath $ExePath
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            Set-RowStatus -Tool $Tool -Status "Ready / current $($PSVersionTable.PSVersion)"
        } else {
            Set-RowStatus -Tool $Tool -Status "Ready / installed $versionText"
        }
    } elseif ($Tool.Key -eq 'DOTNET9') {
        Set-RowStatus -Tool $Tool -Status "Ready / $(Get-DotNet9VersionText -DotNetPath $ExePath)"
    } else {
        Set-RowStatus -Tool $Tool -Status 'Ready'
    }
}

function Refresh-ToolRow {
    param([Parameter(Mandatory)]$Tool)

    $row = $RowControls[$Tool.Key]
    $payloadPath = Get-DownloadPayloadPath -Tool $Tool
    $row.Payload.Text = $payloadPath

    if (Test-ToolUsesToolRoot -Tool $Tool) {
        $detectedInToolRoot = Find-ToolExeInToolRoot -Tool $Tool
        if ($detectedInToolRoot) {
            $row.Exe.Text = $detectedInToolRoot
            Set-ToolReadyStatus -Tool $Tool -ExePath $detectedInToolRoot
            return
        }

        $row.Exe.Text = ''
        switch ($Tool.Kind) {
            'ZipTool' {
                $zipPath = Get-DownloadPayloadPath -Tool $Tool
                if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
                    Set-RowStatus -Tool $Tool -Status 'Downloaded / extract needed'
                } else {
                    Set-RowStatus -Tool $Tool -Status 'Missing'
                }
            }
            'DirectExe' {
                Set-RowStatus -Tool $Tool -Status 'Missing'
            }
            'LocalExe' {
                Set-RowStatus -Tool $Tool -Status 'Missing local'
            }
            default {
                Set-RowStatus -Tool $Tool -Status 'Missing'
            }
        }
        return
    }

    $currentExe = $row.Exe.Text.Trim()
    if ($currentExe -and (Test-Path -LiteralPath $currentExe -PathType Leaf)) {
        Set-ToolReadyStatus -Tool $Tool -ExePath $currentExe
        return
    }

    $detectedExe = Find-ToolExe -Tool $Tool
    if ($detectedExe) {
        $row.Exe.Text = $detectedExe
        Set-ToolReadyStatus -Tool $Tool -ExePath $detectedExe
        return
    }

    switch ($Tool.Kind) {
        'ZipTool' {
            $zipPath = Get-DownloadPayloadPath -Tool $Tool
            if (Test-Path -LiteralPath $zipPath) {
                Set-RowStatus -Tool $Tool -Status 'Downloaded'
            } else {
                Set-RowStatus -Tool $Tool -Status 'Missing'
            }
        }
        'DirectExe' {
            $payload = Get-DownloadPayloadPath -Tool $Tool
            if (Test-Path -LiteralPath $payload) {
                Set-RowStatus -Tool $Tool -Status 'Downloaded'
            } else {
                Set-RowStatus -Tool $Tool -Status 'Missing'
            }
        }
        'LocalExe' {
            $payload = Get-DownloadPayloadPath -Tool $Tool
            if (Test-Path -LiteralPath $payload) {
                Set-RowStatus -Tool $Tool -Status 'Ready'
            } else {
                Set-RowStatus -Tool $Tool -Status 'Missing local'
            }
        }
        'WingetRuntime' {
            if (Get-WingetExe) {
                Set-RowStatus -Tool $Tool -Status 'Missing / winget ready'
            } else {
                Set-RowStatus -Tool $Tool -Status 'Missing / no winget'
            }
        }
        'WingetExe' {
            if (Get-WingetExe) {
                Set-RowStatus -Tool $Tool -Status 'Missing / winget ready'
            } else {
                Set-RowStatus -Tool $Tool -Status 'Missing / no winget'
            }
        }
        default {
            Set-RowStatus -Tool $Tool -Status 'Missing'
        }
    }
}

function Refresh-AllRows {
    Update-GameRootStatus | Out-Null
    foreach ($tool in $Tools) {
        Refresh-ToolRow -Tool $tool
    }
}

function Test-RequiredToolsReady {
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($tool in $Tools) {
        $exe = $null

        if (Test-ToolUsesToolRoot -Tool $tool) {
            $exe = Find-ToolExeInToolRoot -Tool $tool
        } else {
            $exe = $RowControls[$tool.Key].Exe.Text.Trim()
            if (-not $exe -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
                $exe = Find-ToolExe -Tool $tool
            }
        }

        if ($exe -and (Test-Path -LiteralPath $exe -PathType Leaf)) {
            $RowControls[$tool.Key].Exe.Text = $exe
            Set-ToolReadyStatus -Tool $tool -ExePath $exe
        } else {
            if (Test-ToolUsesToolRoot -Tool $tool) {
                $expected = Get-DirectExeFinalPath -Tool $tool
                if ($tool.Kind -eq 'ZipTool') { $expected = Join-Path (Get-ToolInstallDir -Tool $tool) $tool.ExeName }
                [void]$missing.Add("$($tool.Label): expected under Tool Root, for example $expected")
            } else {
                [void]$missing.Add("$($tool.Label): executable not detected")
            }
        }
    }

    return [pscustomobject]@{
        Ok      = ($missing.Count -eq 0)
        Missing = [string[]]$missing.ToArray()
    }
}

function Assert-RequiredToolsReady {
    Refresh-AllRows
    $validation = Test-RequiredToolsReady
    if (-not $validation.Ok) {
        throw ("Required tools are not ready:" + [Environment]::NewLine + ($validation.Missing -join [Environment]::NewLine))
    }
}

function Select-FolderDialog {
    param([AllowNull()][string]$InitialPath)

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select folder'
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath)) {
        $dialog.SelectedPath = $InitialPath
    }

    $result = $dialog.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }

    return $null
}

function Select-ExeDialog {
    param(
        [AllowNull()][string]$InitialPath,
        [Parameter(Mandatory)][string]$ExeName
    )

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select $ExeName"
    $dialog.Filter = "$ExeName|$ExeName|Executable files (*.exe)|*.exe|All files (*.*)|*.*"
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath)) {
        $dialog.InitialDirectory = Split-Path -Parent $InitialPath
        $dialog.FileName = Split-Path -Leaf $InitialPath
    }

    $result = $dialog.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileName
    }

    return $null
}

function Invoke-WingetInstall {
    param([Parameter(Mandatory)]$Tool)

    $winget = Get-WingetExe
    if (-not $winget) {
        throw 'winget.exe was not found. Install or enable Windows App Installer / winget first.'
    }

    $args = @(
        'install',
        '--id', $Tool.WingetId,
        '-e',
        '--source', 'winget',
        '--accept-package-agreements',
        '--accept-source-agreements'
    )

    Write-UiLog "$($Tool.Label): launching winget installer elevated."
    Write-UiLog "winget $($args -join ' ')"
    Start-Process -FilePath $winget -ArgumentList $args -Verb RunAs -Wait
    Write-UiLog "$($Tool.Label): winget process finished. Refreshing detection..."
    Refresh-ToolRow -Tool $Tool
}

function Invoke-ToolDownload {
    param(
        [Parameter(Mandatory)]$Tool,
        [switch]$OnlyIfMissing
    )

    switch ($Tool.Kind) {
        'WingetRuntime' { Invoke-WingetInstall -Tool $Tool; return }
        'WingetExe'     { Invoke-WingetInstall -Tool $Tool; return }
        'LocalExe'      { Write-UiLog "$($Tool.Label): local tool only; download is not available."; Refresh-ToolRow -Tool $Tool; return }
    }

    New-Item -ItemType Directory -Path $TxtDownloadDir.Text -Force | Out-Null

    if ($Tool.Kind -eq 'DirectExe') {
        $finalPath = Get-DirectExeFinalPath -Tool $Tool
        if ((Test-Path -LiteralPath $finalPath) -and $OnlyIfMissing) {
            Write-UiLog "$($Tool.Label): EXE already exists, skipping download."
            Refresh-ToolRow -Tool $Tool
            return
        }

        if (Test-Path -LiteralPath $finalPath) {
            $choice = [System.Windows.MessageBox]::Show(
                "The executable already exists:`n$finalPath`n`nDownload again and overwrite this file?",
                'Confirm re-download',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question
            )
            if ($choice -ne [System.Windows.MessageBoxResult]::Yes) {
                Write-UiLog "$($Tool.Label): download canceled because EXE already exists."
                Refresh-ToolRow -Tool $Tool
                return
            }
        }

        $dir = Split-Path -Parent $finalPath
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-RowStatus -Tool $Tool -Status 'Downloading'
        Write-UiLog "$($Tool.Label): downloading..."
        Write-UiLog "Target EXE: $finalPath"
        Invoke-WebRequest -Uri $Tool.Url -OutFile $finalPath -UseBasicParsing
        $RowControls[$Tool.Key].Exe.Text = $finalPath
        Write-UiLog "$($Tool.Label): download complete."
        Refresh-ToolRow -Tool $Tool
        return
    }

    if ($Tool.Kind -ne 'ZipTool') {
        throw "$($Tool.Label): unsupported download kind $($Tool.Kind)."
    }

    $zipPath = Get-DownloadPayloadPath -Tool $Tool
    if ((Test-Path -LiteralPath $zipPath) -and $OnlyIfMissing) {
        Write-UiLog "$($Tool.Label): ZIP already exists, skipping download."
        Refresh-ToolRow -Tool $Tool
        return
    }

    if (Test-Path -LiteralPath $zipPath) {
        $choice = [System.Windows.MessageBox]::Show(
            "The ZIP already exists:`n$zipPath`n`nDownload again and overwrite this ZIP file?",
            'Confirm re-download',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($choice -ne [System.Windows.MessageBoxResult]::Yes) {
            Write-UiLog "$($Tool.Label): download canceled because ZIP already exists."
            Refresh-ToolRow -Tool $Tool
            return
        }
    }

    Set-RowStatus -Tool $Tool -Status 'Downloading'
    Write-UiLog "$($Tool.Label): downloading..."
    Write-UiLog "Target ZIP: $zipPath"
    Invoke-WebRequest -Uri $Tool.Url -OutFile $zipPath -UseBasicParsing
    Write-UiLog "$($Tool.Label): download complete."
    Refresh-ToolRow -Tool $Tool
}

function Invoke-ToolExtract {
    param([Parameter(Mandatory)]$Tool)

    if ($Tool.Kind -ne 'ZipTool') {
        Write-UiLog "$($Tool.Label): extraction not needed."
        return
    }

    $zipPath = Get-DownloadPayloadPath -Tool $Tool
    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "$($Tool.Label): ZIP not found. Download it first: $zipPath"
    }

    $extractDir = Get-ToolInstallDir -Tool $Tool
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    Set-RowStatus -Tool $Tool -Status 'Extracting'
    Write-UiLog "$($Tool.Label): extracting ZIP..."
    Write-UiLog "Extract target: $extractDir"

    # Does not delete the folder. -Force permits overwriting same-named files from the archive.
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    $exe = Find-ToolExe -Tool $Tool
    if (-not $exe) {
        Set-RowStatus -Tool $Tool -Status 'No EXE found'
        throw "$($Tool.Label): extraction completed, but $($Tool.ExeName) was not found under $extractDir"
    }

    $RowControls[$Tool.Key].Exe.Text = $exe
    Set-RowStatus -Tool $Tool -Status 'Ready'
    Write-UiLog "$($Tool.Label): detected EXE: $exe"
}

function Invoke-ToolRunOrTest {
    param([Parameter(Mandatory)]$Tool)

    $exePath = $RowControls[$Tool.Key].Exe.Text.Trim()
    if (-not $exePath) {
        throw "$($Tool.Label): EXE path is empty. Install, download, extract, or browse first."
    }
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "$($Tool.Label): EXE does not exist: $exePath"
    }

    if (Test-IsWitchyTool -Tool $Tool) {
        Write-UiLog "$($Tool.Label): EXE found. The setup UI does not launch WitchyBND directly; the patch scripts call this version using their original WitchyBND command behavior."
        Write-UiLog "$($Tool.Label): settings are applied by the Setup Portable Tools flow. Re-run setup if the local/appdata settings need to be refreshed."
        return
    }

    switch ($Tool.Key) {
        'BTAB' { Write-UiLog "$($Tool.Label): local EXE found."; return }
        'BTL' { Write-UiLog "$($Tool.Label): local EXE found."; return }
        'BTPB' { Write-UiLog "$($Tool.Label): local EXE found."; return }
        'DCX' { Write-UiLog "$($Tool.Label): local EXE found."; return }
        'FLVER' { Write-UiLog "$($Tool.Label): local EXE found."; return }
        'FXR' { Write-UiLog "$($Tool.Label): local EXE found."; return }
        'MSBB' { Write-UiLog "$($Tool.Label): local EXE found."; return }
        'NVA' { Write-UiLog "$($Tool.Label): local EXE found."; return }
        'PS7' {
            Write-UiLog "$($Tool.Label): opening a PowerShell 7 console."
            Start-Process -FilePath $exePath -ArgumentList @('-NoExit', '-NoProfile', '-Command', '$PSVersionTable')
            return
        }
        'DOTNET9' {
            $versionText = Get-DotNet9VersionText -DotNetPath $exePath
            & $exePath --info *> $null
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                Write-UiLog "$($Tool.Label): test OK. $versionText"
            } else {
                Write-UiLog "$($Tool.Label): test completed with unexpected exit code $exitCode."
            }
            return
        }
        'IM' {
            Write-UiLog "$($Tool.Label): testing magick.exe -version"
            $out = & $exePath -version 2>&1 | Select-Object -First 3
            foreach ($line in $out) { Write-UiLog ([string]$line) }
            return
        }
        'TEX' {
            & $exePath -h *> $null
            $exitCode = $LASTEXITCODE
            if ($exitCode -in @(0, 1)) {
                Write-UiLog "$($Tool.Label): test OK."
            } else {
                Write-UiLog "$($Tool.Label): test completed with unexpected exit code $exitCode."
            }
            return
        }
        'RE' {
            & $exePath -h *> $null
            $exitCode = $LASTEXITCODE
            if ($exitCode -in @(0, -1)) {
                Write-UiLog "$($Tool.Label): test OK."
            } else {
                Write-UiLog "$($Tool.Label): test completed with unexpected exit code $exitCode."
            }
            return
        }
        'GIT' {
            $out = & $exePath --version 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                Write-UiLog "$($Tool.Label): test OK. $out"
            } else {
                Write-UiLog "$($Tool.Label): test completed with unexpected exit code $exitCode."
            }
            return
        }
        default {
            if ($Tool.RunElevated) {
                Write-UiLog "$($Tool.Label): launching elevated. Approve the Windows UAC prompt if it appears."
                Start-Process -FilePath $exePath -WorkingDirectory (Split-Path -Parent $exePath) -Verb RunAs
            } else {
                Write-UiLog "$($Tool.Label): launching."
                Start-Process -FilePath $exePath -WorkingDirectory (Split-Path -Parent $exePath)
            }
        }
    }
}

function Restart-InPwsh7 {
    $tool = Get-ToolByKey -Key 'PS7'
    Refresh-ToolRow -Tool $tool
    $pwsh = $RowControls[$tool.Key].Exe.Text.Trim()

    if (-not $pwsh -or -not (Test-Path -LiteralPath $pwsh)) {
        throw 'PowerShell 7 / pwsh.exe was not found yet. Install it first or browse to pwsh.exe.'
    }

    if (-not $PSCommandPath) {
        throw 'Cannot restart because PSCommandPath is empty. Save this script as a .ps1 file and run it again.'
    }

    Write-UiLog "Restarting this setup script in PowerShell 7: $pwsh"
    Start-Process -FilePath $pwsh -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-STA',
        '-File', $PSCommandPath
    )
    $Window.Close()
}

function Get-PathConfig {
    $gameRoot = Require-ValidGameRoot

    $toolsConfig = [ordered]@{}
    foreach ($tool in $Tools) {
        $exe = $RowControls[$tool.Key].Exe.Text.Trim()
        $toolsConfig[$tool.Variable] = [ordered]@{
            label    = $tool.Label
            kind     = $tool.Kind
            exe      = $exe
            payload  = (Get-DownloadPayloadPath -Tool $tool)
            url      = $tool.Url
            wingetId = $tool.WingetId
        }
    }

    return [ordered]@{
        generatedAt = (Get-Date).ToString('o')
        currentHost = [ordered]@{
            exe     = (Get-Process -Id $PID).Path
            version = $PSVersionTable.PSVersion.ToString()
        }
        gameRoot    = $gameRoot
        outputRoot  = $TxtOutputRoot.Text.Trim()
        downloadDir = $TxtDownloadDir.Text.Trim()
        toolRoot    = $TxtToolRoot.Text.Trim()
        runParams   = [ordered]@{
            cpuThrottle       = (Get-PositiveIntFromTextBox -TextBox $TxtCpuThrottle -Label 'CPU throttle')
            gpuThrottle       = (Get-PositiveIntFromTextBox -TextBox $TxtGpuThrottle -Label 'GPU throttle')
            logicalProcessors = $TxtCpuLogical.Text.Trim()
            cpuInfo           = $TxtCpuInfo.Text.Trim()
            gpuInfo           = $TxtGpuInfo.Text.Trim()
            gpuVram           = $TxtGpuVram.Text.Trim()
            outputDrive       = $TxtOutputDrive.Text.Trim()
            outputFreeSpace   = $TxtOutputFreeSpace.Text.Trim()
            outputSpaceStatus = $TxtOutputSpaceStatus.Text.Trim()
        }
        tools       = $toolsConfig
    }
}

function Get-DefaultConfigPath {
    return (Join-Path $defaultToolRoot 'BBReborneDIYTool.paths.json')
}

function Get-CurrentConfigPath {
    $toolRoot = $TxtToolRoot.Text.Trim()
    if (-not $toolRoot) { $toolRoot = $defaultToolRoot }
    return (Join-Path $toolRoot 'BBReborneDIYTool.paths.json')
}

function Load-PathFiles {
    $candidates = New-Object System.Collections.Generic.List[string]
    $currentConfig = Get-CurrentConfigPath
    if ($currentConfig) { $candidates.Add($currentConfig) }
    $defaultConfig = Get-DefaultConfigPath
    if ($defaultConfig) { $candidates.Add($defaultConfig) }

    $configPath = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $configPath) {
        Write-UiLog 'No saved setup config found yet.'
        return
    }

    try {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $configToolRoot = Split-Path -Parent $configPath

        if ($config.gameRoot) { $TxtGameRoot.Text = [string]$config.gameRoot }
        if ($config.outputRoot) { $TxtOutputRoot.Text = [string]$config.outputRoot }
        if ($config.downloadDir) { $TxtDownloadDir.Text = [string]$config.downloadDir }
        if ($configToolRoot) {
            $TxtToolRoot.Text = $configToolRoot
        } elseif ($config.toolRoot) {
            $TxtToolRoot.Text = [string]$config.toolRoot
        }

        if ($config.runParams) {
            if ($config.runParams.cpuThrottle) { $TxtCpuThrottle.Text = [string]$config.runParams.cpuThrottle }
            if ($config.runParams.gpuThrottle) { $TxtGpuThrottle.Text = [string]$config.runParams.gpuThrottle }
            if ($config.runParams.logicalProcessors) { $TxtCpuLogical.Text = [string]$config.runParams.logicalProcessors }
            if ($config.runParams.cpuInfo) { $TxtCpuInfo.Text = [string]$config.runParams.cpuInfo }
            if ($config.runParams.gpuInfo) { $TxtGpuInfo.Text = [string]$config.runParams.gpuInfo }
            if ($config.runParams.gpuVram) { $TxtGpuVram.Text = [string]$config.runParams.gpuVram }
            if ($config.runParams.outputDrive) { $TxtOutputDrive.Text = [string]$config.runParams.outputDrive }
            if ($config.runParams.outputFreeSpace) { $TxtOutputFreeSpace.Text = [string]$config.runParams.outputFreeSpace }
            if ($config.runParams.outputSpaceStatus) { $TxtOutputSpaceStatus.Text = [string]$config.runParams.outputSpaceStatus }
        }

        if ($config.tools) {
            foreach ($tool in $Tools) {
                if (Test-ToolUsesToolRoot -Tool $tool) {
                    $detectedFromToolRoot = Find-ToolExeInToolRoot -Tool $tool
                    if ($detectedFromToolRoot) {
                        $RowControls[$tool.Key].Exe.Text = $detectedFromToolRoot
                        continue
                    }
                }

                $saved = $config.tools.PSObject.Properties[$tool.Variable]
                if ($saved -and $saved.Value -and $saved.Value.exe) {
                    $RowControls[$tool.Key].Exe.Text = [string]$saved.Value.exe
                }
            }
        }

        Write-UiLog "Loaded saved setup config: $configPath"
    } catch {
        Write-UiLog "Could not load saved setup config: $($_.Exception.Message)"
    }
}

function Save-PathFiles {
    param([switch]$Silent)

    $toolRoot = $TxtToolRoot.Text.Trim()
    if (-not $toolRoot) { throw 'Tool root is empty.' }
    New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null

    $jsonPath = Join-Path $toolRoot 'BBReborneDIYTool.paths.json'
    $ps1Path = Join-Path $toolRoot 'BBReborneDIYTool.paths.ps1'

    Assert-RequiredToolsReady

    $config = Get-PathConfig
    $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Auto-generated by BBReborneDIYTool.ps1')
    $lines.Add('# Dot-source this file to reuse the paths:')
    $lines.Add('#   . "<repo>\Tools\BBReborneDIYTool.paths.ps1"')
    $lines.Add('# Tool-root executables are resolved relative to this file so the repo can be moved without rewriting local paths.')
    $lines.Add('')
    $lines.Add('$BBR_PathsFileRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }')
    $lines.Add('$BBR_GameRoot = ' + (Quote-PSString $config.gameRoot))
    $lines.Add('$BBR_OutputRoot = ' + (Quote-PSString $config.outputRoot))
    $lines.Add('$BBR_ToolDownloadDir = ' + (Quote-PSString $config.downloadDir))
    $lines.Add('$BBR_ToolRoot = $BBR_PathsFileRoot')
    $lines.Add('$BBR_CpuThrottle = ' + $config.runParams.cpuThrottle)
    $lines.Add('$BBR_GpuThrottle = ' + $config.runParams.gpuThrottle)
    $lines.Add('$BBR_LogicalProcessors = ' + (Quote-PSString $config.runParams.logicalProcessors))
    $lines.Add('$BBR_CpuInfo = ' + (Quote-PSString $config.runParams.cpuInfo))
    $lines.Add('$BBR_GpuInfo = ' + (Quote-PSString $config.runParams.gpuInfo))
    $lines.Add('$BBR_GpuVram = ' + (Quote-PSString $config.runParams.gpuVram))
    $lines.Add('')

    foreach ($tool in $Tools) {
        $relativeExe = Get-ToolRelativeExePath -Tool $tool
        if ($relativeExe) {
            $lines.Add('$' + $tool.Variable + ' = Join-Path $BBR_ToolRoot ' + (Quote-PSString $relativeExe))
        } else {
            $exe = $RowControls[$tool.Key].Exe.Text.Trim()
            $lines.Add('$' + $tool.Variable + ' = ' + (Quote-PSString $exe))
        }
        $lines.Add('$env:' + $tool.Variable + ' = ' + '$' + $tool.Variable)
    }

    $lines.Add('')
    $lines.Add('$BBR_Tools = [ordered]@{')
    foreach ($tool in $Tools) {
        $lines.Add('    ' + (Quote-PSString $tool.Label) + ' = $' + $tool.Variable)
    }
    $lines.Add('}')

    Set-Content -LiteralPath $ps1Path -Value $lines -Encoding UTF8

    Write-UiLog "Saved JSON paths: $jsonPath"
    Write-UiLog "Saved PowerShell variables: $ps1Path"
    if (-not $Silent) {
        [System.Windows.MessageBox]::Show(
            "Saved:`n$jsonPath`n`n$ps1Path",
            'Paths saved',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    }
}

function Invoke-SafeUiAction {
    param([Parameter(Mandatory)][scriptblock]$Action)
    try {
        & $Action
    } catch {
        $parts = New-Object System.Collections.Generic.List[string]
        [void]$parts.Add($_.Exception.Message)
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
            [void]$parts.Add('')
            [void]$parts.Add($_.InvocationInfo.PositionMessage)
        }
        if ($_.ScriptStackTrace) {
            [void]$parts.Add('')
            [void]$parts.Add('Stack:')
            [void]$parts.Add($_.ScriptStackTrace)
        }
        Show-UiError ($parts -join "`n")
    } finally {
        Refresh-AllRows
    }
}

function Add-ToolsGridColumns {
    $widths = @('210', '165', '2*', '2*', '380')
    foreach ($w in $widths) {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        $col.Width = [System.Windows.GridLengthConverter]::new().ConvertFromString($w)
        [void]$ToolsGrid.ColumnDefinitions.Add($col)
    }
}

function Add-GridChild {
    param(
        [Parameter(Mandatory)]$Child,
        [Parameter(Mandatory)][int]$Row,
        [Parameter(Mandatory)][int]$Column
    )

    [System.Windows.Controls.Grid]::SetRow($Child, $Row)
    [System.Windows.Controls.Grid]::SetColumn($Child, $Column)
    [void]$ToolsGrid.Children.Add($Child)
}

function New-TextBlockCell {
    param(
        [Parameter(Mandatory)][string]$Text,
        [switch]$Bold,
        [AllowNull()][string]$Tooltip
    )

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.Margin = [System.Windows.Thickness]::new(4)
    $tb.VerticalAlignment = 'Center'
    $tb.TextWrapping = 'Wrap'
    if ($Bold) { $tb.FontWeight = 'Bold' }
    if ($Tooltip) { $tb.ToolTip = $Tooltip }
    return $tb
}

function New-TextBoxCell {
    param(
        [switch]$ReadOnly,
        [AllowNull()][string]$Tooltip
    )

    $box = New-Object System.Windows.Controls.TextBox
    $box.Margin = [System.Windows.Thickness]::new(4)
    $box.Height = 26
    $box.IsReadOnly = [bool]$ReadOnly
    if ($Tooltip) { $box.ToolTip = $Tooltip }
    return $box
}

function New-ButtonCell {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$Width,
        [AllowNull()][string]$Tooltip
    )

    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = $Text
    $btn.Width = $Width
    $btn.Height = 26
    $btn.Margin = [System.Windows.Thickness]::new(2)
    if ($Tooltip) { $btn.ToolTip = $Tooltip }
    return $btn
}


function New-StepCheckboxPanel {
    param(
        [Parameter(Mandatory)][string]$MapCode,
        [bool]$IsGlobal = $false
    )

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $panel.Margin = [System.Windows.Thickness]::new(2)
    $panel.VerticalAlignment = 'Center'
    $panel.MinWidth = 300

    $byStep = @{}
    $steps = @()
    if (-not $IsGlobal) {
        try { $steps = @(Get-MapStepDefinitions -MapCode $MapCode) } catch { $steps = @() }
    }

    for ($i = 1; $i -le 8; $i++) {
        $id = ('{0:00}' -f $i)
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = [string]$i
        $cb.Margin = [System.Windows.Thickness]::new(6,0,6,0)
        $cb.MinWidth = 28
        $cb.VerticalAlignment = 'Center'
        $cb.IsChecked = $true
        $cb.Tag = $id

        if ($IsGlobal) {
            $cb.IsEnabled = $false
            $cb.IsChecked = $false
            $cb.Opacity = 0.25
            $cb.ToolTip = 'Map steps only'
        }
        else {
            $step = @($steps | Where-Object { $_.Id -eq $id } | Select-Object -First 1)
            if ($step.Count -gt 0) {
                $cb.ToolTip = ("{0} {1}" -f $step[0].Id, $step[0].Name)
                if ($step[0].Enabled -ne $true) {
                    $cb.IsChecked = $false
                    $cb.IsEnabled = $false
                    $cb.Opacity = 0.35
                    $cb.ToolTip = ("{0} {1}: {2}" -f $step[0].Id, $step[0].Name, $step[0].Reason)
                }
            }
        }

        if (-not $IsGlobal) {
            $cb.Add_Click({
                if (-not $script:IsUpdatingMapStepBulkChecks) {
                    Update-MapStepBulkCheckboxState
                }
            }.GetNewClosure())
        }

        [void]$panel.Children.Add($cb)
        $byStep[$id] = $cb
    }

    if (-not $IsGlobal) { $MapStepCheckControls[$MapCode] = $byStep }
    return $panel
}


function Get-EnabledMapStepCheckboxesForStep {
    param([Parameter(Mandatory)][string]$StepId)

    $items = @()
    foreach ($mapEntry in $MapStepCheckControls.GetEnumerator()) {
        $byStep = $mapEntry.Value
        if ($null -eq $byStep) { continue }
        if (-not $byStep.ContainsKey($StepId)) { continue }

        $cb = $byStep[$StepId]
        if ($null -eq $cb) { continue }
        if ($cb.IsEnabled -eq $true) {
            $items += $cb
        }
    }

    return @($items)
}

function Set-MapStepCheckboxesForAllMaps {
    param(
        [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][bool]$IsChecked
    )

    $script:IsUpdatingMapStepBulkChecks = $true
    try {
        foreach ($cb in @(Get-EnabledMapStepCheckboxesForStep -StepId $StepId)) {
            $cb.IsChecked = $IsChecked
        }
    }
    finally {
        $script:IsUpdatingMapStepBulkChecks = $false
    }

    Update-MapStepBulkCheckboxState
}

function Update-MapStepBulkCheckboxState {
    if (-not $MapStepBulkCheckControls -or $MapStepBulkCheckControls.Count -le 0) { return }

    $script:IsUpdatingMapStepBulkChecks = $true
    try {
        for ($i = 1; $i -le 8; $i++) {
            $id = ('{0:00}' -f $i)
            if (-not $MapStepBulkCheckControls.ContainsKey($id)) { continue }

            $bulkCb = $MapStepBulkCheckControls[$id]
            $enabledBoxes = @(Get-EnabledMapStepCheckboxesForStep -StepId $id)

            if ($enabledBoxes.Count -le 0) {
                $bulkCb.IsEnabled = $false
                $bulkCb.IsChecked = $false
                $bulkCb.Opacity = 0.35
                $bulkCb.ToolTip = "Step $i is unavailable for all maps."
                continue
            }

            $checkedCount = @($enabledBoxes | Where-Object { $_.IsChecked -eq $true }).Count
            $bulkCb.IsEnabled = $true
            $bulkCb.Opacity = 1.0
            $bulkCb.ToolTip = "Check/uncheck step $i for all maps. Mixed state means only some enabled maps are selected."

            if ($checkedCount -eq $enabledBoxes.Count) {
                $bulkCb.IsChecked = $true
            }
            elseif ($checkedCount -eq 0) {
                $bulkCb.IsChecked = $false
            }
            else {
                $bulkCb.IsChecked = $null
            }
        }
    }
    finally {
        $script:IsUpdatingMapStepBulkChecks = $false
    }
}

function New-StepBulkCheckboxPanel {
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $panel.Margin = [System.Windows.Thickness]::new(2)
    $panel.VerticalAlignment = 'Center'
    $panel.MinWidth = 300

    for ($i = 1; $i -le 8; $i++) {
        $id = ('{0:00}' -f $i)

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = [string]$i
        $cb.Margin = [System.Windows.Thickness]::new(6,0,6,0)
        $cb.MinWidth = 28
        $cb.VerticalAlignment = 'Center'
        $cb.IsThreeState = $true
        $cb.IsChecked = $true
        $cb.Tag = $id
        $cb.ToolTip = "Check/uncheck step $i for all maps."

        $localStepId = $id
        $localCheckBox = $cb

        # Handle the toggle before WPF cycles a three-state checkbox.
        # Desired behavior:
        #   checked       -> click unchecks all enabled rows for this step
        #   unchecked     -> click checks all enabled rows for this step
        #   indeterminate -> click checks all enabled rows for this step
        $cb.Add_PreviewMouseLeftButtonDown({
            if ($script:IsUpdatingMapStepBulkChecks) { return }

            $currentlyChecked = ($localCheckBox.IsChecked -eq $true)
            Set-MapStepCheckboxesForAllMaps -StepId $localStepId -IsChecked (-not $currentlyChecked)

            $_.Handled = $true
        }.GetNewClosure())

        [void]$panel.Children.Add($cb)
        $MapStepBulkCheckControls[$id] = $cb
    }

    return $panel
}


function Add-MapGridChild {
    param(
        [Parameter(Mandatory)]$Child,
        [Parameter(Mandatory)][int]$Row,
        [Parameter(Mandatory)][int]$Column
    )

    [System.Windows.Controls.Grid]::SetRow($Child, $Row)
    [System.Windows.Controls.Grid]::SetColumn($Child, $Column)
    [void]$MapsGrid.Children.Add($Child)
}

function Update-MapNameVisibility {
    $showNames = (C 'ChkShowMapNames').IsChecked -eq $true

    foreach ($map in $Maps) {
        if (-not $MapRowControls.ContainsKey($map.Code)) { continue }
        if ($showNames) {
            $MapRowControls[$map.Code].Name.Text = $map.Name
        } else {
            $MapRowControls[$map.Code].Name.Text = 'Hidden'
        }
    }

    if ($MapRowControls.ContainsKey('GLOBAL')) {
        $MapRowControls['GLOBAL'].Name.Text = 'Global files'
    }
}

function Format-ElapsedSeconds {
    param([Parameter(Mandatory)][double]$Seconds)

    $ts = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
    if ($ts.TotalHours -ge 1) {
        return ('{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds)
    }

    return ('{0:00}:{1:00}' -f $ts.Minutes, $ts.Seconds)
}

function Get-ReferenceEstimateScale {
    $actualTotal = 0.0
    $referenceTotal = 0.0

    foreach ($entry in $ScopeElapsedSeconds.GetEnumerator()) {
        $scopeCode = [string]$entry.Key
        if ($scopeCode -eq 'GLOBAL') { continue }
        if (-not $ScopeReferenceSeconds.Contains($scopeCode)) { continue }
        if (-not $ScopeCompleted.ContainsKey($scopeCode)) { continue }
        if (-not [bool]$ScopeCompleted[$scopeCode]) { continue }

        $refSeconds = [double]$ScopeReferenceSeconds[$scopeCode]
        if ($refSeconds -le 0) { continue }

        $actualTotal += [double]$entry.Value
        $referenceTotal += $refSeconds
    }

    if ($referenceTotal -le 0) { return 1.0 }
    return ($actualTotal / $referenceTotal)
}

function Get-ScaledReferenceSeconds {
    param([Parameter(Mandatory)][string]$ScopeCode)

    if (-not $ScopeReferenceSeconds.Contains($ScopeCode)) { return $null }

    $seconds = [double]$ScopeReferenceSeconds[$ScopeCode]
    if ($ScopeCode -ne 'GLOBAL') {
        $seconds *= (Get-ReferenceEstimateScale)
    }
    return $seconds
}

function Get-ScopeEstimateText {
    param([Parameter(Mandatory)][string]$ScopeCode)

    $seconds = Get-ScaledReferenceSeconds -ScopeCode $ScopeCode
    if ($null -eq $seconds) { return 'TBD' }
    return (Format-ElapsedSeconds -Seconds ([double]$seconds))
}

function Get-ScaledReferenceTotalSeconds {
    $total = 0.0
    foreach ($entry in $ScopeReferenceSeconds.GetEnumerator()) {
        $scopeCode = [string]$entry.Key
        $seconds = Get-ScaledReferenceSeconds -ScopeCode $scopeCode
        if ($null -ne $seconds) { $total += [double]$seconds }
    }
    return $total
}

function Update-EstimateDisplay {
    foreach ($entry in $MapRowControls.GetEnumerator()) {
        $scopeCode = [string]$entry.Key
        if (-not $ScopeReferenceSeconds.Contains($scopeCode)) { continue }
        $entry.Value.Estimate.Text = (Get-ScopeEstimateText -ScopeCode $scopeCode)
    }

    if ($TotalsControls.ContainsKey('Estimate')) {
        $TotalsControls.Estimate.Text = (Format-ElapsedSeconds -Seconds (Get-ScaledReferenceTotalSeconds))
    }
}

function Set-ScopeElapsed {
    param(
        [Parameter(Mandatory)][string]$ScopeCode,
        [Parameter(Mandatory)][double]$Seconds,
        [switch]$Completed
    )

    $ScopeElapsedSeconds[$ScopeCode] = $Seconds
    if ($Completed) {
        $ScopeCompleted[$ScopeCode] = $true
    }

    if ($MapRowControls.ContainsKey($ScopeCode)) {
        $MapRowControls[$ScopeCode].Elapsed.Text = (Format-ElapsedSeconds -Seconds $Seconds)
        if ($Completed) {
            $MapRowControls[$ScopeCode].Status.Text = 'Completed'
        }
    }

    Update-EstimateDisplay
    Update-ModTotals
}

function Update-ModTotals {
    if (-not $TotalsControls.ContainsKey('Status')) { return }

    $totalTargets = $Maps.Count + 1
    $completedCount = @($ScopeCompleted.GetEnumerator() | Where-Object { $_.Value -eq $true }).Count
    $elapsedTotal = 0.0

    foreach ($value in $ScopeElapsedSeconds.Values) {
        $elapsedTotal += [double]$value
    }

    $TotalsControls.Estimate.Text = (Format-ElapsedSeconds -Seconds (Get-ScaledReferenceTotalSeconds))
    $TotalsControls.Elapsed.Text = (Format-ElapsedSeconds -Seconds $elapsedTotal)
    $TotalsControls.Status.Text = "$completedCount / $totalTargets completed"
}


function Add-ParamTweaksGridChild {
    param(
        [Parameter(Mandatory)]$Child,
        [Parameter(Mandatory)][int]$Row,
        [Parameter(Mandatory)][int]$Column
    )

    [System.Windows.Controls.Grid]::SetRow($Child, $Row)
    [System.Windows.Controls.Grid]::SetColumn($Child, $Column)
    [void]$ParamTweaksGrid.Children.Add($Child)
}

function Get-YebisTargetParams {
    return @(
        [pscustomobject]@{ Key = 'Exposure';    Name1 = 'Yebis-ToneMapExposure'; Name2 = 'Exposure';    Kind = 'Float' },
        [pscustomobject]@{ Key = 'Gamma';       Name1 = 'Yebis-Gamma';           Name2 = 'Gamma';       Kind = 'Float' },
        [pscustomobject]@{ Key = 'ColorS';      Name1 = 'Yebis-ColorS';          Name2 = 'ColorS';      Kind = 'Float' },
        [pscustomobject]@{ Key = 'MiddleGray';  Name1 = 'Yebis-MiddleGray';      Name2 = 'MiddleGray';  Kind = 'Float' },
        [pscustomobject]@{ Key = 'LutSourceId'; Name1 = 'Yebis-LutSourceId';     Name2 = 'LutSourceId'; Kind = 'Int' }
    )
}

function Get-ParamTweaksFriendlyLabelTable {
    $table = @{}

    $table['m21_00_0000'] = [pscustomobject]@{ Map = 'Hunters Dream';               Time = 'Night' }
    $table['m21_00_0001'] = [pscustomobject]@{ Map = 'Hunters Dream';               Time = 'Bloodmoon' }
    $table['m21_01_0000'] = [pscustomobject]@{ Map = 'Abandoned Workshop';          Time = 'Afternoon' }
    $table['m21_01_0001'] = [pscustomobject]@{ Map = 'Abandoned Workshop';          Time = 'Night' }
    $table['m21_01_0002'] = [pscustomobject]@{ Map = 'Abandoned Workshop';          Time = 'Bloodmoon' }

    $table['m22_00_0000'] = [pscustomobject]@{ Map = 'Hemwick Charnel Lane';        Time = 'Afternoon' }
    $table['m22_00_0001'] = [pscustomobject]@{ Map = 'Hemwick Charnel Lane';        Time = 'Night' }

    $table['m23_00_0000'] = [pscustomobject]@{ Map = 'Old Yharnam';                 Time = 'Afternoon' }
    $table['m23_00_0001'] = [pscustomobject]@{ Map = 'Old Yharnam';                 Time = 'Night' }

    $table['m24_00_0000'] = [pscustomobject]@{ Map = 'Cathedral Ward';              Time = 'Afternoon' }
    $table['m24_00_0001'] = [pscustomobject]@{ Map = 'Cathedral Ward';              Time = 'Night' }
    $table['m24_00_0002'] = [pscustomobject]@{ Map = 'Cathedral Ward';              Time = 'Bloodmoon' }

    $table['m24_01_0000'] = [pscustomobject]@{ Map = 'Central Yharnam';             Time = 'Afternoon' }
    $table['m24_01_0100'] = [pscustomobject]@{ Map = 'Central Yharnam';             Time = 'Clinic' }
    $table['m24_01_0001'] = [pscustomobject]@{ Map = 'Central Yharnam';             Time = 'Sunset' }
    $table['m24_01_0002'] = [pscustomobject]@{ Map = 'Central Yharnam';             Time = 'Night' }
    $table['m24_01_0003'] = [pscustomobject]@{ Map = 'Central Yharnam';             Time = 'Bloodmoon' }

    $table['m24_02_0000'] = [pscustomobject]@{ Map = 'Upper Cathedral';             Time = 'Bloodmoon' }

    $table['m25_00_0000'] = [pscustomobject]@{ Map = 'Forsaken Castle Cainhurst';   Time = 'Night' }
    $table['m26_00_0000'] = [pscustomobject]@{ Map = 'Nightmare of Mensis';         Time = 'Night' }

    $table['m27_00_0000'] = [pscustomobject]@{ Map = 'Forbidden Woods';             Time = 'Night' }
    $table['m27_00_0100'] = [pscustomobject]@{ Map = 'Forbidden Woods';             Time = 'Transition' }

    $table['m28_00_0000'] = [pscustomobject]@{ Map = "Yahar'gul Unseen Village";   Time = 'Afternoon' }
    $table['m28_00_0001'] = [pscustomobject]@{ Map = "Yahar'gul Unseen Village";   Time = 'Night' }
    $table['m28_00_0002'] = [pscustomobject]@{ Map = "Yahar'gul Unseen Village";   Time = 'Bloodmoon' }

    $table['m29_00_0000'] = [pscustomobject]@{ Map = 'Chalice Dungeons';            Time = 'Indoors' }
    $table['m32_00_0000'] = [pscustomobject]@{ Map = 'Byrgenwerth';                 Time = 'Night' }
    $table['m33_00_0000'] = [pscustomobject]@{ Map = 'Nightmare Frontier';          Time = 'Afternoon' }
    $table['m34_00_0000'] = [pscustomobject]@{ Map = "Hunter's Nightmare";         Time = 'Afternoon' }
    $table['m35_00_0000'] = [pscustomobject]@{ Map = 'Research Hall';               Time = 'Indoors' }
    $table['m36_00_0000'] = [pscustomobject]@{ Map = 'Fishing Hamlet';              Time = 'Night' }

    return $table
}

function Get-ParamTweaksPatchFiles {
    $diffRoot = Get-DiffRoot
    if (-not (Test-Path -LiteralPath $diffRoot -PathType Container)) {
        return @()
    }

    $paramRoot = Join-Path $diffRoot 'param'
    $searchRoot = if (Test-Path -LiteralPath $paramRoot -PathType Container) { $paramRoot } else { $diffRoot }

    return @(
        Get-ChildItem -LiteralPath $searchRoot -Recurse -File -Filter '*.patch' -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like '*.gparam.xml.patch' -and
                $_.Name -notlike '*_witchy-bnd4.xml.patch'
            } |
            Sort-Object FullName
    )
}

function Get-ParamTweaksMapInfoFromPatchPath {
    param([Parameter(Mandatory)][string]$PatchPath)

    $leaf = [System.IO.Path]::GetFileName($PatchPath)
    $xmlKey = ''
    $mapAreaCode = ''
    $shortMapCode = ''
    $timeCode = ''

    if ($leaf -match '^(m(?<map>\d{2})_(?<area>\d{2})_(?<time>\d{4}))\.gparam\.xml\.patch$') {
        $xmlKey = [string]$Matches[1]
        $mapAreaCode = ('M{0}_{1}' -f $Matches['map'], $Matches['area'])
        $shortMapCode = ('M{0}' -f $Matches['map'])
        $timeCode = [string]$Matches['time']
    }
    else {
        $xmlKey = [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileNameWithoutExtension($leaf))
        $mapAreaCode = $xmlKey
        $shortMapCode = $xmlKey
        $timeCode = ''
    }

    $labelTable = Get-ParamTweaksFriendlyLabelTable
    $friendly = $null
    if ($labelTable.ContainsKey($xmlKey)) {
        $friendly = $labelTable[$xmlKey]
    }

    $friendlyMap = if ($friendly) { [string]$friendly.Map } else { $mapAreaCode }
    $friendlyTime = if ($friendly) { [string]$friendly.Time } else { $timeCode }

    return [pscustomobject]@{
        XmlKey       = $xmlKey
        MapAreaCode  = $mapAreaCode
        ShortMapCode = $shortMapCode
        TimeCode     = $timeCode
        MapName      = $friendlyMap
        TimeName     = $friendlyTime
    }
}

function Get-YebisValuesFromPatch {
    param([Parameter(Mandatory)][string]$PatchPath)

    $targets = @(Get-YebisTargetParams)
    $byName1 = @{}
    foreach ($target in $targets) {
        $byName1[$target.Name1] = $target
    }

    $result = @{}
    foreach ($target in $targets) {
        $result[$target.Key] = [pscustomobject]@{
            Key       = $target.Key
            Name1     = $target.Name1
            Name2     = $target.Name2
            Kind      = $target.Kind
            Vanilla   = ''
            Modded    = ''
            User      = ''
            LinkedIds = @()
            HasValue  = $false
        }
    }

    $currentKey = $null
    $currentIds = New-Object System.Collections.Generic.List[string]

    foreach ($line in [System.IO.File]::ReadLines($PatchPath)) {
        $content = $line
        if ($content.Length -gt 0 -and $content[0] -in @(' ', '-', '+')) {
            $content = $content.Substring(1)
        }

        if ($content -match '<param\b[^>]*name1="([^"]+)"[^>]*name2="([^"]+)"') {
            $name1 = [string]$Matches[1]
            if ($byName1.ContainsKey($name1)) {
                $currentKey = [string]$byName1[$name1].Key
                $currentIds.Clear()
            }
            else {
                $currentKey = $null
            }
        }

        if ($currentKey) {
            if ($line -match '^-.*<value\s+id="([^"]+)">\s*(.*?)\s*</value>') {
                $id = [string]$Matches[1]
                $value = [string]$Matches[2]
                if ($id -eq '0') {
                    $result[$currentKey].Vanilla = $value
                    $result[$currentKey].HasValue = $true
                }
                else {
                    [void]$currentIds.Add($id)
                }
            }
            elseif ($line -match '^\+.*<value\s+id="([^"]+)">\s*(.*?)\s*</value>') {
                $id = [string]$Matches[1]
                $value = [string]$Matches[2]
                if ($id -eq '0') {
                    $result[$currentKey].Modded = $value
                    $result[$currentKey].User = $value
                    $result[$currentKey].HasValue = $true
                }
                else {
                    [void]$currentIds.Add($id)
                }
            }

            if ($content -match '</param>') {
                $result[$currentKey].LinkedIds = @($currentIds | Select-Object -Unique | Sort-Object)
                $currentKey = $null
                $currentIds.Clear()
            }
        }
    }

    return $result
}

function Set-ParamTweaksColumnUserValues {
    param(
        [Parameter(Mandatory)][string]$ParamKey,
        [Parameter(Mandatory)][ValidateSet('User','Modded','Vanilla')][string]$Source
    )

    if (-not $ParamTweaksRowControls -or @($ParamTweaksRowControls).Count -le 0) {
        return
    }

    $firstUserValue = $null
    if ($Source -eq 'User') {
        foreach ($row in @($ParamTweaksRowControls)) {
            if (-not $row.Values.ContainsKey($ParamKey)) { continue }
            $cell = $row.Values[$ParamKey]
            if ($cell -and $cell.TextBox) {
                $firstUserValue = [string]$cell.TextBox.Text
                break
            }
        }

        if ($null -eq $firstUserValue) {
            return
        }
    }

    foreach ($row in @($ParamTweaksRowControls)) {
        if (-not $row.Values.ContainsKey($ParamKey)) { continue }

        $cell = $row.Values[$ParamKey]
        if (-not $cell -or -not $cell.TextBox) { continue }

        if ($Source -eq 'User') {
            $cell.TextBox.Text = $firstUserValue
            continue
        }

        $valueInfo = $null
        if ($row.ValueInfos -and $row.ValueInfos.ContainsKey($ParamKey)) {
            $valueInfo = $row.ValueInfos[$ParamKey]
        }

        if ($null -eq $valueInfo) { continue }

        if ($Source -eq 'Modded') {
            if (-not [string]::IsNullOrWhiteSpace([string]$valueInfo.Modded)) {
                $cell.TextBox.Text = [string]$valueInfo.Modded
            }
        }
        elseif ($Source -eq 'Vanilla') {
            if (-not [string]::IsNullOrWhiteSpace([string]$valueInfo.Vanilla)) {
                $cell.TextBox.Text = [string]$valueInfo.Vanilla
            }
        }
    }

    Write-UiLog ("Param tweaks: copied {0} values into User boxes for {1}." -f $Source, $ParamKey)
}

function New-ParamTweaksHeaderCell {
    param(
        [Parameter(Mandatory)][string]$Title,
        [switch]$Nested,
        [string]$ParamKey = ''
    )

    $border = New-Object System.Windows.Controls.Border
    $border.BorderBrush = [System.Windows.Media.Brushes]::DimGray
    $border.BorderThickness = [System.Windows.Thickness]::new(0,0,1,1)
    $border.Padding = [System.Windows.Thickness]::new(4)
    $border.Margin = [System.Windows.Thickness]::new(0)

    if (-not $Nested) {
        $tb = New-TextBlockCell -Text $Title -Bold
        $tb.Margin = [System.Windows.Thickness]::new(2)
        $border.Child = $tb
        return $border
    }

    $grid = New-Object System.Windows.Controls.Grid
    $row1 = New-Object System.Windows.Controls.RowDefinition
    $row1.Height = [System.Windows.GridLength]::Auto
    [void]$grid.RowDefinitions.Add($row1)
    $row2 = New-Object System.Windows.Controls.RowDefinition
    $row2.Height = [System.Windows.GridLength]::Auto
    [void]$grid.RowDefinitions.Add($row2)

    foreach ($w in @('82','62','62')) {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        $col.Width = [System.Windows.GridLengthConverter]::new().ConvertFromString($w)
        [void]$grid.ColumnDefinitions.Add($col)
    }

    $titleBlock = New-TextBlockCell -Text $Title -Bold
    $titleBlock.HorizontalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetRow($titleBlock, 0)
    [System.Windows.Controls.Grid]::SetColumnSpan($titleBlock, 3)
    [void]$grid.Children.Add($titleBlock)

    $labels = @('User', 'Modded', 'Vanilla')
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $source = $labels[$i]

        $button = New-Object System.Windows.Controls.Button
        $button.Content = $source
        $button.Height = 22
        $button.Margin = [System.Windows.Thickness]::new(2)
        $button.Padding = [System.Windows.Thickness]::new(4,0,4,0)
        $button.FontSize = 11
        $button.ToolTip = if ($source -eq 'User') {
            "Copy the first User value in this $Title column to all User boxes in this column."
        }
        else {
            "Copy each row's $source value in this $Title column to that row's User box."
        }

        $localParamKey = $ParamKey
        $localSource = $source
        $button.Add_Click({
            Invoke-SafeUiAction {
                if (-not [string]::IsNullOrWhiteSpace($localParamKey)) {
                    Set-ParamTweaksColumnUserValues -ParamKey $localParamKey -Source $localSource
                }
            }
        }.GetNewClosure())

        [System.Windows.Controls.Grid]::SetRow($button, 1)
        [System.Windows.Controls.Grid]::SetColumn($button, $i)
        [void]$grid.Children.Add($button)
    }

    $border.Child = $grid
    return $border
}

function New-ParamTweaksValueCell {
    param(
        [Parameter(Mandatory)]$ValueInfo,
        [Parameter(Mandatory)][string]$PatchPath
    )

    $border = New-Object System.Windows.Controls.Border
    $border.BorderBrush = [System.Windows.Media.Brushes]::DimGray
    $border.BorderThickness = [System.Windows.Thickness]::new(0,0,1,1)
    $border.Padding = [System.Windows.Thickness]::new(4)
    $border.Margin = [System.Windows.Thickness]::new(0)

    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in @('82','62','62')) {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        $col.Width = [System.Windows.GridLengthConverter]::new().ConvertFromString($w)
        [void]$grid.ColumnDefinitions.Add($col)
    }

    $userBox = New-Object System.Windows.Controls.TextBox
    $userBox.Height = 24
    $userBox.Margin = [System.Windows.Thickness]::new(2)
    $userBox.Text = [string]$ValueInfo.User
    $userBox.ToolTip = "Custom value for $($ValueInfo.Name1). This UI does not write patches yet."

    $moddedText = if ([string]::IsNullOrWhiteSpace([string]$ValueInfo.Modded)) { '-' } else { [string]$ValueInfo.Modded }
    $vanillaText = if ([string]::IsNullOrWhiteSpace([string]$ValueInfo.Vanilla)) { '-' } else { [string]$ValueInfo.Vanilla }

    $modded = New-TextBlockCell -Text $moddedText
    $modded.HorizontalAlignment = 'Center'
    $modded.ToolTip = "Modded +value from patch."

    $vanilla = New-TextBlockCell -Text $vanillaText
    $vanilla.HorizontalAlignment = 'Center'
    $vanilla.ToolTip = "Vanilla -value from patch."

    if ($ValueInfo.LinkedIds -and @($ValueInfo.LinkedIds).Count -gt 0) {
        $userBox.ToolTip = "Custom value for $($ValueInfo.Name1). Linked changed ids in this patch: $(@($ValueInfo.LinkedIds) -join ', '). This UI does not write patches yet."
    }

    [System.Windows.Controls.Grid]::SetColumn($userBox, 0)
    [System.Windows.Controls.Grid]::SetColumn($modded, 1)
    [System.Windows.Controls.Grid]::SetColumn($vanilla, 2)
    [void]$grid.Children.Add($userBox)
    [void]$grid.Children.Add($modded)
    [void]$grid.Children.Add($vanilla)

    $border.Child = $grid

    return [pscustomobject]@{
        Element = $border
        TextBox = $userBox
        Modded = $modded
        Vanilla = $vanilla
    }
}

function Update-ParamTweaksNameVisibility {
    if (-not $ParamTweaksRowControls) { return }

    $showNames = ($ChkShowParamTweaksSpoilers.IsChecked -eq $true)

    foreach ($row in @($ParamTweaksRowControls)) {
        if ($showNames) {
            $row.MapText.Text = $row.MapName
            $row.TimeText.Text = $row.TimeName
        }
        else {
            $row.MapText.Text = $row.MapAreaCode
            $row.TimeText.Text = $row.TimeCode
        }
    }
}

function Get-ParamTweaksSourceRoot {
    $diffRoot = Get-DiffRoot
    $paramRoot = Join-Path $diffRoot 'param'

    if (Test-Path -LiteralPath $paramRoot -PathType Container) {
        return ([System.IO.Path]::GetFullPath($paramRoot))
    }

    return ([System.IO.Path]::GetFullPath($diffRoot))
}

function Get-RelativePathUnderRoot {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$FullPath
    )

    $base = [System.IO.Path]::GetFullPath($BasePath)
    $path = [System.IO.Path]::GetFullPath($FullPath)

    if (-not $base.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $base = $base + [System.IO.Path]::DirectorySeparatorChar
    }

    try {
        $baseUri = [System.Uri]::new($base)
        $pathUri = [System.Uri]::new($path)
        $rel = $baseUri.MakeRelativeUri($pathUri).ToString()
        return ([System.Uri]::UnescapeDataString($rel) -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    }
    catch {
        return ([System.IO.Path]::GetFileName($FullPath))
    }
}

function Get-ParamTweaksCustomPatchRoot {
    $outputRoot = Get-RequiredOutputRoot
    $customRoot = Join-Path $outputRoot 'BBReborne_param_custom'
    $workRoot = Join-Path $customRoot '_work'
    $diffRoot = Get-DiffRoot
    $paramRoot = Join-Path $diffRoot 'param'
    $sourceRoot = Get-ParamTweaksSourceRoot

    $destRoot = Join-Path $workRoot 'Diffs'

    if ((Test-Path -LiteralPath $paramRoot -PathType Container) -and
        (([System.IO.Path]::GetFullPath($sourceRoot).TrimEnd('\')) -ieq ([System.IO.Path]::GetFullPath($paramRoot).TrimEnd('\')))) {
        $destRoot = Join-Path $destRoot 'param'
    }

    return [pscustomobject]@{
        CustomRoot = $customRoot
        WorkRoot   = $workRoot
        SourceRoot = $sourceRoot
        DestRoot   = $destRoot
    }
}

function Set-YebisPatchPlusValues {
    param(
        [Parameter(Mandatory)][string]$PatchPath,
        [Parameter(Mandatory)]$ValuesByName1
    )

    if (-not (Test-Path -LiteralPath $PatchPath -PathType Leaf)) {
        throw "Patch file not found: $PatchPath"
    }

    $lines = [System.IO.File]::ReadAllLines($PatchPath)
    $outLines = New-Object System.Collections.Generic.List[string]

    $activeEntry = $null
    $activeName1 = $null

    foreach ($line in $lines) {
        $content = [string]$line
        if ($content.Length -gt 0 -and $content[0] -in @(' ', '-', '+')) {
            $content = $content.Substring(1)
        }

        if ($content -match '<param\b[^>]*name1="([^"]+)"[^>]*name2="([^"]+)"') {
            $name1 = [string]$Matches[1]
            if ($ValuesByName1.ContainsKey($name1)) {
                $activeName1 = $name1
                $activeEntry = $ValuesByName1[$name1]
            }
            else {
                $activeName1 = $null
                $activeEntry = $null
            }
        }

        $newLine = [string]$line

        if ($activeEntry -and $line -match '^(\+.*<value\s+id=")([^"]+)(">\s*)(.*?)(\s*</value>.*)$') {
            $valueId = [string]$Matches[2]
            if (@($activeEntry.Ids) -contains $valueId) {
                $newLine = $Matches[1] + $valueId + $Matches[3] + [string]$activeEntry.Value + $Matches[5]
            }
        }

        [void]$outLines.Add($newLine)

        if ($activeEntry -and $content -match '</param>') {
            $activeName1 = $null
            $activeEntry = $null
        }
    }

    [System.IO.File]::WriteAllText(
        $PatchPath,
        (($outLines.ToArray()) -join "`n") + "`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Get-ParamTweaksUserValuesPath {
    $toolRoot = $TxtToolRoot.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($toolRoot)) {
        $toolRoot = Join-Path $scriptRoot 'Tools'
    }

    New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
    return (Join-Path $toolRoot 'BBReborneDIYTool.param_tweaks.user_values.json')
}

function Save-ParamTweaksUserValues {
    if (-not $ParamTweaksRowControls -or @($ParamTweaksRowControls).Count -le 0) {
        return
    }

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($row in @($ParamTweaksRowControls)) {
        $values = [ordered]@{}

        foreach ($target in @(Get-YebisTargetParams)) {
            if ($row.Values -and $row.Values.ContainsKey($target.Key)) {
                $cell = $row.Values[$target.Key]
                if ($cell -and $cell.TextBox) {
                    $values[$target.Key] = [string]$cell.TextBox.Text
                }
            }
        }

        [void]$rows.Add([pscustomobject]@{
            XmlKey      = [string]$row.XmlKey
            MapAreaCode = [string]$row.MapAreaCode
            TimeCode    = [string]$row.TimeCode
            Values      = $values
        })
    }

    $payload = [pscustomobject]@{
        Version = 1
        SavedAt = (Get-Date).ToString('o')
        Rows = @($rows.ToArray())
    }

    $path = Get-ParamTweaksUserValuesPath
    $json = $payload | ConvertTo-Json -Depth 8

    [System.IO.File]::WriteAllText(
        $path,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-UiLog "Param tweaks: user values saved: $path"
}

function Restore-ParamTweaksUserValues {
    $path = Get-ParamTweaksUserValuesPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return
    }

    try {
        $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $byXmlKey = @{}

        foreach ($savedRow in @($data.Rows)) {
            $key = [string]$savedRow.XmlKey
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            $byXmlKey[$key] = $savedRow
        }

        $restored = 0

        foreach ($row in @($ParamTweaksRowControls)) {
            $xmlKey = [string]$row.XmlKey
            if (-not $byXmlKey.ContainsKey($xmlKey)) { continue }

            $savedRow = $byXmlKey[$xmlKey]
            foreach ($target in @(Get-YebisTargetParams)) {
                if (-not $row.Values.ContainsKey($target.Key)) { continue }

                $prop = $savedRow.Values.PSObject.Properties[$target.Key]
                if ($null -eq $prop) { continue }

                $cell = $row.Values[$target.Key]
                if ($cell -and $cell.TextBox) {
                    $cell.TextBox.Text = [string]$prop.Value
                    $restored++
                }
            }
        }

        if ($restored -gt 0) {
            Write-UiLog ("Param tweaks: restored {0} saved User value(s) from {1}" -f $restored, $path)
        }
    }
    catch {
        Write-UiLog "Param tweaks: could not restore saved User values from $path :: $($_.Exception.Message)"
    }
}

function Invoke-GenerateParamTweaksPatches {
    param([switch]$Silent)

    if (-not $ParamTweaksRowControls -or @($ParamTweaksRowControls).Count -le 0) {
        Build-ParamTweaksRows
    }

    Save-ParamTweaksUserValues

    $allPatchFiles = @(Get-ParamTweaksPatchFiles)
    if ($allPatchFiles.Count -le 0) {
        throw 'No gparam patch files were found under Diffs.'
    }

    $paths = Get-ParamTweaksCustomPatchRoot
    New-Item -ItemType Directory -Path $paths.DestRoot -Force | Out-Null

    $sourceToDest = @{}
    $copied = 0

    # Copy every gparam patch first, including no-value/special cases that do not appear
    # as editable UI rows. The User boxes only control editable +value lines later.
    foreach ($patch in $allPatchFiles) {
        $relative = Get-RelativePathUnderRoot -BasePath $paths.SourceRoot -FullPath $patch.FullName
        $destPatch = Join-Path $paths.DestRoot $relative
        $destDir = Split-Path -Parent $destPatch

        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Copy-Item -LiteralPath $patch.FullName -Destination $destPatch -Force

        $sourceToDest[[System.IO.Path]::GetFullPath($patch.FullName)] = $destPatch
        $copied++
    }

    $modified = 0
    $skippedRows = 0

    foreach ($row in @($ParamTweaksRowControls)) {
        if ([string]::IsNullOrWhiteSpace([string]$row.PatchPath)) {
            $skippedRows++
            continue
        }

        $sourceKey = [System.IO.Path]::GetFullPath([string]$row.PatchPath)
        if (-not $sourceToDest.ContainsKey($sourceKey)) {
            Write-UiLog "Param tweaks: editable row source was not found in copied patch set, skipped: $($row.PatchPath)"
            $skippedRows++
            continue
        }

        $destPatch = $sourceToDest[$sourceKey]

        $valuesByName1 = @{}
        foreach ($target in @(Get-YebisTargetParams)) {
            if (-not $row.Values.ContainsKey($target.Key)) { continue }
            if (-not $row.ValueInfos.ContainsKey($target.Key)) { continue }

            $cell = $row.Values[$target.Key]
            $info = $row.ValueInfos[$target.Key]
            if (-not $info.HasValue) { continue }
            if (-not $cell -or -not $cell.TextBox) { continue }

            $userValue = [string]$cell.TextBox.Text
            if ([string]::IsNullOrWhiteSpace($userValue)) { continue }

            $ids = New-Object System.Collections.Generic.List[string]
            [void]$ids.Add('0')

            foreach ($linkedId in @($info.LinkedIds)) {
                if ([string]::IsNullOrWhiteSpace([string]$linkedId)) { continue }
                # Keep changed non-zero values linked to the id=0 UI value.
                # This includes the known id=100 cases and any other changed id detected in the patch.
                if (-not ($ids.Contains([string]$linkedId))) {
                    [void]$ids.Add([string]$linkedId)
                }
            }

            $valuesByName1[$target.Name1] = [pscustomobject]@{
                Value = $userValue
                Ids   = @($ids.ToArray())
            }
        }

        if ($valuesByName1.Count -le 0) {
            $skippedRows++
            continue
        }

        Set-YebisPatchPlusValues -PatchPath $destPatch -ValuesByName1 $valuesByName1
        $modified++
    }

    $TxtParamTweaksStatus.Text = ("Generated custom patch copy: {0} modified / {1} copied. Output: {2}" -f $modified, $copied, $paths.DestRoot)
    Write-UiLog ("Param tweaks: generated custom patch copy. Modified={0}; Copied={1}; SkippedEditableRows={2}; Output={3}" -f $modified, $copied, $skippedRows, $paths.DestRoot)

    if (-not $Silent) {
        [System.Windows.MessageBox]::Show(
            ("Generated custom patch copy.`n`nModified editable patch files: {0}`nCopied patch files: {1}`nSkipped editable rows: {2}`n`nOutput:`n{3}" -f $modified, $copied, $skippedRows, $paths.DestRoot),
            'Param tweaks',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    }

    return $paths
}


function Invoke-PatchParamTweaksFiles {
    $paths = Invoke-GenerateParamTweaksPatches -Silent

    if ($null -eq $paths) {
        $paths = Get-ParamTweaksCustomPatchRoot
    }

    if (-not (Test-Path -LiteralPath $paths.DestRoot -PathType Container)) {
        throw "Custom patch directory was not found: $($paths.DestRoot)"
    }

    Save-PathFiles -Silent

    $toolRoot = $TxtToolRoot.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($toolRoot)) { throw 'Tool root is empty.' }

    $toolPathsPs1 = Join-Path $toolRoot 'BBReborneDIYTool.paths.ps1'
    if (-not (Test-Path -LiteralPath $toolPathsPs1 -PathType Leaf)) {
        throw "Tool paths file was not created: $toolPathsPs1"
    }

    $pwsh = Get-PwshForWorkflow

    $mapScriptsRoot = Join-Path (Join-Path $scriptRoot 'Scripts') 'Mapfiles'
    $paramScript = Join-Path $mapScriptsRoot '05_Mapfiles_BBReborne_Param.ps1'
    if (-not (Test-Path -LiteralPath $paramScript -PathType Leaf)) {
        throw "Param patch script not found: $paramScript"
    }

    $gameRoot = $TxtGameRoot.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($gameRoot)) { throw 'Game folder is empty.' }

    $outputRoot = Get-RequiredOutputRoot
    $customOutputDir = Join-Path (Join-Path (Join-Path $outputRoot 'BBReborne_param_custom') 'param') 'drawparam'
    $customLogRoot = Join-Path (Join-Path (Join-Path $outputRoot '_logs') 'param_tweaks') (Get-Date -Format 'yyyyMMdd_HHmmss')

    New-Item -ItemType Directory -Path $customOutputDir -Force | Out-Null
    New-Item -ItemType Directory -Path $customLogRoot -Force | Out-Null

    $argList = [string[]]@(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $paramScript,
        '-ToolPathsPs1', $toolPathsPs1,
        '-GameRoot', $gameRoot,
        '-OutputRoot', $outputRoot,
        '-PatchDir', $paths.DestRoot,
        '-OutputDir', $customOutputDir,
        '-LogDir', $customLogRoot
    )

    $argLine = Join-WindowsCommandLine -Arguments $argList

    Write-UiLog 'Param tweaks: launching custom Param patch process.'
    Write-UiLog "Param tweaks patch dir: $($paths.DestRoot)"
    Write-UiLog "Param tweaks output dir: $customOutputDir"
    Write-UiLog "Param tweaks log dir: $customLogRoot"

    $button = C 'BtnPatchParamTweaksFiles'
    $button.IsEnabled = $false
    $TxtParamTweaksStatus.Text = 'Patching custom param files...'

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $pwsh -ArgumentList $argLine -WindowStyle Normal -PassThru

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Tag = [pscustomobject]@{
        Process = $proc
        Stopwatch = $sw
        Button = $button
        OutputDir = $customOutputDir
        LogDir = $customLogRoot
        WorkRoot = $paths.WorkRoot
    }

    $timer.Add_Tick({
        param($sender, $eventArgs)

        $state = $sender.Tag
        if (-not $state.Process.HasExited) {
            $TxtParamTweaksStatus.Text = ("Patching custom param files... {0}" -f (Format-ElapsedSeconds -Seconds $state.Stopwatch.Elapsed.TotalSeconds))
            return
        }

        $sender.Stop()
        $state.Stopwatch.Stop()
        $state.Button.IsEnabled = $true

        $exitCode = $state.Process.ExitCode
        if ($exitCode -eq 0) {
            if ($state.WorkRoot -and (Test-Path -LiteralPath $state.WorkRoot -PathType Container)) {
                try {
                    Remove-Item -LiteralPath $state.WorkRoot -Recurse -Force
                    Write-UiLog ("Param tweaks: removed work directory after patching: {0}" -f $state.WorkRoot)
                }
                catch {
                    Write-UiLog ("Param tweaks: could not remove work directory {0}: {1}" -f $state.WorkRoot, $_.Exception.Message)
                }
            }

            $TxtParamTweaksStatus.Text = ("Custom param patching completed. Output: {0}" -f $state.OutputDir)
            Write-UiLog ("Param tweaks: custom Param patch process completed. Output={0}; LogDir={1}" -f $state.OutputDir, $state.LogDir)
        }
        else {
            $TxtParamTweaksStatus.Text = ("Custom param patching failed with exit code {0}. See visible PowerShell window / logs." -f $exitCode)
            Write-UiLog ("Param tweaks: custom Param patch process failed with exit code {0}. Output={1}; LogDir={2}" -f $exitCode, $state.OutputDir, $state.LogDir)
        }
    })

    $timer.Start()
}

function Build-ParamTweaksRows {
    $ParamTweaksGrid.Children.Clear()
    $ParamTweaksGrid.RowDefinitions.Clear()
    $ParamTweaksGrid.ColumnDefinitions.Clear()
    $script:ParamTweaksRowControls = @()

    foreach ($w in @('115','85','220','220','220','220','220')) {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        $col.Width = [System.Windows.GridLengthConverter]::new().ConvertFromString($w)
        [void]$ParamTweaksGrid.ColumnDefinitions.Add($col)
    }

    $header = New-Object System.Windows.Controls.RowDefinition
    $header.Height = [System.Windows.GridLength]::Auto
    [void]$ParamTweaksGrid.RowDefinitions.Add($header)

    Add-ParamTweaksGridChild -Child (New-ParamTweaksHeaderCell -Title 'Map') -Row 0 -Column 0
    Add-ParamTweaksGridChild -Child (New-ParamTweaksHeaderCell -Title 'Time') -Row 0 -Column 1

    $targets = @(Get-YebisTargetParams)
    for ($i = 0; $i -lt $targets.Count; $i++) {
        Add-ParamTweaksGridChild -Child (New-ParamTweaksHeaderCell -Title $targets[$i].Key -Nested -ParamKey $targets[$i].Key) -Row 0 -Column ($i + 2)
    }

    $patchFiles = @(Get-ParamTweaksPatchFiles)
    $rowsAdded = 0

    foreach ($patch in $patchFiles) {
        try {
            $values = Get-YebisValuesFromPatch -PatchPath $patch.FullName
            $hasAny = $false
            foreach ($target in $targets) {
                if ($values[$target.Key].HasValue) { $hasAny = $true; break }
            }
            if (-not $hasAny) { continue }

            $info = Get-ParamTweaksMapInfoFromPatchPath -PatchPath $patch.FullName

            $rowIndex = $ParamTweaksGrid.RowDefinitions.Count
            $rd = New-Object System.Windows.Controls.RowDefinition
            $rd.Height = [System.Windows.GridLength]::Auto
            [void]$ParamTweaksGrid.RowDefinitions.Add($rd)

            $mapText = New-TextBlockCell -Text $info.MapAreaCode -Tooltip $patch.FullName
            $timeText = New-TextBlockCell -Text $info.TimeCode -Tooltip $patch.FullName

            Add-ParamTweaksGridChild -Child $mapText -Row $rowIndex -Column 0
            Add-ParamTweaksGridChild -Child $timeText -Row $rowIndex -Column 1

            $valueControls = @{}
            for ($i = 0; $i -lt $targets.Count; $i++) {
                $target = $targets[$i]
                $cell = New-ParamTweaksValueCell -ValueInfo $values[$target.Key] -PatchPath $patch.FullName
                Add-ParamTweaksGridChild -Child $cell.Element -Row $rowIndex -Column ($i + 2)
                $valueControls[$target.Key] = $cell
            }

            $script:ParamTweaksRowControls += [pscustomobject]@{
                MapText      = $mapText
                TimeText     = $timeText
                XmlKey       = $info.XmlKey
                MapAreaCode  = $info.MapAreaCode
                ShortMapCode = $info.ShortMapCode
                TimeCode     = $info.TimeCode
                MapName      = $info.MapName
                TimeName     = $info.TimeName
                PatchPath    = $patch.FullName
                Values       = $valueControls
                ValueInfos   = $values
            }

            $rowsAdded++
        }
        catch {
            Write-UiLog "Param tweaks: failed to read patch $($patch.FullName): $($_.Exception.Message)"
        }
    }

    if ($rowsAdded -eq 0) {
        $rowIndex = $ParamTweaksGrid.RowDefinitions.Count
        $rd = New-Object System.Windows.Controls.RowDefinition
        $rd.Height = [System.Windows.GridLength]::Auto
        [void]$ParamTweaksGrid.RowDefinitions.Add($rd)

        $msg = New-TextBlockCell -Text 'No Yebis gparam patch rows found under Diffs yet.' -Tooltip 'Expected *.gparam.xml.patch files under Diffs, ignoring *_witchy-bnd4.xml.patch.'
        [System.Windows.Controls.Grid]::SetColumnSpan($msg, 7)
        Add-ParamTweaksGridChild -Child $msg -Row $rowIndex -Column 0
        $TxtParamTweaksStatus.Text = 'No Yebis gparam patch rows found.'
    }
    else {
        $TxtParamTweaksStatus.Text = ("Loaded {0} Yebis param tweak row(s)." -f $rowsAdded)
    }

    Restore-ParamTweaksUserValues
    Update-ParamTweaksNameVisibility
}


function Build-MapRows {
    $widths = @('75', '210', '100', '100', '320', '120', '125', '185')
    foreach ($w in $widths) {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        $col.Width = [System.Windows.GridLengthConverter]::new().ConvertFromString($w)
        [void]$MapsGrid.ColumnDefinitions.Add($col)
    }

    $header = New-Object System.Windows.Controls.RowDefinition
    $header.Height = [System.Windows.GridLength]::Auto
    [void]$MapsGrid.RowDefinitions.Add($header)

    Add-MapGridChild -Child (New-TextBlockCell -Text 'Section' -Bold) -Row 0 -Column 0
    Add-MapGridChild -Child (New-TextBlockCell -Text 'Name' -Bold) -Row 0 -Column 1
    Add-MapGridChild -Child (New-TextBlockCell -Text 'Estimate' -Bold) -Row 0 -Column 2
    Add-MapGridChild -Child (New-TextBlockCell -Text 'Elapsed' -Bold) -Row 0 -Column 3
    Add-MapGridChild -Child (New-TextBlockCell -Text 'Steps 1-8' -Bold) -Row 0 -Column 4
    Add-MapGridChild -Child (New-TextBlockCell -Text 'Patch' -Bold) -Row 0 -Column 5
    Add-MapGridChild -Child (New-TextBlockCell -Text 'Check files' -Bold) -Row 0 -Column 6
    Add-MapGridChild -Child (New-TextBlockCell -Text 'Status' -Bold) -Row 0 -Column 7

    $scopes = New-Object System.Collections.Generic.List[object]
    $scopes.Add([pscustomobject]@{ Code = 'GLOBAL'; Name = 'Global files'; Estimate = (Get-ScopeEstimateText -ScopeCode 'GLOBAL'); IsGlobal = $true })
    foreach ($map in $Maps) {
        $scopes.Add([pscustomobject]@{ Code = $map.Code; Name = $map.Name; Estimate = (Get-ScopeEstimateText -ScopeCode $map.Code); IsGlobal = $false })
    }

    $rowIndex = 1
    foreach ($scope in $scopes) {
        $rd = New-Object System.Windows.Controls.RowDefinition
        $rd.Height = [System.Windows.GridLength]::Auto
        [void]$MapsGrid.RowDefinitions.Add($rd)

        $codeText = New-TextBlockCell -Text $scope.Code
        $nameText = New-TextBlockCell -Text $(if ($scope.IsGlobal) { 'Global files' } else { 'Hidden' }) -Tooltip 'Enable Show name spoilers to reveal map names.'
        $estimateText = New-TextBlockCell -Text $scope.Estimate
        $elapsedText = New-TextBlockCell -Text '--'
        $statusText = New-TextBlockCell -Text 'Not checked'
        $btnPatch = New-ButtonCell -Text 'Patch' -Width 105 -Tooltip "Run the configured patch scripts for $($scope.Code). Script calls will be wired in the next implementation pass."
        $btnCheck = New-ButtonCell -Text 'Check files' -Width 100 -Tooltip "Check generated files for $($scope.Code) against available diff/input files."
        $stepsPanel = New-StepCheckboxPanel -MapCode ([string]$scope.Code) -IsGlobal ([bool]$scope.IsGlobal)

        Add-MapGridChild -Child $codeText -Row $rowIndex -Column 0
        Add-MapGridChild -Child $nameText -Row $rowIndex -Column 1
        Add-MapGridChild -Child $estimateText -Row $rowIndex -Column 2
        Add-MapGridChild -Child $elapsedText -Row $rowIndex -Column 3
        Add-MapGridChild -Child $stepsPanel -Row $rowIndex -Column 4
        Add-MapGridChild -Child $btnPatch -Row $rowIndex -Column 5
        Add-MapGridChild -Child $btnCheck -Row $rowIndex -Column 6
        Add-MapGridChild -Child $statusText -Row $rowIndex -Column 7

        $MapRowControls[$scope.Code] = [pscustomobject]@{
            Name     = $nameText
            Estimate = $estimateText
            Elapsed  = $elapsedText
            Status   = $statusText
            Patch    = $btnPatch
            Check    = $btnCheck
            StepChecks = $stepsPanel
        }

        $localScopeCode = [string]$scope.Code
        $localScopeIsGlobal = [bool]$scope.IsGlobal
        $btnPatch.Add_Click({
            Invoke-SafeUiAction {
                Ensure-ModOutputFolders
                if ($localScopeIsGlobal) {
                    Invoke-GlobalPatchStub
                    return
                }

                Invoke-MapPatchStub -MapCode $localScopeCode
            }
        }.GetNewClosure())

        $btnCheck.Add_Click({
            Invoke-SafeUiAction {
                Ensure-ModOutputFolders
                if ($localScopeIsGlobal) {
                    $result = Test-GeneratedFilesForScope -Scope 'Global' -MapCode $null
                } else {
                    $result = Test-GeneratedFilesForScope -Scope $localScopeCode -MapCode $localScopeCode
                }
                $MapRowControls[$localScopeCode].Status.Text = $result
                if ([string]$result -like 'Generated*') {
                    $ScopeCompleted[$localScopeCode] = $true
                    Update-ModTotals
                }
            }
        }.GetNewClosure())

        $rowIndex++
    }

    $totalsRow = New-Object System.Windows.Controls.RowDefinition
    $totalsRow.Height = [System.Windows.GridLength]::Auto
    [void]$MapsGrid.RowDefinitions.Add($totalsRow)

    $totalCode = New-TextBlockCell -Text 'TOTAL' -Bold
    $totalName = New-TextBlockCell -Text 'Global + maps' -Bold
    $totalEstimate = New-TextBlockCell -Text (Format-ElapsedSeconds -Seconds (Get-ScaledReferenceTotalSeconds)) -Bold
    $totalElapsed = New-TextBlockCell -Text '00:00' -Bold
    $totalStepsPanel = New-StepBulkCheckboxPanel
    $totalStatus = New-TextBlockCell -Text '0 / 15 completed' -Bold

    Add-MapGridChild -Child $totalCode -Row $rowIndex -Column 0
    Add-MapGridChild -Child $totalName -Row $rowIndex -Column 1
    Add-MapGridChild -Child $totalEstimate -Row $rowIndex -Column 2
    Add-MapGridChild -Child $totalElapsed -Row $rowIndex -Column 3
    Add-MapGridChild -Child $totalStepsPanel -Row $rowIndex -Column 4
    Add-MapGridChild -Child $totalStatus -Row $rowIndex -Column 7

    $TotalsControls.Estimate = $totalEstimate
    $TotalsControls.Elapsed = $totalElapsed
    $TotalsControls.StepChecks = $totalStepsPanel
    $TotalsControls.Status = $totalStatus

    Update-MapNameVisibility
    Refresh-MapStepCheckboxAvailability
    Update-MapStepBulkCheckboxState
    Update-ModTotals
}

function Build-ToolRows {
    Add-ToolsGridColumns

    $header = New-Object System.Windows.Controls.RowDefinition
    $header.Height = [System.Windows.GridLength]::Auto
    [void]$ToolsGrid.RowDefinitions.Add($header)

    Add-GridChild -Child (New-TextBlockCell -Text 'Tool' -Bold) -Row 0 -Column 0
    Add-GridChild -Child (New-TextBlockCell -Text 'Status' -Bold) -Row 0 -Column 1
    Add-GridChild -Child (New-TextBlockCell -Text 'Installer / download payload' -Bold) -Row 0 -Column 2
    Add-GridChild -Child (New-TextBlockCell -Text 'Detected executable' -Bold) -Row 0 -Column 3
    Add-GridChild -Child (New-TextBlockCell -Text 'Actions' -Bold) -Row 0 -Column 4

    $rowIndex = 1
    foreach ($tool in $Tools) {
        $rd = New-Object System.Windows.Controls.RowDefinition
        $rd.Height = [System.Windows.GridLength]::Auto
        [void]$ToolsGrid.RowDefinitions.Add($rd)

        $toolName = New-TextBlockCell -Text $tool.Label -Tooltip $tool.Tooltip
        $status = New-TextBlockCell -Text 'Not checked'
        $payload = New-TextBoxCell -ReadOnly -Tooltip 'For ZIP/direct downloads this shows the local payload path. For winget installs this shows the package ID.'
        $exe = New-TextBoxCell -Tooltip 'Detected executable path. You can also type or paste a path here, then Save paths.'

        $panel = New-Object System.Windows.Controls.WrapPanel
        $panel.Margin = [System.Windows.Thickness]::new(4)

        $primaryText = switch ($tool.Kind) {
            'WingetRuntime' { 'Install/update' }
            'WingetExe'     { 'Install winget' }
            'LocalExe'      { 'Local only' }
            default         { 'Download' }
        }

        $extractText = switch ($tool.Kind) {
            'ZipTool' { 'Extract' }
            default   { 'No extract' }
        }

        $runText = switch ($tool.Key) {
            'PS7' { 'Run PS7' }
            'DOTNET9' { 'Test' }
            'W3001' { 'Verify' }
            'W21445' { 'Verify' }
            'W2401' { 'Verify' }
            'IM'  { 'Test' }
            'TEX' { 'Test' }
            'RE'  { 'Test' }
            'GIT' { 'Test' }
            default { if ($tool.Kind -eq 'LocalExe') { 'Check' } elseif ($tool.RunElevated) { 'Run elevated' } else { 'Run' } }
        }

        $btnPrimary = New-ButtonCell -Text $primaryText -Width 100 -Tooltip 'Download this tool or launch the winget installer for it.'
        $btnExtract = New-ButtonCell -Text $extractText -Width 78 -Tooltip 'Extract ZIP-based tools. Disabled when extraction is not needed.'
        $btnBrowse = New-ButtonCell -Text 'Exe...' -Width 62 -Tooltip 'Manually browse to the executable if it already exists elsewhere.'
        $runTooltip = if (Test-IsWitchyTool -Tool $tool) {
            'Verify the WitchyBND executable path only. The setup UI does not launch WitchyBND; patch scripts launch it directly with their original command behavior.'
        } else {
            'Run or test the configured executable.'
        }
        $btnRun = New-ButtonCell -Text $runText -Width 105 -Tooltip $runTooltip

        if ($tool.Kind -ne 'ZipTool') {
            $btnExtract.IsEnabled = $false
        }
        if ($tool.Kind -eq 'LocalExe') {
            $btnPrimary.IsEnabled = $false
        }

        [void]$panel.Children.Add($btnPrimary)
        [void]$panel.Children.Add($btnExtract)
        [void]$panel.Children.Add($btnBrowse)
        [void]$panel.Children.Add($btnRun)

        Add-GridChild -Child $toolName -Row $rowIndex -Column 0
        Add-GridChild -Child $status -Row $rowIndex -Column 1
        Add-GridChild -Child $payload -Row $rowIndex -Column 2
        Add-GridChild -Child $exe -Row $rowIndex -Column 3
        Add-GridChild -Child $panel -Row $rowIndex -Column 4

        $RowControls[$tool.Key] = [pscustomobject]@{
            Status     = $status
            Payload    = $payload
            Exe        = $exe
            Primary    = $btnPrimary
            Extract    = $btnExtract
            Browse     = $btnBrowse
            Run        = $btnRun
        }

        $localTool = $tool

        $btnPrimary.Add_Click({
            Invoke-SafeUiAction {
                Invoke-ToolDownload -Tool $localTool
            }
        }.GetNewClosure())

        $btnExtract.Add_Click({
            Invoke-SafeUiAction {
                Invoke-ToolExtract -Tool $localTool
            }
        }.GetNewClosure())

        $btnBrowse.Add_Click({
            Invoke-SafeUiAction {
                $current = $RowControls[$localTool.Key].Exe.Text.Trim()
                $selected = Select-ExeDialog -InitialPath $current -ExeName $localTool.ExeName
                if ($selected) {
                    $RowControls[$localTool.Key].Exe.Text = $selected
                    Set-RowStatus -Tool $localTool -Status 'Ready'
                }
            }
        }.GetNewClosure())

        $btnRun.Add_Click({
            Invoke-SafeUiAction {
                Invoke-ToolRunOrTest -Tool $localTool
            }
        }.GetNewClosure())

        $rowIndex++
    }
}

(C 'ChkShowMapNames').Add_Click({
    Invoke-SafeUiAction {
        Update-MapNameVisibility
    }
})

(C 'BtnRunAllMapPatches').Add_Click({
    Invoke-SafeUiAction {
        Invoke-AllMapPatches
    }
})

(C 'BtnProbeSystem').Add_Click({
    Invoke-SafeUiAction {
        Apply-SystemProbeDefaults -OverwriteExisting
    }
})

(C 'BtnBrowseGameRoot').Add_Click({
    Invoke-SafeUiAction {
        $selected = Select-FolderDialog -InitialPath $TxtGameRoot.Text
        if ($selected) {
            $TxtGameRoot.Text = $selected
            Update-GameRootStatus | Out-Null
        }
    }
})

$TxtGameRoot.Add_TextChanged({
    Update-GameRootStatus | Out-Null
})

(C 'BtnBrowseOutputRoot').Add_Click({
    Invoke-SafeUiAction {
        $selected = Select-FolderDialog -InitialPath $TxtOutputRoot.Text
        if ($selected) {
            $TxtOutputRoot.Text = $selected
            Update-OutputSpaceStatus | Out-Null
        }
    }
})

$TxtOutputRoot.Add_TextChanged({
    Update-OutputSpaceStatus | Out-Null
})

(C 'BtnBrowseDownload').Add_Click({
    Invoke-SafeUiAction {
        $selected = Select-FolderDialog -InitialPath $TxtDownloadDir.Text
        if ($selected) {
            $TxtDownloadDir.Text = $selected
            Refresh-AllRows
        }
    }
})

(C 'BtnBrowseToolRoot').Add_Click({
    Invoke-SafeUiAction {
        $selected = Select-FolderDialog -InitialPath $TxtToolRoot.Text
        if ($selected) {
            $TxtToolRoot.Text = $selected
            Refresh-AllRows
        }
    }
})

(C 'BtnSetupAllPortable').Add_Click({
    Invoke-SafeUiAction {
        $TxtSetupAllStatus.Text = 'Working...'
        $TxtSetupAllStatus.Foreground = [System.Windows.Media.Brushes]::Khaki
        Write-UiLog 'Starting required tool setup...'
        Refresh-AllRows

        foreach ($tool in ($Tools | Where-Object { $_.Kind -in @('WingetRuntime', 'WingetExe') })) {
            $exe = Find-ToolExe -Tool $tool
            if ($exe) {
                Write-UiLog "$($tool.Label): already detected, skipping winget install."
                $RowControls[$tool.Key].Exe.Text = $exe
                continue
            }

            Invoke-ToolDownload -Tool $tool -OnlyIfMissing
        }

        foreach ($tool in ($Tools | Where-Object { $_.Kind -in @('ZipTool', 'DirectExe') })) {
            $exe = Find-ToolExeInToolRoot -Tool $tool
            if ($exe) {
                Write-UiLog "$($tool.Label): already detected under Tool Root, skipping download."
                $RowControls[$tool.Key].Exe.Text = $exe
                continue
            }

            Invoke-ToolDownload -Tool $tool -OnlyIfMissing
            if ($tool.Kind -eq 'ZipTool') {
                Invoke-ToolExtract -Tool $tool
            }
        }

        Install-BBReborneUpscalerModels

        foreach ($tool in ($Tools | Where-Object { $_.Kind -eq 'LocalExe' })) {
            $exe = Find-ToolExeInToolRoot -Tool $tool
            if ($exe) {
                Write-UiLog "$($tool.Label): local tool detected under Tool Root."
                $RowControls[$tool.Key].Exe.Text = $exe
                Set-RowStatus -Tool $tool -Status 'Ready'
            } else {
                Write-UiLog "$($tool.Label): missing local tool at $(Get-DownloadPayloadPath -Tool $tool)"
                Set-RowStatus -Tool $tool -Status 'Missing local'
            }
        }

        Write-WitchyBndRecommendedSettings -Silent
        Refresh-AllRows

        $toolValidation = Test-RequiredToolsReady
        if (-not $toolValidation.Ok) {
            foreach ($missingTool in $toolValidation.Missing) {
                Write-UiLog "Missing required tool: $missingTool"
            }
            $TxtSetupAllStatus.Text = 'Missing required tools'
            $TxtSetupAllStatus.Foreground = [System.Windows.Media.Brushes]::Orange
            Write-UiLog 'Required tool setup incomplete; paths were not saved.'
            return
        }

        $gameRootStatus = Update-GameRootStatus
        if ($gameRootStatus.Ok) {
            Save-PathFiles -Silent
            $TxtSetupAllStatus.Text = '✓ tools set   ✓ settings saved'
            $TxtSetupAllStatus.Foreground = [System.Windows.Media.Brushes]::LightGreen
        } else {
            Write-UiLog "Required tools are set up. Paths were not saved yet: $($gameRootStatus.Message)"
            $TxtSetupAllStatus.Text = '✓ tools set'
            $TxtSetupAllStatus.Foreground = [System.Windows.Media.Brushes]::Khaki
        }

        Write-UiLog 'Required tool setup finished.'
    }
})

(C 'BtnRestartPwsh7').Add_Click({
    Invoke-SafeUiAction {
        Restart-InPwsh7
    }
})

(C 'BtnSavePaths').Add_Click({
    Invoke-SafeUiAction {
        Save-PathFiles
    }
})

(C 'BtnOpenSetupFolder').Add_Click({
    Invoke-SafeUiAction {
        $root = Split-Path -Parent $TxtToolRoot.Text.Trim()
        if (-not $root) { $root = $TxtToolRoot.Text.Trim() }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Start-Process explorer.exe -ArgumentList "`"$root`""
    }
})




(C 'BtnPatchParamTweaksFiles').Add_Click({
    Invoke-SafeUiAction {
        Invoke-PatchParamTweaksFiles
    }
})

(C 'BtnGenerateParamTweaksPatches').Add_Click({
    Invoke-SafeUiAction {
        Invoke-GenerateParamTweaksPatches
    }
})

$ChkShowParamTweaksSpoilers.Add_Click({
    Invoke-SafeUiAction {
        Update-ParamTweaksNameVisibility
    }
})

(C 'BtnRefreshParamTweaks').Add_Click({
    Invoke-SafeUiAction {
        Build-ParamTweaksRows
    }
})

(C 'BtnClose').Add_Click({
    $Window.Close()
})

Build-ToolRows
Build-MapRows

Write-UiLog 'Ready.'
Write-UiLog "Current host: $((Get-Process -Id $PID).Path)"
Write-UiLog "Current PowerShell version: $($PSVersionTable.PSVersion)"
Write-UiLog "Default output folder: $($TxtOutputRoot.Text)"
Write-UiLog "Default download cache: $($TxtDownloadDir.Text)"
Write-UiLog "Default tool root: $($TxtToolRoot.Text)"
Load-PathFiles
Apply-SystemProbeDefaults
try {
    Ensure-ModOutputFolders
} catch {
    Write-UiLog "Output folders were not created yet: $($_.Exception.Message)"
}
Write-UiLog 'Tip: set the game folder first, then install/check tools. Setup writes default WitchyBND settings; the Global runner rewrites the correct WitchyBND settings before each script step. Save paths when everything is ready.'
Refresh-AllRows

[void]$Window.ShowDialog()
