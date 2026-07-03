@echo off
setlocal enabledelayedexpansion

set "PS1=%~dp0flash_firmware_fastboot.ps1"
if not exist "%PS1%" (
    echo Error: %PS1% not found.
    echo Place this launcher alongside flash_firmware_fastboot.ps1.
    pause
    exit /b 1
)

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo Error: PowerShell is not available on this system.
    pause
    exit /b 1
)

:: Auto-unblock files downloaded from the internet
powershell -NoProfile -Command "Get-ChildItem '%~dp0*.ps1','%~dp0*.exe','%~dp0*.dll' -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %ERRORLEVEL%
