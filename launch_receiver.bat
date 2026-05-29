@echo off
REM launch_receiver.bat -- Dev-mode Windows entry point.
REM
REM Double-click in Explorer (or run from cmd). Opens a console, runs
REM the receiver from source. Stays open after exit so you can read
REM any traceback or the final shutdown banner.
REM
REM For lab distribution, use the standalone .exe instead:
REM     trigger_app_AJ\build\build_windows.bat
REM         -> trigger_app_AJ\dist\TMS Trigger Receiver.exe
REM (the .exe is self-contained, no Python needed on the receiver machine).

setlocal
title TMS Trigger Receiver
cd /d "%~dp0"

REM Resolve a Python interpreter. Prefer py launcher when present.
where py >nul 2>nul
if not errorlevel 1 (
    set "PYCMD=py -3"
    goto :run
)
where python >nul 2>nul
if not errorlevel 1 (
    set "PYCMD=python"
    goto :run
)
echo.
echo ERROR: No Python interpreter found on PATH.
echo Install Python 3 from https://www.python.org/downloads/windows/
echo (during install, tick "Add python.exe to PATH").
echo.
pause
exit /b 1

:run
echo.
echo Launching TMS Trigger Receiver from source...
echo Press Ctrl+C in this window to stop.
echo.
%PYCMD% -m trigger_app_AJ.windows.main %*
set "EXITCODE=%ERRORLEVEL%"

echo.
if "%EXITCODE%"=="0" (
    echo Receiver exited cleanly.
) else (
    echo Receiver exited with code %EXITCODE%.
)
echo.
pause
endlocal
