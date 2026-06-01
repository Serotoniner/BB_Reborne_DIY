@echo off
REM This file is part of BB Reborne DIY Tool.
REM Copyright (C) 2026 Greg Pitta
REM
REM BB Reborne DIY Tool is free software: you can redistribute it and/or modify
REM it under the terms of the GNU General Public License as published by
REM the Free Software Foundation, either version 3 of the License, or
REM any later version.
REM
REM See the LICENSE file for details.

setlocal

set "SCRIPT_DIR=%~dp0"
set "TOOL_PS1=%SCRIPT_DIR%BBReborneDIYTool.ps1"

if not exist "%TOOL_PS1%" (
    echo BBReborneDIYTool.ps1 was not found next to this launcher:
    echo "%TOOL_PS1%"
    echo.
    pause
    exit /b 1
)


set "BBR_TOOLROOT=%SCRIPT_DIR%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Get-ChildItem -LiteralPath $env:BBR_TOOLROOT -Recurse -Force -File | Unblock-File -ErrorAction SilentlyContinue; exit 0 } catch { Write-Host 'Warning: could not unblock all files.'; Write-Host $_.Exception.Message; exit 0 }"

where pwsh.exe >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7 was not found in PATH.
    echo Please install PowerShell 7, then run this launcher again.
    echo.
    pause
    exit /b 1
)

pwsh.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%TOOL_PS1%"

if errorlevel 1 (
    echo.
    echo BB Reborne DIY Tool exited with an error.
    pause
)