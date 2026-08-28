@echo off
setlocal
title Army of Two - Same-PC Co-op

set "AOT_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%AOT_POWERSHELL%" (
    echo ERROR: Windows PowerShell was not found at:
    echo %AOT_POWERSHELL%
    echo.
    pause
    exit /b 1
)

set "AOT_LAUNCH_ARG="
set "AOT_INSPECT_MODE="
if /i "%~1"=="check" set "AOT_LAUNCH_ARG=-InspectOnly -RequireControllers"
if /i "%~1"=="check" set "AOT_INSPECT_MODE=1"
if /i "%~1"=="inspect" set "AOT_LAUNCH_ARG=-InspectOnly -RequireControllers"
if /i "%~1"=="inspect" set "AOT_INSPECT_MODE=1"
if /i "%~1"=="portable" set "AOT_LAUNCH_ARG=-LaunchEngine PortablePlan"
if /i "%~1"=="portable-check" set "AOT_LAUNCH_ARG=-InspectOnly -RequireControllers -LaunchEngine PortablePlan"
if /i "%~1"=="portable-check" set "AOT_INSPECT_MODE=1"
if not exist "%~dp0aot-coop.local.psd1" if exist "%~dp0aot-coop.portable.psd1" if "%~1"=="" set "AOT_LAUNCH_ARG=-LaunchEngine PortablePlan"
if not exist "%~dp0aot-coop.local.psd1" if exist "%~dp0aot-coop.portable.psd1" if /i "%~1"=="check" set "AOT_LAUNCH_ARG=-InspectOnly -RequireControllers -LaunchEngine PortablePlan"
if not exist "%~dp0aot-coop.local.psd1" if exist "%~dp0aot-coop.portable.psd1" if /i "%~1"=="inspect" set "AOT_LAUNCH_ARG=-InspectOnly -RequireControllers -LaunchEngine PortablePlan"
if not "%~1"=="" if not defined AOT_LAUNCH_ARG (
    echo Usage: %~nx0 [check^|portable^|portable-check]
    echo No argument uses the local legacy config when present, otherwise the portable config.
    echo Use "check" for the read-only preflight.
    echo Use "portable" for the direct immutable-plan runtime candidate.
    echo.
    pause
    exit /b 2
)

pushd "%~dp0"
"%AOT_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-AOT-Coop.ps1" %AOT_LAUNCH_ARG%
set "AOT_EXIT=%ERRORLEVEL%"
popd

echo.
if not "%AOT_EXIT%"=="0" (
    echo AOT co-op did not start. Read the error above; no Codex prompt is required.
) else if defined AOT_INSPECT_MODE (
    echo Read-only co-op check passed.
) else (
    echo The launcher finished successfully. The two games and local backends remain running.
)
echo.
pause
exit /b %AOT_EXIT%
